#requires -Version 7.4
# Kokoro Generator.forward source path up to the 22-channel harmonic spectrum.
# Source: kokoro/istftnet.py at dfb907a02bba8152ca444717ca5d78747ccb4bec.
# This is a bounded PowerShell FP32 reference, not learned-generator output.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $F0,
    [Parameter(Mandatory)][float[]] $SourceMergeWeights,
    [Parameter(Mandatory)][float[]] $SourceMergeBias,
    [float[]] $InitialPhase,
    [float[]] $HarmonicGaussian,
    [float[]] $NoiseGaussian
)

$ErrorActionPreference = 'Stop'
$modelRoot = $PSScriptRoot
$args = @{
    F0 = $F0
    MergeWeights = $SourceMergeWeights
    MergeBias = $SourceMergeBias
    UpsampleScale = 300
}
if ($null -ne $InitialPhase) { $args.InitialPhase = $InitialPhase }
if ($null -ne $HarmonicGaussian) { $args.HarmonicGaussian = $HarmonicGaussian }
if ($null -ne $NoiseGaussian) { $args.NoiseGaussian = $NoiseGaussian }
$source = & (Join-Path $modelRoot 'Invoke-KokoroSineSource.ps1') @args
$spectrum = & (Join-Path $modelRoot 'ConvertTo-KokoroStft.ps1') `
    -Samples $source.Harmonic
$expectedFrames = 60 * $F0.Length + 1
if ($spectrum.Bins -ne 11 -or $spectrum.Frames -ne $expectedFrames -or
    $spectrum.Magnitude.Length -ne 11 * $expectedFrames -or
    $spectrum.Phase.Length -ne 11 * $expectedFrames) {
    throw 'Generator source spectrum shape differs from stock configuration.'
}
$channels = [float[]]::new(22 * $expectedFrames)
[Array]::Copy($spectrum.Magnitude, $channels, 11 * $expectedFrames)
[Array]::Copy($spectrum.Phase, 0, $channels, 11 * $expectedFrames,
    11 * $expectedFrames)
[pscustomobject]@{
    SourceSpectrum = $channels
    SpectrumFrames = $expectedFrames
    ExcitationSamples = $source.Samples
    F0Frames = $F0.Length
}
