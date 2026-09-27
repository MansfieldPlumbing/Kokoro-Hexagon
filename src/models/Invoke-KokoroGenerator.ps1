#requires -Version 7.4
# Stock Generator.forward: harmonic source, STFT, learned generator, inverse STFT.
# kokoro/istftnet.py at dfb907a02bba8152ca444717ca5d78747ccb4bec.
# Bounded PowerShell FP32 correctness reference, not a device backend.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $InputTensor,
    [Parameter(Mandatory)][float[]] $Style,
    [Parameter(Mandatory)][float[]] $F0,
    [Parameter(Mandatory)][float[]] $SourceMergeWeights,
    [Parameter(Mandatory)][float[]] $SourceMergeBias,
    [Parameter(Mandatory)][ValidateRange(4, 512)][int] $InitialChannels,
    [Parameter(Mandatory)][System.Collections.IDictionary] $Parameters,
    [float[]] $InitialPhase,
    [float[]] $HarmonicGaussian,
    [float[]] $NoiseGaussian
)

$ErrorActionPreference = 'Stop'
if ($F0.Length -lt 2 -or $F0.Length -gt 109 -or
    $InputTensor.Length -ne [long]$InitialChannels * $F0.Length) {
    throw 'Generator decoder feature and F0 frame counts differ.'
}
$preludeArgs = @{
    F0 = $F0
    SourceMergeWeights = $SourceMergeWeights
    SourceMergeBias = $SourceMergeBias
}
if ($null -ne $InitialPhase) { $preludeArgs.InitialPhase = $InitialPhase }
if ($null -ne $HarmonicGaussian) { $preludeArgs.HarmonicGaussian = $HarmonicGaussian }
if ($null -ne $NoiseGaussian) { $preludeArgs.NoiseGaussian = $NoiseGaussian }
$source = & (Join-Path $PSScriptRoot 'Invoke-KokoroGeneratorPrelude.ps1') @preludeArgs
$result = & (Join-Path $PSScriptRoot 'Invoke-KokoroLearnedGenerator.ps1') `
    -InputTensor $InputTensor -SourceSpectrum $source.SourceSpectrum `
    -Style $Style -InputFrames $F0.Length -InitialChannels $InitialChannels `
    -Parameters $Parameters
if ($result.Samples -ne $source.ExcitationSamples -or
    $result.SpectrumFrames -ne $source.SpectrumFrames) {
    throw 'Generator source and waveform frame counts differ.'
}
$result
