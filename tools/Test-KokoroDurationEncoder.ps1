#requires -Version 7.4
[CmdletBinding()]
param([string] $CheckpointPath)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stage = Join-Path $root 'src/models/Invoke-KokoroDurationEncoder.ps1'
$parameters = @{}
for ($layer = 0; $layer -lt 2; $layer++) {
    $lstmIndex = 2 * $layer
    $normIndex = $lstmIndex + 1
    foreach ($suffix in @('', '_reverse')) {
        $parameters["lstms.$lstmIndex.weight_ih_l0$suffix"] = [float[]]::new(4 * 3)
        $parameters["lstms.$lstmIndex.weight_hh_l0$suffix"] = [float[]]::new(4)
        $parameters["lstms.$lstmIndex.bias_ih_l0$suffix"] = [float[]]::new(4)
        $parameters["lstms.$lstmIndex.bias_hh_l0$suffix"] = [float[]]::new(4)
    }
    $parameters["lstms.$normIndex.fc.weight"] = [float[]]::new(4)
    $parameters["lstms.$normIndex.fc.bias"] = [float[]]::new(4)
}
$actual = & $stage -TokenFeatures ([float[]]@(1, 0, 0, 1)) `
    -Style ([float[]]@(0)) -Parameters $parameters -Tokens 2 `
    -FeatureSize 2 -Layers 2
if ($actual.Length -ne 6 -or @($actual | Where-Object { $_ -ne 0 }).Count -ne 0) {
    throw 'Analytic duration encoder stack or output shape differs.'
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
    $stockParameters = @{}
    $prefix = 'predictor.module.text_encoder.'
    $read = {
        param([string] $Name, [string] $Shape)
        $descriptor = $checkpoint.Tensors[$prefix + $Name]
        if ($null -eq $descriptor -or ($descriptor.Shape -join ',') -cne $Shape) {
            throw 'Stock duration encoder tensor shape differs.'
        }
        [byte[]]$bytes = & $reader.Bytes $checkpoint ($prefix + $Name)
        [float[]]$values = [float[]]::new($bytes.Length / 4)
        [Buffer]::BlockCopy($bytes, 0, $values, 0, $bytes.Length)
        return ,$values
    }
    for ($layer = 0; $layer -lt 3; $layer++) {
        $lstmIndex = 2 * $layer
        $normIndex = $lstmIndex + 1
        foreach ($suffix in @('', '_reverse')) {
            foreach ($name in @('weight_ih_l0', 'weight_hh_l0', 'bias_ih_l0', 'bias_hh_l0')) {
                $shape = if ($name -eq 'weight_ih_l0') { '1024,640' }
                    elseif ($name -eq 'weight_hh_l0') { '1024,256' } else { '1024' }
                $key = "lstms.$lstmIndex.$name$suffix"
                $stockParameters[$key] = & $read $key $shape
            }
        }
        $stockParameters["lstms.$normIndex.fc.weight"] = & $read `
            "lstms.$normIndex.fc.weight" '1024,128'
        $stockParameters["lstms.$normIndex.fc.bias"] = & $read `
            "lstms.$normIndex.fc.bias" '1024'
    }
    $stockInput = [float[]]::new(2 * 512)
    for ($i = 0; $i -lt $stockInput.Length; $i++) {
        $stockInput[$i] = [float](0.1 * [Math]::Sin($i * 0.02))
    }
    $stock = & $stage -TokenFeatures $stockInput -Style ([float[]]::new(128)) `
        -Parameters $stockParameters -Tokens 2 -FeatureSize 512 -Layers 3
    if ($stock.Length -ne 1280) { throw 'Stock duration encoder output shape differs.' }
    foreach ($value in $stock) {
        if (-not [float]::IsFinite($value)) { throw 'Stock duration encoder output is non-finite.' }
    }
}
Write-Output 'PASS: duration encoder recurrent stack and optional stock-weight three-layer gate'
