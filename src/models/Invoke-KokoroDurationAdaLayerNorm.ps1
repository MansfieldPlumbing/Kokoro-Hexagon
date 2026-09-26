#requires -Version 7.4
# DurationEncoder AdaLayerNorm and style re-concatenation, batch one.
# Kokoro kokoro/modules.py AdaLayerNorm.forward and DurationEncoder.forward at
# dfb907a02bba8152ca444717ca5d78747ccb4bec.
# Input [time, channels]; output [time, channels + style].
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $InputTensor,
    [Parameter(Mandatory)][float[]] $Style,
    [Parameter(Mandatory)][float[]] $FcWeights,
    [Parameter(Mandatory)][float[]] $FcBias,
    [Parameter(Mandatory)][ValidateRange(1, 512)][int] $Frames,
    [Parameter(Mandatory)][ValidateRange(2, 1024)][int] $Channels,
    [ValidateRange(0, 1)][double] $Epsilon = 1e-5
)

$ErrorActionPreference = 'Stop'
$styleSize = $Style.Length
if ($styleSize -lt 1 -or $styleSize -gt 1024 -or
    $InputTensor.Length -ne [long]$Frames * $Channels -or
    $FcWeights.Length -ne [long]2 * $Channels * $styleSize -or
    $FcBias.Length -ne 2 * $Channels) {
    throw 'Duration adaptive layer norm shape is invalid.'
}
foreach ($array in @($InputTensor, $Style, $FcWeights, $FcBias)) {
    foreach ($value in $array) {
        if (-not [float]::IsFinite($value)) { throw 'Duration adaptive layer norm input is non-finite.' }
    }
}
$affine = [double[]]::new(2 * $Channels)
for ($output = 0; $output -lt $affine.Length; $output++) {
    $sum = [double]$FcBias[$output]
    for ($input = 0; $input -lt $styleSize; $input++) {
        $sum += [double]$FcWeights[$output * $styleSize + $input] *
            [double]$Style[$input]
    }
    $affine[$output] = $sum
}
$result = [float[]]::new($Frames * ($Channels + $styleSize))
for ($frame = 0; $frame -lt $Frames; $frame++) {
    $mean = 0.0
    for ($channel = 0; $channel -lt $Channels; $channel++) {
        $mean += [double]$InputTensor[$frame * $Channels + $channel]
    }
    $mean /= $Channels
    $variance = 0.0
    for ($channel = 0; $channel -lt $Channels; $channel++) {
        $difference = [double]$InputTensor[$frame * $Channels + $channel] - $mean
        $variance += $difference * $difference
    }
    $inverseStd = 1.0 / [Math]::Sqrt($variance / $Channels + $Epsilon)
    for ($channel = 0; $channel -lt $Channels; $channel++) {
        $value = (([double]$InputTensor[$frame * $Channels + $channel] - $mean) *
            $inverseStd) * (1.0 + $affine[$channel]) + $affine[$Channels + $channel]
        if (-not [double]::IsFinite($value) -or [Math]::Abs($value) -gt [float]::MaxValue) {
            throw 'Duration adaptive layer norm output is non-finite.'
        }
        $result[$frame * ($Channels + $styleSize) + $channel] = [float]$value
    }
    for ($channel = 0; $channel -lt $styleSize; $channel++) {
        $result[$frame * ($Channels + $styleSize) + $Channels + $channel] = $Style[$channel]
    }
}
Write-Output -NoEnumerate $result
