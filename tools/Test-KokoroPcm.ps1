#requires -Version 7.4
# Analytic DC-spectrum gate for stock centered TorchSTFT inverse semantics.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$converter = Join-Path $PSScriptRoot '../src/models/ConvertTo-KokoroPcm.ps1'
$frames = 5
$stride = 6 # One padded frame must not enter the inverse.
$post = [float[]]::new(22 * $stride)
for ($bin = 0; $bin -lt 11; $bin++) {
    for ($frame = 0; $frame -lt $stride; $frame++) {
        $post[$bin * $stride + $frame] = if ($bin -eq 0 -and $frame -lt $frames) { 0.0 } else { -20.0 }
    }
}

[float[]]$pcm = & $converter -Post $post -Frames $frames -FrameStride $stride
if ($pcm.Length -ne 20) { throw "Expected 20 samples, got $($pcm.Length)." }

# An isolated DC bin has inverse-DFT value 1/20 in every frame. The tiny
# non-DC bins (exp(-20)) keep the input finite and add <1e-7 at this scale.
for ($i = 0; $i -lt $pcm.Length; $i++) {
    $position = 10 + $i
    $windowSum = 0.0
    $windowSquares = 0.0
    for ($frame = 0; $frame -lt $frames; $frame++) {
        $n = $position - 5 * $frame
        if ($n -lt 0 -or $n -ge 20) { continue }
        $window = 0.5 - 0.5 * [Math]::Cos(2.0 * [Math]::PI * $n / 20)
        $windowSum += $window
        $windowSquares += $window * $window
    }
    $expected = $windowSum / (20.0 * $windowSquares)
    if ([Math]::Abs([double]$pcm[$i] - $expected) -gt 1e-6) {
        throw "Stock iSTFT normalization differs at sample $i."
    }
}

if ([Math]::Abs([double]$pcm[0] - 0.06) -gt 1e-6) {
    throw 'The centered first sample did not include squared-window normalization.'
}

# A single interior bin exercises Hermitian doubling and the phase sign.
$phasePost = [float[]]::new($post.Length)
[Array]::Copy($post, $phasePost, $post.Length)
for ($frame = 0; $frame -lt $frames; $frame++) {
    $phasePost[$frame] = -20.0
    $phasePost[$stride + $frame] = 0.0
    $phasePost[(11 + 1) * $stride + $frame] = 0.5
}
[float[]]$phasePcm = & $converter -Post $phasePost -Frames $frames -FrameStride $stride
$phase = [Math]::Sin(0.5)
$phaseExpected = (-2.0 * [Math]::Cos($phase) - [Math]::Sin($phase)) / 25.0
if ([Math]::Abs([double]$phasePcm[0] - $phaseExpected) -gt 1e-6) {
    throw 'The interior-bin inverse phase or Hermitian factor differs.'
}

[float[]]$short = & $converter -Post $post -Frames $frames -FrameStride $stride -OutputSamples 7
if ($short.Length -ne 7) { throw 'Requested output length was not honored.' }

$bad = [float[]]::new($post.Length)
[Array]::Copy($post, $bad, $post.Length)
$bad[0] = [float]::NaN
$rejected = $false
try { $null = & $converter -Post $bad -Frames $frames -FrameStride $stride } catch { $rejected = $true }
if (-not $rejected) { throw 'Non-finite generator output was accepted.' }

Write-Output 'PASS: centered stock iSTFT envelope, phase, padding, length, finite-input gate'
