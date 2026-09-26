#requires -Version 7.4
# Stock Kokoro generator spectral head -> centered TorchSTFT.inverse -> float PCM.
# Source: kokoro/istftnet.py:80-100,323-325 at
# dfb907a02bba8152ca444717ca5d78747ccb4bec; PyTorch
# aten/src/ATen/native/SpectralOps.cpp:1158-1212 at
# 2b3ec34829036a65cd9d1398ea72a0167dc37470.
# This is a bounded scalar reference stage, not a Hexagon performance path.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $Post,
    [Parameter(Mandatory)][ValidateRange(2, 65536)][int] $Frames,
    [Parameter(Mandatory)][ValidateRange(2, 65536)][int] $FrameStride,
    [ValidateRange(0, 327675)][int] $OutputSamples = 0
)

$ErrorActionPreference = 'Stop'
if ($FrameStride -lt $Frames) { throw 'FrameStride is smaller than Frames.' }

# The pinned stock config fixes the waveform head at 20/5. The generator
# emits 11 log-magnitude channels followed by 11 phase channels, bin-major.
$nfft = 20
$hop = 5
$bins = 11
if ($Post.Length -ne 2 * $bins * $FrameStride) {
    throw 'Generator post tensor shape is not [22, FrameStride].'
}
$defaultSamples = ($Frames - 1) * $hop
if ($OutputSamples -eq 0) { $OutputSamples = $defaultSamples }
if ($OutputSamples -gt $defaultSamples) {
    throw 'Requested PCM length exceeds the centered inverse length.'
}

$window = [double[]]::new($nfft)
for ($n = 0; $n -lt $nfft; $n++) {
    $window[$n] = [float](0.5 - 0.5 * [Math]::Cos(2.0 * [Math]::PI * $n / $nfft))
}
$rawLength = $nfft + ($Frames - 1) * $hop
$sum = [double[]]::new($rawLength)
$envelope = [double[]]::new($rawLength)
$real = [double[]]::new($bins)
$imag = [double[]]::new($bins)

for ($frame = 0; $frame -lt $Frames; $frame++) {
    for ($bin = 0; $bin -lt $bins; $bin++) {
        $logMagnitude = [double]$Post[$bin * $FrameStride + $frame]
        $phaseSource = [double]$Post[($bin + $bins) * $FrameStride + $frame]
        if (-not [double]::IsFinite($logMagnitude) -or
            -not [double]::IsFinite($phaseSource)) {
            throw 'Generator post tensor contains a non-finite value.'
        }
        $magnitude = [Math]::Exp($logMagnitude)
        if (-not [double]::IsFinite($magnitude)) {
            throw 'Generator post magnitude overflowed.'
        }
        $phase = [Math]::Sin($phaseSource)
        $real[$bin] = $magnitude * [Math]::Cos($phase)
        $imag[$bin] = $magnitude * [Math]::Sin($phase)
    }

    $base = $frame * $hop
    for ($n = 0; $n -lt $nfft; $n++) {
        # Even-size onesided c2r: DC and Nyquist occur once, interior bins twice.
        $sample = $real[0] + $(if (($n % 2) -eq 0) { $real[$bins - 1] } else { -$real[$bins - 1] })
        for ($bin = 1; $bin -lt ($bins - 1); $bin++) {
            $angle = 2.0 * [Math]::PI * $bin * $n / $nfft
            $sample += 2.0 * ($real[$bin] * [Math]::Cos($angle) -
                $imag[$bin] * [Math]::Sin($angle))
        }
        $position = $base + $n
        $sum[$position] += ($sample / $nfft) * $window[$n]
        $envelope[$position] += $window[$n] * $window[$n]
    }
}

$pcm = [float[]]::new($OutputSamples)
$center = $nfft / 2
for ($i = 0; $i -lt $OutputSamples; $i++) {
    $position = $center + $i
    if ($envelope[$position] -lt 1e-11) {
        throw 'The inverse window overlap-add envelope is zero.'
    }
    $value = $sum[$position] / $envelope[$position]
    if (-not [double]::IsFinite($value) -or [Math]::Abs($value) -gt [float]::MaxValue) {
        throw 'Generated PCM contains a non-finite value.'
    }
    $pcm[$i] = [float]$value
}

Write-Output -NoEnumerate $pcm
