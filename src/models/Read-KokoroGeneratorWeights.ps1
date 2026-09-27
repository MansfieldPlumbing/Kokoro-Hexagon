#requires -Version 7.4
# Build-time extraction of the pinned stock generator's FP32 tensors.
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
$prefix = 'decoder.module.generator.'
$shapes = @{}
for ($stage = 0; $stage -lt 2; $stage++) {
    $channelsIn = @(512, 256)[$stage]
    $channelsOut = @(256, 128)[$stage]
    $upKernel = @(20, 12)[$stage]
    $noiseKernel = @(12, 1)[$stage]
    $shapes["ups.$stage.weight_v"] = "$channelsIn,$channelsOut,$upKernel"
    $shapes["ups.$stage.weight_g"] = "$channelsIn,1,1"
    $shapes["ups.$stage.bias"] = "$channelsOut"
    $shapes["noise_convs.$stage.weight"] = "$channelsOut,22,$noiseKernel"
    $shapes["noise_convs.$stage.bias"] = "$channelsOut"
}
$shapes['conv_post.weight_v'] = '22,128,7'
$shapes['conv_post.weight_g'] = '22,1,1'
$shapes['conv_post.bias'] = '22'
$shapes['m_source.l_linear.weight'] = '1,9'
$shapes['m_source.l_linear.bias'] = '1'

function Add-BlockShapes([string] $BlockPrefix, [int] $Channels, [int] $Kernel) {
    for ($pass = 0; $pass -lt 3; $pass++) {
        foreach ($side in 1, 2) {
            $shapes["${BlockPrefix}adain$side.$pass.fc.weight"] = "$(2 * $Channels),128"
            $shapes["${BlockPrefix}adain$side.$pass.fc.bias"] = "$(2 * $Channels)"
            $shapes["${BlockPrefix}alpha$side.$pass"] = "1,$Channels,1"
            $shapes["${BlockPrefix}convs$side.$pass.weight_v"] = "$Channels,$Channels,$Kernel"
            $shapes["${BlockPrefix}convs$side.$pass.weight_g"] = "$Channels,1,1"
            $shapes["${BlockPrefix}convs$side.$pass.bias"] = "$Channels"
        }
    }
}
for ($stage = 0; $stage -lt 2; $stage++) {
    $channels = @(256, 128)[$stage]
    Add-BlockShapes "noise_res.$stage." $channels @(7, 11)[$stage]
    for ($branch = 0; $branch -lt 3; $branch++) {
        Add-BlockShapes "resblocks.$($stage * 3 + $branch)." $channels @(3, 7, 11)[$branch]
    }
}
if ($shapes.Count -ne 303) { throw 'Generator tensor specification count differs.' }

# Validate the full declared map before extracting any tensor bytes.
foreach ($name in $shapes.Keys) {
    $descriptor = $checkpoint.Tensors[$prefix + $name]
    if ($null -eq $descriptor -or $descriptor.DType -cne 'float32' -or
        ($descriptor.Shape -join ',') -cne $shapes[$name]) {
        throw "Stock generator tensor shape or element width differs: $name"
    }
    $expectedStride = 1L
    for ($axis = $descriptor.Shape.Length - 1; $axis -ge 0; $axis--) {
        if ($descriptor.Stride[$axis] -ne $expectedStride) {
            throw "Stock generator tensor is not contiguous: $name"
        }
        $expectedStride *= $descriptor.Shape[$axis]
    }
}
if ($NamesOnly) {
    Write-Output -NoEnumerate @($shapes.Keys | ForEach-Object { $prefix + $_ })
    return
}
$vectors = @{}
foreach ($name in $shapes.Keys) {
    [byte[]]$bytes = & $reader.Bytes $checkpoint ($prefix + $name)
    $values = [float[]]::new($bytes.Length / 4)
    [Buffer]::BlockCopy($bytes, 0, $values, 0, $bytes.Length)
    foreach ($value in $values) {
        if (-not [float]::IsFinite($value)) { throw "Stock generator tensor is non-finite: $name" }
    }
    $vectors[$name] = $values
}
$mergeWeights = $vectors['m_source.l_linear.weight']
$mergeBias = $vectors['m_source.l_linear.bias']
$vectors.Remove('m_source.l_linear.weight')
$vectors.Remove('m_source.l_linear.bias')
[pscustomobject]@{
    Parameters = $vectors
    SourceMergeWeights = $mergeWeights
    SourceMergeBias = $mergeBias
    TensorCount = $shapes.Count
    CheckpointSha256 = $pin[0].sha256
}
