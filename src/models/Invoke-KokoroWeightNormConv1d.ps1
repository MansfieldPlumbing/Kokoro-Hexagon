#requires -Version 7.4
# Model-neutral weight_norm(dim=0) Conv1d, channel-first, batch one, same
# zero padding. PyTorch torch/nn/utils/parametrizations.py at
# 2b3ec34829036a65cd9d1398ea72a0167dc37470. Used by stock Kokoro
# text encoder and decoder references; bounded FP32 correctness path only.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $InputTensor,
    [Parameter(Mandatory)][ValidateRange(1, 32768)][int] $Frames,
    [Parameter(Mandatory)][ValidateRange(1, 2048)][int] $InputChannels,
    [Parameter(Mandatory)][ValidateRange(1, 1024)][int] $OutputChannels,
    [Parameter(Mandatory)][ValidateRange(1, 31)][int] $KernelSize,
    [Parameter(Mandatory)][ValidateRange(1, 32)][int] $Dilation,
    [Parameter(Mandatory)][float[]] $WeightV,
    [Parameter(Mandatory)][float[]] $WeightG,
    [Parameter(Mandatory)][float[]] $Bias
)

$ErrorActionPreference = 'Stop'
$weightCount = [long]$OutputChannels * $InputChannels * $KernelSize
# Three aligned frames in the minimal stock phoneme fixture require about
# ten million terms in the decoder's 1090-to-1024, three-tap convolution.
if (($KernelSize % 2) -ne 1 -or $weightCount * $Frames -gt 16000000 -or
    $InputTensor.Length -ne [long]$InputChannels * $Frames -or
    $WeightV.Length -ne $weightCount -or $WeightG.Length -ne $OutputChannels -or
    $Bias.Length -ne $OutputChannels) {
    throw 'Weight-normalized Conv1D shape exceeds the scalar reference contract.'
}
foreach ($values in @($InputTensor, $WeightV, $WeightG, $Bias)) {
    foreach ($value in $values) {
        if (-not [float]::IsFinite($value)) { throw 'Weight-normalized Conv1D input is non-finite.' }
    }
}
$padding = [int](($KernelSize - 1) * $Dilation / 2)
$output = [float[]]::new($OutputChannels * $Frames)
for ($outChannel = 0; $outChannel -lt $OutputChannels; $outChannel++) {
    $weightBase = $outChannel * $InputChannels * $KernelSize
    $squares = 0.0
    for ($i = 0; $i -lt $InputChannels * $KernelSize; $i++) {
        $value = [double]$WeightV[$weightBase + $i]
        $squares += $value * $value
    }
    if ($squares -eq 0.0) { throw 'Conv1D weight direction has zero norm.' }
    $scale = [double]$WeightG[$outChannel] / [Math]::Sqrt($squares)
    for ($frame = 0; $frame -lt $Frames; $frame++) {
        $sum = [double]$Bias[$outChannel]
        for ($inChannel = 0; $inChannel -lt $InputChannels; $inChannel++) {
            $inputBase = $inChannel * $Frames
            $kernelBase = $weightBase + $inChannel * $KernelSize
            for ($tap = 0; $tap -lt $KernelSize; $tap++) {
                $inputFrame = $frame - $padding + $tap * $Dilation
                if ($inputFrame -lt 0 -or $inputFrame -ge $Frames) { continue }
                $sum += [double]$InputTensor[$inputBase + $inputFrame] *
                    [double]$WeightV[$kernelBase + $tap] * $scale
            }
        }
        if (-not [double]::IsFinite($sum) -or [Math]::Abs($sum) -gt [float]::MaxValue) {
            throw 'Weight-normalized Conv1D output is non-finite.'
        }
        $output[$outChannel * $Frames + $frame] = [float]$sum
    }
}
Write-Output -NoEnumerate $output
