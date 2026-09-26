#requires -Version 7.4
# Kokoro TorchSTFT.transform: n_fft=20, hop=5, periodic Hann, centered
# reflect padding, one-sided unnormalized DFT. Kokoro istftnet.py at
# dfb907a02bba8152ca444717ca5d78747ccb4bec; PyTorch SpectralOps.cpp
# at 2b3ec34829036a65cd9d1398ea72a0167dc37470.
# Bounded batch-one FP32 correctness reference.
[CmdletBinding()]
param([Parameter(Mandatory)][float[]] $Samples)

$ErrorActionPreference = 'Stop'
$length = $Samples.Length
if ($length -le 10 -or $length -gt 32768) {
    throw 'STFT sample count exceeds the bounded reference contract.'
}
foreach ($value in $Samples) {
    if (-not [float]::IsFinite($value)) { throw 'STFT input is non-finite.' }
}
$frames = [int][Math]::Floor($length / 5) + 1
$magnitude = [float[]]::new(11 * $frames)
$phase = [float[]]::new(11 * $frames)
$window = [double[]]::new(20)
for ($tap = 0; $tap -lt 20; $tap++) {
    $window[$tap] = 0.5 - 0.5 * [Math]::Cos(2.0 * [Math]::PI * $tap / 20.0)
}
for ($frame = 0; $frame -lt $frames; $frame++) {
    $windowed = [double[]]::new(20)
    for ($tap = 0; $tap -lt 20; $tap++) {
        $sample = $frame * 5 + $tap - 10
        if ($sample -lt 0) { $sample = -$sample }
        elseif ($sample -ge $length) { $sample = 2 * $length - 2 - $sample }
        $windowed[$tap] = [double]$Samples[$sample] * $window[$tap]
    }
    for ($bin = 0; $bin -lt 11; $bin++) {
        $real = 0.0
        $imaginary = 0.0
        for ($tap = 0; $tap -lt 20; $tap++) {
            $angle = 2.0 * [Math]::PI * $bin * $tap / 20.0
            $real += $windowed[$tap] * [Math]::Cos($angle)
            $imaginary -= $windowed[$tap] * [Math]::Sin($angle)
        }
        $index = $bin * $frames + $frame
        $magnitude[$index] = [float][Math]::Sqrt($real * $real + $imaginary * $imaginary)
        $phase[$index] = [float][Math]::Atan2($imaginary, $real)
    }
}
[pscustomobject]@{
    Magnitude = $magnitude
    Phase = $phase
    Frames = $frames
    Bins = 11
}
