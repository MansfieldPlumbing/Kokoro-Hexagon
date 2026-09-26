#requires -Version 7.4
# Kokoro TorchSTFT.inverse: one-sided complex iDFT, periodic Hann,
# overlap-add, squared-window envelope, centered trimming. Source:
# kokoro/istftnet.py at dfb907a02bba8152ca444717ca5d78747ccb4bec;
# PyTorch aten/src/ATen/native/SpectralOps.cpp:1044-1220 at
# 2b3ec34829036a65cd9d1398ea72a0167dc37470.
# Bounded batch-one FP32 correctness reference.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $Magnitude,
    [Parameter(Mandatory)][float[]] $Phase,
    [Parameter(Mandatory)][ValidateRange(3, 6554)][int] $Frames
)

$ErrorActionPreference = 'Stop'
if ($Magnitude.Length -ne [long]11 * $Frames -or
    $Phase.Length -ne [long]11 * $Frames) {
    throw 'Inverse STFT spectrum shape is invalid.'
}
foreach ($values in @($Magnitude, $Phase)) {
    foreach ($value in $values) {
        if (-not [float]::IsFinite($value)) {
            throw 'Inverse STFT input is non-finite.'
        }
    }
}
$rawLength = 20 + 5 * ($Frames - 1)
$accumulated = [double[]]::new($rawLength)
$envelope = [double[]]::new($rawLength)
$window = [double[]]::new(20)
for ($tap = 0; $tap -lt 20; $tap++) {
    $window[$tap] = 0.5 - 0.5 * [Math]::Cos(2.0 * [Math]::PI * $tap / 20.0)
}
for ($frame = 0; $frame -lt $Frames; $frame++) {
    $real = [double[]]::new(11)
    $imaginary = [double[]]::new(11)
    for ($bin = 0; $bin -lt 11; $bin++) {
        $index = $bin * $Frames + $frame
        $real[$bin] = [double]$Magnitude[$index] * [Math]::Cos([double]$Phase[$index])
        $imaginary[$bin] = [double]$Magnitude[$index] * [Math]::Sin([double]$Phase[$index])
    }
    for ($tap = 0; $tap -lt 20; $tap++) {
        $value = $real[0] + $(if ($tap % 2 -eq 0) { $real[10] } else { -$real[10] })
        for ($bin = 1; $bin -lt 10; $bin++) {
            $angle = 2.0 * [Math]::PI * $bin * $tap / 20.0
            $value += 2.0 * ($real[$bin] * [Math]::Cos($angle) -
                $imaginary[$bin] * [Math]::Sin($angle))
        }
        $value /= 20.0
        $position = $frame * 5 + $tap
        $accumulated[$position] += $value * $window[$tap]
        $envelope[$position] += $window[$tap] * $window[$tap]
    }
}
$length = 5 * ($Frames - 1)
$result = [float[]]::new($length)
for ($sample = 0; $sample -lt $length; $sample++) {
    $position = 10 + $sample
    if ($envelope[$position] -lt 1e-11) {
        throw 'Inverse STFT window overlap-add envelope is singular.'
    }
    $value = $accumulated[$position] / $envelope[$position]
    if (-not [double]::IsFinite($value) -or [Math]::Abs($value) -gt [float]::MaxValue) {
        throw 'Inverse STFT output is non-finite.'
    }
    $result[$sample] = [float]$value
}
Write-Output -NoEnumerate $result
