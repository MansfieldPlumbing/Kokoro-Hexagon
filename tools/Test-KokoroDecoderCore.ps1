#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string] $CheckpointPath)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
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
        throw "Stock decoder core tensor shape differs: $Name"
    }
    [byte[]]$bytes = & $reader.Bytes $checkpoint $Name
    [float[]]$values = [float[]]::new($bytes.Length / 4)
    [Buffer]::BlockCopy($bytes, 0, $values, 0, $bytes.Length)
    return ,$values
}
$preludeParameters = @{}
$preludeShapes = @{
    'F0_conv.weight_v' = '1,1,3'; 'F0_conv.weight_g' = '1,1,1'
    'F0_conv.bias' = '1'; 'N_conv.weight_v' = '1,1,3'
    'N_conv.weight_g' = '1,1,1'; 'N_conv.bias' = '1'
    'asr_res.0.weight_v' = '64,512,1'
    'asr_res.0.weight_g' = '64,1,1'; 'asr_res.0.bias' = '64'
}
foreach ($entry in $preludeShapes.GetEnumerator()) {
    $preludeParameters[$entry.Key] = & $read ('decoder.module.' + $entry.Key) $entry.Value
}
$parameters = @{}
foreach ($block in -1, 0, 1, 2, 3) {
    $prefix = if ($block -eq -1) { 'encode.' } else { "decode.$block." }
    $inputChannels = if ($block -eq -1) { 514 } else { 1090 }
    $outputChannels = if ($block -eq 3) { 512 } else { 1024 }
    $shapes = @{
        'norm1.fc.weight' = "$(2 * $inputChannels),128"
        'norm1.fc.bias' = "$(2 * $inputChannels)"
        'norm2.fc.weight' = "$(2 * $outputChannels),128"
        'norm2.fc.bias' = "$(2 * $outputChannels)"
        'conv1.weight_v' = "$outputChannels,$inputChannels,3"
        'conv1.weight_g' = "$outputChannels,1,1"
        'conv1.bias' = "$outputChannels"
        'conv2.weight_v' = "$outputChannels,$outputChannels,3"
        'conv2.weight_g' = "$outputChannels,1,1"
        'conv2.bias' = "$outputChannels"
        'conv1x1.weight_v' = "$outputChannels,$inputChannels,1"
        'conv1x1.weight_g' = "$outputChannels,1,1"
    }
    if ($block -eq 3) {
        $shapes['pool.weight_v'] = '1090,1,3'
        $shapes['pool.weight_g'] = '1090,1,1'
        $shapes['pool.bias'] = '1090'
    }
    foreach ($entry in $shapes.GetEnumerator()) {
        $key = $prefix + $entry.Key
        $parameters[$key] = & $read ('decoder.module.' + $key) $entry.Value
    }
}
$text = [float[]]::new(512 * 2)
for ($i = 0; $i -lt $text.Length; $i++) {
    $text[$i] = [float](0.1 * [Math]::Sin($i * 0.03))
}
$prelude = & (Join-Path $root 'src/models/Invoke-KokoroDecoderPrelude.ps1') `
    -AlignedTextFeatures $text -F0 ([float[]]@(91, 92, 93, 94)) `
    -N ([float[]]@(0.1, 0.2, 0.3, 0.4)) -Parameters $preludeParameters `
    -Frames 2
$actual = & (Join-Path $root 'src/models/Invoke-KokoroDecoderCore.ps1') `
    -Prelude $prelude -Style ([float[]]::new(128)) -Parameters $parameters
if ($actual.Channels -ne 512 -or $actual.Frames -ne 4 -or
    $actual.Features.Length -ne 2048) {
    throw 'Stock decoder core output shape differs.'
}
foreach ($value in $actual.Features) {
    if (-not [float]::IsFinite($value)) {
        throw 'Stock decoder core output is non-finite.'
    }
}
Write-Output 'PASS: stock-weight decoder core shape and finite-output gate'
