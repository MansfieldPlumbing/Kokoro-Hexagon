#requires -Version 7.4
# Generator upsample ConvTranspose1d with weight_norm(dim=0), groups=1.
# Kokoro kokoro/istftnet.py at dfb907a02bba8152ca444717ca5d78747ccb4bec;
# PyTorch ConvTranspose1d weight layout [input, output, tap] at
# 2b3ec34829036a65cd9d1398ea72a0167dc37470.
# Bounded channel-first batch-one FP32 correctness reference.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $InputTensor,
    [Parameter(Mandatory)][float[]] $WeightV,
    [Parameter(Mandatory)][float[]] $WeightG,
    [Parameter(Mandatory)][float[]] $Bias,
    [Parameter(Mandatory)][ValidateRange(1, 32768)][int] $Frames,
    [Parameter(Mandatory)][ValidateRange(1, 1024)][int] $InputChannels,
    [Parameter(Mandatory)][ValidateRange(1, 1024)][int] $OutputChannels,
    [Parameter(Mandatory)][ValidateRange(1, 31)][int] $KernelSize,
    [Parameter(Mandatory)][ValidateRange(1, 16)][int] $Stride,
    [Parameter(Mandatory)][ValidateRange(0, 31)][int] $Padding
)

$ErrorActionPreference = 'Stop'
$weights = [long]$InputChannels * $OutputChannels * $KernelSize
$outputFrames = [long]($Frames - 1) * $Stride - 2 * $Padding + $KernelSize
if ($InputTensor.Length -ne [long]$Frames * $InputChannels -or
    $WeightV.Length -ne $weights -or $WeightG.Length -ne $InputChannels -or
    $Bias.Length -ne $OutputChannels -or
    $outputFrames -lt 1 -or $outputFrames -gt 32768 -or
    $weights * $Frames -gt 16000000) {
    throw 'Transposed Conv1D shape exceeds the bounded reference contract.'
}
foreach ($values in @($InputTensor, $WeightV, $WeightG, $Bias)) {
    foreach ($value in $values) {
        if (-not [float]::IsFinite($value)) {
            throw 'Transposed Conv1D input is non-finite.'
        }
    }
}
$result = [float[]]::new([int]($outputFrames * $OutputChannels))
for ($channel = 0; $channel -lt $OutputChannels; $channel++) {
    for ($frame = 0; $frame -lt $outputFrames; $frame++) {
        $result[$channel * $outputFrames + $frame] = $Bias[$channel]
    }
}
for ($inputChannel = 0; $inputChannel -lt $InputChannels; $inputChannel++) {
    $weightBase = $inputChannel * $OutputChannels * $KernelSize
    $squares = 0.0
    for ($i = 0; $i -lt $OutputChannels * $KernelSize; $i++) {
        $value = [double]$WeightV[$weightBase + $i]
        $squares += $value * $value
    }
    if ($squares -eq 0) { throw 'Transposed Conv1D weight direction has zero norm.' }
    $scale = [double]$WeightG[$inputChannel] / [Math]::Sqrt($squares)
    for ($inputFrame = 0; $inputFrame -lt $Frames; $inputFrame++) {
        $source = [double]$InputTensor[$inputChannel * $Frames + $inputFrame] * $scale
        for ($outputChannel = 0; $outputChannel -lt $OutputChannels; $outputChannel++) {
            $tapBase = $weightBase + $outputChannel * $KernelSize
            $outputBase = $outputChannel * $outputFrames
            for ($tap = 0; $tap -lt $KernelSize; $tap++) {
                $outputFrame = $inputFrame * $Stride - $Padding + $tap
                if ($outputFrame -lt 0 -or $outputFrame -ge $outputFrames) { continue }
                $index = $outputBase + $outputFrame
                $sum = [double]$result[$index] + $source *
                    [double]$WeightV[$tapBase + $tap]
                if (-not [double]::IsFinite($sum) -or [Math]::Abs($sum) -gt [float]::MaxValue) {
                    throw 'Transposed Conv1D output is non-finite.'
                }
                $result[$index] = [float]$sum
            }
        }
    }
}
Write-Output -NoEnumerate $result
