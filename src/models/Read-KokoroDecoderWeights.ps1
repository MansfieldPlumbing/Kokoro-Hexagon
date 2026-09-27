#requires -Version 7.4
# Build-time extraction of the pinned stock decoder's FP32 tensors.
# Kokoro checkpoint revision f3ff3571791e39611d31c381e3a41a3af07b4987.
[CmdletBinding()]
param([Parameter(Mandatory)][string] $CheckpointPath, [switch] $NamesOnly)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
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
$shapes = @{
    'F0_conv.weight_v' = '1,1,3'; 'F0_conv.weight_g' = '1,1,1'
    'F0_conv.bias' = '1'; 'N_conv.weight_v' = '1,1,3'
    'N_conv.weight_g' = '1,1,1'; 'N_conv.bias' = '1'
    'asr_res.0.weight_v' = '64,512,1'
    'asr_res.0.weight_g' = '64,1,1'; 'asr_res.0.bias' = '64'
}
for ($block = -1; $block -lt 4; $block++) {
    $blockPrefix = if ($block -eq -1) { 'encode.' } else { "decode.$block." }
    $inputChannels = if ($block -eq -1) { 514 } else { 1090 }
    $outputChannels = if ($block -eq 3) { 512 } else { 1024 }
    $shapes["${blockPrefix}norm1.fc.weight"] = "$(2 * $inputChannels),128"
    $shapes["${blockPrefix}norm1.fc.bias"] = "$(2 * $inputChannels)"
    $shapes["${blockPrefix}norm2.fc.weight"] = "$(2 * $outputChannels),128"
    $shapes["${blockPrefix}norm2.fc.bias"] = "$(2 * $outputChannels)"
    $shapes["${blockPrefix}conv1.weight_v"] = "$outputChannels,$inputChannels,3"
    $shapes["${blockPrefix}conv1.weight_g"] = "$outputChannels,1,1"
    $shapes["${blockPrefix}conv1.bias"] = "$outputChannels"
    $shapes["${blockPrefix}conv2.weight_v"] = "$outputChannels,$outputChannels,3"
    $shapes["${blockPrefix}conv2.weight_g"] = "$outputChannels,1,1"
    $shapes["${blockPrefix}conv2.bias"] = "$outputChannels"
    $shapes["${blockPrefix}conv1x1.weight_v"] = "$outputChannels,$inputChannels,1"
    $shapes["${blockPrefix}conv1x1.weight_g"] = "$outputChannels,1,1"
    if ($block -eq 3) {
        $shapes["${blockPrefix}pool.weight_v"] = '1090,1,3'
        $shapes["${blockPrefix}pool.weight_g"] = '1090,1,1'
        $shapes["${blockPrefix}pool.bias"] = '1090'
    }
}
if ($shapes.Count -ne 72) { throw 'Decoder tensor specification count differs.' }
foreach ($name in $shapes.Keys) {
    $descriptor = $checkpoint.Tensors['decoder.module.' + $name]
    if ($null -eq $descriptor -or $descriptor.DType -cne 'float32' -or
        ($descriptor.Shape -join ',') -cne $shapes[$name]) {
        throw "Stock decoder tensor shape or element width differs: $name"
    }
    $expectedStride = 1L
    for ($axis = $descriptor.Shape.Length - 1; $axis -ge 0; $axis--) {
        if ($descriptor.Stride[$axis] -ne $expectedStride) {
            throw "Stock decoder tensor is not contiguous: $name"
        }
        $expectedStride *= $descriptor.Shape[$axis]
    }
}
if ($NamesOnly) {
    Write-Output -NoEnumerate @($shapes.Keys | ForEach-Object { 'decoder.module.' + $_ })
    return
}
$prelude = @{}
$core = @{}
foreach ($name in $shapes.Keys) {
    [byte[]]$bytes = & $reader.Bytes $checkpoint ('decoder.module.' + $name)
    $values = [float[]]::new($bytes.Length / 4)
    [Buffer]::BlockCopy($bytes, 0, $values, 0, $bytes.Length)
    foreach ($value in $values) {
        if (-not [float]::IsFinite($value)) { throw "Stock decoder tensor is non-finite: $name" }
    }
    if ($name -match '^(F0_conv|N_conv|asr_res)\.') {
        $prelude[$name] = $values
    } else {
        $core[$name] = $values
    }
}
[pscustomobject]@{
    PreludeParameters = $prelude
    CoreParameters = $core
    TensorCount = $shapes.Count
    CheckpointSha256 = $pin[0].sha256
}
