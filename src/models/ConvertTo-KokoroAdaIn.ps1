#requires -Version 7.4
# Kokoro AdaIN1d normalization and affine for one batch item, channel-major.
# Kokoro istftnet.py:20-31 at dfb907a02bba8152ca444717ca5d78747ccb4bec.
# PyTorch InstanceNorm1d uses input statistics in eval when running statistics
# are disabled: torch/nn/modules/instancenorm.py at
# 2b3ec34829036a65cd9d1398ea72a0167dc37470.
# The pinned stock checkpoint has no AdaIN norm.weight/norm.bias tensors, so
# _NormBase defaults (weight=1, bias=0) apply unless both are supplied.
# The style projection is upstream; Gain is 1 + gamma, Shift is beta.
# This scalar FP32 reference is not the emitted Hexagon execution path.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $InputTensor,
    [Parameter(Mandatory)][ValidateRange(1, 32768)][int] $Frames,
    [Parameter(Mandatory)][ValidateRange(1, 1024)][int] $Channels,
    [float[]] $NormWeight,
    [float[]] $NormBias,
    [Parameter(Mandatory)][float[]] $Gain,
    [Parameter(Mandatory)][float[]] $Shift
)

$ErrorActionPreference = 'Stop'
$elements = [long]$Frames * $Channels
if ($elements -gt 8388608 -or $InputTensor.Length -ne $elements) {
    throw 'AdaIN tensor shape is invalid or exceeds the reference bound.'
}
$hasNormWeight = $PSBoundParameters.ContainsKey('NormWeight')
$hasNormBias = $PSBoundParameters.ContainsKey('NormBias')
if ($hasNormWeight -ne $hasNormBias) {
    throw 'AdaIN norm weight and bias must be supplied together.'
}
$parameters = if ($hasNormWeight) { @($NormWeight, $NormBias, $Gain, $Shift) }
    else { @($Gain, $Shift) }
foreach ($parameter in $parameters) {
    if ($parameter.Length -ne $Channels) { throw 'AdaIN channel parameter shape is invalid.' }
    foreach ($value in $parameter) {
        if (-not [float]::IsFinite($value)) { throw 'AdaIN channel parameter is non-finite.' }
    }
}

$output = [float[]]::new([int]$elements)
for ($channel = 0; $channel -lt $Channels; $channel++) {
    $offset = $channel * $Frames
    $sum = 0.0
    for ($frame = 0; $frame -lt $Frames; $frame++) {
        $value = [double]$InputTensor[$offset + $frame]
        if (-not [double]::IsFinite($value)) { throw 'AdaIN input is non-finite.' }
        $sum += $value
    }
    $mean = $sum / $Frames
    $squares = 0.0
    for ($frame = 0; $frame -lt $Frames; $frame++) {
        $difference = [double]$InputTensor[$offset + $frame] - $mean
        $squares += $difference * $difference
    }
    # Instance normalization uses population variance, not Bessel correction.
    $inverseStd = 1.0 / [Math]::Sqrt($squares / $Frames + 1e-5)
    $normScale = if ($hasNormWeight) { [double]$NormWeight[$channel] } else { 1.0 }
    $normShift = if ($hasNormBias) { [double]$NormBias[$channel] } else { 0.0 }
    $scale = $normScale * [double]$Gain[$channel]
    $bias = $normShift * [double]$Gain[$channel] + [double]$Shift[$channel]
    for ($frame = 0; $frame -lt $Frames; $frame++) {
        $value = (([double]$InputTensor[$offset + $frame] - $mean) * $inverseStd) * $scale + $bias
        if (-not [double]::IsFinite($value) -or [Math]::Abs($value) -gt [float]::MaxValue) {
            throw 'AdaIN output is non-finite.'
        }
        $output[$offset + $frame] = [float]$value
    }
}
Write-Output -NoEnumerate $output
