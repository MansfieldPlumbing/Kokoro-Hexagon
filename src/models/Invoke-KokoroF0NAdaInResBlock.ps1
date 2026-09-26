#requires -Version 7.4
# F0/N predictor AdainResBlk1d, including the middle upsample variant.
# Kokoro kokoro/istftnet.py AdainResBlk1d at
# dfb907a02bba8152ca444717ca5d78747ccb4bec.
# AdaIN -> LeakyReLU(0.2) -> Conv1D, repeated twice, then scaled residual.
# Bounded FP32 correctness reference.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $InputTensor,
    [Parameter(Mandatory)][float[]] $Style,
    [Parameter(Mandatory)][System.Collections.IDictionary] $Parameters,
    [Parameter(Mandatory)][ValidateRange(2, 32768)][int] $Frames,
    [Parameter(Mandatory)][ValidateRange(1, 1024)][int] $Channels,
    [ValidateRange(0, 1024)][int] $OutputChannels = 0,
    [switch] $Upsample
)

$ErrorActionPreference = 'Stop'
if ($OutputChannels -eq 0) { $OutputChannels = $Channels }
if (-not $Upsample -and $OutputChannels -ne $Channels) {
    throw 'F0/N channel change requires the upsample variant.'
}
if ($InputTensor.Length -ne [long]$Frames * $Channels -or
    $Style.Length -lt 1 -or $Style.Length -gt 1024) {
    throw 'F0/N AdaIN residual block input shape is invalid.'
}
foreach ($stage in 1, 2) {
    foreach ($key in @("norm$stage.fc.weight", "norm$stage.fc.bias",
            "conv$stage.weight_v", "conv$stage.weight_g", "conv$stage.bias")) {
        if (-not $Parameters.Contains($key) -or $Parameters[$key] -isnot [float[]]) {
            throw "F0/N AdaIN residual block parameter is absent: $key"
        }
    }
}
if ($Upsample) {
    foreach ($key in @('pool.weight_v', 'pool.weight_g', 'pool.bias')) {
        if (-not $Parameters.Contains($key) -or $Parameters[$key] -isnot [float[]]) {
            throw "F0/N upsample parameter is absent: $key"
        }
    }
}
if ($OutputChannels -ne $Channels) {
    foreach ($key in @('conv1x1.weight_v', 'conv1x1.weight_g')) {
        if (-not $Parameters.Contains($key) -or $Parameters[$key] -isnot [float[]]) {
            throw "F0/N shortcut parameter is absent: $key"
        }
    }
}
$modelRoot = $PSScriptRoot
$state = $InputTensor
$currentFrames = $Frames
foreach ($stage in 1, 2) {
    $inputChannels = if ($stage -eq 1) { $Channels } else { $OutputChannels }
    $affine = & (Join-Path $modelRoot 'ConvertTo-KokoroAdaInStyle.ps1') `
        -Style $Style -Weights $Parameters["norm$stage.fc.weight"] `
        -Bias $Parameters["norm$stage.fc.bias"] -Channels $inputChannels
    [float[]]$state = & (Join-Path $modelRoot 'ConvertTo-KokoroAdaIn.ps1') `
        -InputTensor $state -Frames $currentFrames -Channels $inputChannels `
        -Gain $affine.Gain -Shift $affine.Shift
    for ($i = 0; $i -lt $state.Length; $i++) {
        if ($state[$i] -lt 0) { $state[$i] = [float](0.2 * [double]$state[$i]) }
    }
    if ($stage -eq 1 -and $Upsample) {
        [float[]]$state = & (Join-Path $modelRoot 'Invoke-KokoroDepthwiseTransposeConv1d.ps1') `
            -InputTensor $state -Frames $currentFrames -Channels $Channels `
            -WeightV $Parameters['pool.weight_v'] -WeightG $Parameters['pool.weight_g'] `
            -Bias $Parameters['pool.bias']
        $currentFrames *= 2
    }
    [float[]]$state = & (Join-Path $modelRoot 'Invoke-KokoroWeightNormConv1d.ps1') `
        -InputTensor $state -Frames $currentFrames -InputChannels $inputChannels `
        -OutputChannels $OutputChannels -KernelSize 3 -Dilation 1 `
        -WeightV $Parameters["conv$stage.weight_v"] `
        -WeightG $Parameters["conv$stage.weight_g"] `
        -Bias $Parameters["conv$stage.bias"]
}
$shortcut = $InputTensor
if ($Upsample) {
    $shortcut = [float[]]::new($Channels * $currentFrames)
    for ($channel = 0; $channel -lt $Channels; $channel++) {
        for ($frame = 0; $frame -lt $Frames; $frame++) {
            $value = $InputTensor[$channel * $Frames + $frame]
            $shortcut[$channel * $currentFrames + 2 * $frame] = $value
            $shortcut[$channel * $currentFrames + 2 * $frame + 1] = $value
        }
    }
}
if ($OutputChannels -ne $Channels) {
    [float[]]$shortcut = & (Join-Path $modelRoot 'Invoke-KokoroWeightNormConv1d.ps1') `
        -InputTensor $shortcut -Frames $currentFrames -InputChannels $Channels `
        -OutputChannels $OutputChannels -KernelSize 1 -Dilation 1 `
        -WeightV $Parameters['conv1x1.weight_v'] `
        -WeightG $Parameters['conv1x1.weight_g'] -Bias ([float[]]::new($OutputChannels))
}
$result = [float[]]::new($state.Length)
$scale = 1.0 / [Math]::Sqrt(2.0)
for ($i = 0; $i -lt $result.Length; $i++) {
    $value = ([double]$shortcut[$i] + [double]$state[$i]) * $scale
    if (-not [double]::IsFinite($value) -or [Math]::Abs($value) -gt [float]::MaxValue) {
        throw 'F0/N AdaIN residual block output is non-finite.'
    }
    $result[$i] = [float]$value
}
Write-Output -NoEnumerate $result
