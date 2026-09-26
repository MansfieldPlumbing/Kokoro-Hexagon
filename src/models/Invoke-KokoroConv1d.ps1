#requires -Version 7.4
# Stock generator noise_conv: ordinary Conv1d, channel-first batch one.
# Kokoro kokoro/istftnet.py at dfb907a02bba8152ca444717ca5d78747ccb4bec.
# Bounded FP32 correctness reference with explicit stride and zero padding.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $InputTensor,
    [Parameter(Mandatory)][float[]] $Weights,
    [Parameter(Mandatory)][float[]] $Bias,
    [Parameter(Mandatory)][ValidateRange(1, 32768)][int] $Frames,
    [Parameter(Mandatory)][ValidateRange(1, 1024)][int] $InputChannels,
    [Parameter(Mandatory)][ValidateRange(1, 1024)][int] $OutputChannels,
    [Parameter(Mandatory)][ValidateRange(1, 31)][int] $KernelSize,
    [Parameter(Mandatory)][ValidateRange(1, 16)][int] $Stride,
    [Parameter(Mandatory)][ValidateRange(0, 31)][int] $Padding
)

$ErrorActionPreference = 'Stop'
$weightsCount = [long]$OutputChannels * $InputChannels * $KernelSize
$outputFrames = [int][Math]::Floor(($Frames + 2 * $Padding - $KernelSize) / $Stride) + 1
if ($InputTensor.Length -ne [long]$InputChannels * $Frames -or
    $Weights.Length -ne $weightsCount -or $Bias.Length -ne $OutputChannels -or
    $outputFrames -lt 1 -or $outputFrames -gt 32768 -or
    [long]$outputFrames * $weightsCount -gt 16000000) {
    throw 'Conv1D shape exceeds the bounded reference contract.'
}
foreach ($values in @($InputTensor, $Weights, $Bias)) {
    foreach ($value in $values) {
        if (-not [float]::IsFinite($value)) { throw 'Conv1D input is non-finite.' }
    }
}
$result = [float[]]::new($OutputChannels * $outputFrames)
for ($outputChannel = 0; $outputChannel -lt $OutputChannels; $outputChannel++) {
    $weightBase = $outputChannel * $InputChannels * $KernelSize
    for ($frame = 0; $frame -lt $outputFrames; $frame++) {
        $sum = [double]$Bias[$outputChannel]
        for ($inputChannel = 0; $inputChannel -lt $InputChannels; $inputChannel++) {
            $inputBase = $inputChannel * $Frames
            $tapBase = $weightBase + $inputChannel * $KernelSize
            for ($tap = 0; $tap -lt $KernelSize; $tap++) {
                $inputFrame = $frame * $Stride - $Padding + $tap
                if ($inputFrame -lt 0 -or $inputFrame -ge $Frames) { continue }
                $sum += [double]$InputTensor[$inputBase + $inputFrame] *
                    [double]$Weights[$tapBase + $tap]
            }
        }
        if (-not [double]::IsFinite($sum) -or [Math]::Abs($sum) -gt [float]::MaxValue) {
            throw 'Conv1D output is non-finite.'
        }
        $result[$outputChannel * $outputFrames + $frame] = [float]$sum
    }
}
Write-Output -NoEnumerate $result
