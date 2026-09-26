#requires -Version 7.4
# One stock AdaINResBlock1 weight-normalized Conv1d, channel-first, batch=1.
# Kokoro istftnet.py:34-78 at dfb907a02bba8152ca444717ca5d78747ccb4bec.
# PyTorch weight_norm dim=0: torch/nn/utils/parametrizations.py at
# 2b3ec34829036a65cd9d1398ea72a0167dc37470.
# Bounded scalar reference only; product execution requires direct lowering.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $InputTensor,
    [Parameter(Mandatory)][ValidateRange(1, 32768)][int] $Frames,
    [Parameter(Mandatory)][ValidateRange(1, 1024)][int] $InputChannels,
    [Parameter(Mandatory)][ValidateRange(1, 1024)][int] $OutputChannels,
    [Parameter(Mandatory)][ValidateRange(1, 31)][int] $KernelSize,
    [Parameter(Mandatory)][ValidateRange(1, 32)][int] $Dilation,
    [Parameter(Mandatory)][float[]] $WeightV,
    [Parameter(Mandatory)][float[]] $WeightG,
    [Parameter(Mandatory)][float[]] $Bias
)

$ErrorActionPreference = 'Stop'
$weightCount = [long]$OutputChannels * $InputChannels * $KernelSize
$multiplyAdds = $weightCount * $Frames
if (($KernelSize % 2) -ne 1 -or $multiplyAdds -gt 8000000 -or
    $InputTensor.Length -ne [long]$InputChannels * $Frames -or
    $WeightV.Length -ne $weightCount -or
    $WeightG.Length -ne $OutputChannels -or $Bias.Length -ne $OutputChannels) {
    throw 'AdaIN Conv1D shape is invalid or exceeds the scalar reference bound.'
}
foreach ($array in @($InputTensor, $WeightV, $WeightG, $Bias)) {
    foreach ($value in $array) {
        if (-not [float]::IsFinite($value)) { throw 'AdaIN Conv1D input is non-finite.' }
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
    if ($squares -eq 0.0) { throw 'AdaIN Conv1D weight direction has zero norm.' }
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
            throw 'AdaIN Conv1D output is non-finite.'
        }
        $output[$outChannel * $Frames + $frame] = [float]$sum
    }
}
Write-Output -NoEnumerate $output
