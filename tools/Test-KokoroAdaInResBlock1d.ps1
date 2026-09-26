#requires -Version 7.4
[CmdletBinding()]
param([string] $CheckpointPath)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stage = Join-Path $root 'src/models/Invoke-KokoroAdaInResBlock1d.ps1'
$parameters = @{
    'norm1.fc.weight' = [float[]]::new(4)
    'norm1.fc.bias' = [float[]]::new(4)
    'norm2.fc.weight' = [float[]]::new(2)
    'norm2.fc.bias' = [float[]]::new(2)
    'conv1.weight_v' = [float[]]@(0, 1, 0, 0, 0, 0)
    'conv1.weight_g' = [float[]]@(0)
    'conv1.bias' = [float[]]@(0)
    'conv2.weight_v' = [float[]]@(0, 1, 0)
    'conv2.weight_g' = [float[]]@(0)
    'conv2.bias' = [float[]]@(0)
    'conv1x1.weight_v' = [float[]]@(1, 0)
    'conv1x1.weight_g' = [float[]]@(1)
}
$actual = & $stage -InputTensor ([float[]]@(1, 2, 4, 5)) `
    -Style ([float[]]@(0)) -Parameters $parameters -Frames 2 `
    -Channels 2 -OutputChannels 1
if ($actual.Length -ne 2 -or
    [Math]::Abs([double]$actual[0] - 1 / [Math]::Sqrt(2)) -gt 1e-6 -or
    [Math]::Abs([double]$actual[1] - 2 / [Math]::Sqrt(2)) -gt 1e-6) {
    throw 'Analytic non-upsample AdaIN channel shortcut differs.'
}
if ($CheckpointPath) {
    $pin = @(([IO.File]::ReadAllText((Join-Path $root 'lib/manifest.json')) |
        ConvertFrom-Json -AsHashtable).model.files | Where-Object { $_.path -ceq 'kokoro-v1_0.pth' })
    $path = (Resolve-Path -LiteralPath $CheckpointPath).Path
    if ($pin.Count -ne 1 -or (Get-Item -LiteralPath $path).Length -ne [long]$pin[0].bytes -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $pin[0].sha256) {
        throw 'Stock checkpoint does not match the pinned digest.'
    }
    $reader = [scriptblock]::Create([IO.File]::ReadAllText(
        (Join-Path $root 'src/runspace/Torch.Checkpoint.psm1'))).InvokeReturnAsIs()
    $checkpoint = & $reader.Read $path
    $read = {
        param([string] $Name, [string] $Shape)
        $descriptor = $checkpoint.Tensors[$Name]
        if ($null -eq $descriptor -or ($descriptor.Shape -join ',') -cne $Shape) {
            throw "Stock decoder encode tensor shape differs: $Name"
        }
        [byte[]]$bytes = & $reader.Bytes $checkpoint $Name
        [float[]]$values = [float[]]::new($bytes.Length / 4)
        [Buffer]::BlockCopy($bytes, 0, $values, 0, $bytes.Length)
        return ,$values
    }
    $stock = @{}
    $shapes = @{
        'norm1.fc.weight' = '1028,128'; 'norm1.fc.bias' = '1028'
        'norm2.fc.weight' = '2048,128'; 'norm2.fc.bias' = '2048'
        'conv1.weight_v' = '1024,514,3'; 'conv1.weight_g' = '1024,1,1'
        'conv1.bias' = '1024'; 'conv2.weight_v' = '1024,1024,3'
        'conv2.weight_g' = '1024,1,1'; 'conv2.bias' = '1024'
        'conv1x1.weight_v' = '1024,514,1'; 'conv1x1.weight_g' = '1024,1,1'
    }
    foreach ($entry in $shapes.GetEnumerator()) {
        $stock[$entry.Key] = & $read ('decoder.module.encode.' + $entry.Key) $entry.Value
    }
    $stockInput = [float[]]::new(514 * 2)
    for ($i = 0; $i -lt $stockInput.Length; $i++) {
        $stockInput[$i] = [float](0.1 * [Math]::Sin($i * 0.03))
    }
    $stockOutput = & $stage -InputTensor $stockInput `
        -Style ([float[]]::new(128)) -Parameters $stock `
        -Frames 2 -Channels 514 -OutputChannels 1024
    if ($stockOutput.Length -ne 2048) { throw 'Stock decoder encode output shape differs.' }
    foreach ($value in $stockOutput) {
        if (-not [float]::IsFinite($value)) {
            throw 'Stock decoder encode output is non-finite.'
        }
    }
}
Write-Output 'PASS: AdaIN channel shortcut and optional stock decoder encode gate'
