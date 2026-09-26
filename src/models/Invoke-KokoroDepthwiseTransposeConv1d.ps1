#requires -Version 7.4
# Kokoro F0/N AdainResBlk1d pool: depthwise weight-normalized ConvTranspose1d
# kernel 3, stride 2, padding 1, output_padding 1. Pinned Kokoro
# kokoro/istftnet.py at dfb907a02bba8152ca444717ca5d78747ccb4bec;
# weight_norm(dim=0) per PyTorch 2b3ec34829036a65cd9d1398ea72a0167dc37470.
# Channel-first batch-one bounded FP32 reference.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $InputTensor,
    [Parameter(Mandatory)][float[]] $WeightV,
    [Parameter(Mandatory)][float[]] $WeightG,
    [Parameter(Mandatory)][float[]] $Bias,
    [Parameter(Mandatory)][ValidateRange(1, 32768)][int] $Frames,
    [Parameter(Mandatory)][ValidateRange(1, 1024)][int] $Channels
)

$ErrorActionPreference = 'Stop'
if ($InputTensor.Length -ne [long]$Channels * $Frames -or
    $WeightV.Length -ne [long]$Channels * 3 -or
    $WeightG.Length -ne $Channels -or $Bias.Length -ne $Channels -or
    [long]$Channels * $Frames * 3 -gt 8000000) {
    throw 'Depthwise transposed Conv1D shape exceeds the reference contract.'
}
foreach ($values in @($InputTensor, $WeightV, $WeightG, $Bias)) {
    foreach ($value in $values) {
        if (-not [float]::IsFinite($value)) { throw 'Depthwise transposed Conv1D input is non-finite.' }
    }
}
$outputFrames = 2 * $Frames
$result = [float[]]::new($Channels * $outputFrames)
for ($channel = 0; $channel -lt $Channels; $channel++) {
    $offset = $channel * 3
    $norm = [Math]::Sqrt(
        [double]$WeightV[$offset] * [double]$WeightV[$offset] +
        [double]$WeightV[$offset + 1] * [double]$WeightV[$offset + 1] +
        [double]$WeightV[$offset + 2] * [double]$WeightV[$offset + 2])
    if ($norm -eq 0) { throw 'Depthwise transposed Conv1D weight norm is zero.' }
    $scale = [double]$WeightG[$channel] / $norm
    for ($frame = 0; $frame -lt $outputFrames; $frame++) {
        $result[$channel * $outputFrames + $frame] = $Bias[$channel]
    }
    for ($frame = 0; $frame -lt $Frames; $frame++) {
        for ($tap = 0; $tap -lt 3; $tap++) {
            $outputFrame = $frame * 2 - 1 + $tap
            if ($outputFrame -lt 0 -or $outputFrame -ge $outputFrames) { continue }
            $index = $channel * $outputFrames + $outputFrame
            $sum = [double]$result[$index] +
                [double]$InputTensor[$channel * $Frames + $frame] *
                [double]$WeightV[$offset + $tap] * $scale
            if (-not [double]::IsFinite($sum) -or [Math]::Abs($sum) -gt [float]::MaxValue) {
                throw 'Depthwise transposed Conv1D output is non-finite.'
            }
            $result[$index] = [float]$sum
        }
    }
}
Write-Output -NoEnumerate $result
