#requires -Version 7.4
# Bounded FP32 oracle for a Conv1d whose frozen weight_norm is already folded.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $InputTensor,
    [Parameter(Mandatory)][ValidateRange(1, 32768)][int] $Frames,
    [Parameter(Mandatory)][ValidateRange(1, 2048)][int] $InputChannels,
    [Parameter(Mandatory)][ValidateRange(1, 2048)][int] $OutputChannels,
    [Parameter(Mandatory)][ValidateRange(1, 31)][int] $KernelSize,
    [Parameter(Mandatory)][ValidateRange(1, 32)][int] $Dilation,
    [Parameter(Mandatory)][float[]] $Weights,
    [Parameter(Mandatory)][float[]] $Bias
)

$ErrorActionPreference = 'Stop'
$weightCount = [long]$OutputChannels * $InputChannels * $KernelSize
if (($KernelSize % 2) -ne 1 -or $weightCount * $Frames -gt 16000000 -or
    $InputTensor.Length -ne [long]$InputChannels * $Frames -or
    $Weights.Length -ne $weightCount -or $Bias.Length -ne $OutputChannels) {
    throw 'Folded Conv1D shape exceeds the scalar reference contract.'
}
foreach ($values in @($InputTensor, $Weights, $Bias)) {
    foreach ($value in $values) {
        if (-not [float]::IsFinite($value)) { throw 'Folded Conv1D input is non-finite.' }
    }
}
$padding = [int](($KernelSize - 1) * $Dilation / 2)
$output = [float[]]::new($OutputChannels * $Frames)
for ($outChannel = 0; $outChannel -lt $OutputChannels; $outChannel++) {
    $weightBase = $outChannel * $InputChannels * $KernelSize
    for ($frame = 0; $frame -lt $Frames; $frame++) {
        [double]$sum = $Bias[$outChannel]
        for ($inChannel = 0; $inChannel -lt $InputChannels; $inChannel++) {
            $inputBase = $inChannel * $Frames
            $kernelBase = $weightBase + $inChannel * $KernelSize
            for ($tap = 0; $tap -lt $KernelSize; $tap++) {
                $inputFrame = $frame - $padding + $tap * $Dilation
                if ($inputFrame -ge 0 -and $inputFrame -lt $Frames) {
                    $sum += [double]$InputTensor[$inputBase + $inputFrame] * [double]$Weights[$kernelBase + $tap]
                }
            }
        }
        if (-not [double]::IsFinite($sum) -or [Math]::Abs($sum) -gt [float]::MaxValue) {
            throw 'Folded Conv1D output is non-finite.'
        }
        $output[$outChannel * $Frames + $frame] = [float]$sum
    }
}
Write-Output -NoEnumerate $output
