#requires -Version 7.4
# Stock KModel.forward_with_tokens: admitted token IDs and voice row to PCM.
# kokoro/model.py and kokoro/istftnet.py at
# dfb907a02bba8152ca444717ca5d78747ccb4bec.
# Bounded PowerShell FP32 reference; no device or performance claim.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int[]] $TokenIds,
    [Parameter(Mandatory)][float[]] $VoiceRow,
    [Parameter(Mandatory)][ValidateRange(0.001, 100)][double] $Speed,
    [Parameter(Mandatory)][psobject] $AcousticWeights,
    [Parameter(Mandatory)][psobject] $DecoderWeights,
    [Parameter(Mandatory)][psobject] $GeneratorWeights,
    [float[]] $InitialPhase,
    [float[]] $HarmonicGaussian,
    [float[]] $NoiseGaussian
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$pin = @(([IO.File]::ReadAllText((Join-Path $root 'lib/manifest.json')) |
    ConvertFrom-Json -AsHashtable).model.files | Where-Object { $_.path -ceq 'kokoro-v1_0.pth' })
if ($pin.Count -ne 1) { throw 'Stock checkpoint pin is not unique.' }
if ($TokenIds.Length -lt 2 -or $TokenIds.Length -gt 510 -or
    $TokenIds[0] -ne 0 -or $TokenIds[$TokenIds.Length - 1] -ne 0 -or
    $VoiceRow.Length -ne 256 -or
    $AcousticWeights.TensorCount -ne 171 -or
    $DecoderWeights.TensorCount -ne 72 -or
    $GeneratorWeights.TensorCount -ne 303 -or
    $AcousticWeights.CheckpointSha256 -cne $pin[0].sha256 -or
    $DecoderWeights.CheckpointSha256 -cne $pin[0].sha256 -or
    $GeneratorWeights.CheckpointSha256 -cne $pin[0].sha256 -or
    $DecoderWeights.PreludeParameters -isnot [System.Collections.IDictionary] -or
    $DecoderWeights.CoreParameters -isnot [System.Collections.IDictionary] -or
    $GeneratorWeights.Parameters -isnot [System.Collections.IDictionary]) {
    throw 'Phoneme-to-PCM admission or verified model-weight map is incomplete.'
}
foreach ($value in $VoiceRow) {
    if (-not [float]::IsFinite($value)) { throw 'Voice row is non-finite.' }
}
$modelRoot = $PSScriptRoot
$acoustic = & (Join-Path $modelRoot 'Invoke-KokoroAcousticBranches.ps1') `
    -TokenIds $TokenIds -VoiceRow $VoiceRow `
    -AlbertEmbeddings $AcousticWeights.AlbertEmbeddings `
    -AlbertProjection $AcousticWeights.AlbertProjection `
    -AlbertAttention $AcousticWeights.AlbertAttention `
    -AlbertFeedForward $AcousticWeights.AlbertFeedForward `
    -BertEncoderWeights $AcousticWeights.BertEncoderWeights `
    -BertEncoderBias $AcousticWeights.BertEncoderBias `
    -DurationEncoderParameters $AcousticWeights.DurationEncoderParameters `
    -DurationLstmParameters $AcousticWeights.DurationLstmParameters `
    -DurationWeights $AcousticWeights.DurationWeights `
    -DurationBias $AcousticWeights.DurationBias `
    -TextEncoderParameters $AcousticWeights.TextEncoderParameters `
    -F0NParameters $AcousticWeights.F0NParameters `
    -Speed $Speed -AlbertLayerRepeats 12 -DurationEncoderLayers 3 `
    -TextEncoderLayers 3
Write-Verbose 'Full stock acoustic branches completed.'
if ($acoustic.FrameCount -lt 2 -or $acoustic.FrameCount -gt 54 -or
    $acoustic.F0.Length -ne 2 * $acoustic.FrameCount -or
    $acoustic.N.Length -ne 2 * $acoustic.FrameCount -or
    $acoustic.AlignedTextFeatures.Length -ne 512 * $acoustic.FrameCount -or
    $acoustic.DecoderStyle.Length -ne 128) {
    throw 'Acoustic output exceeds the bounded decoder/generator reference.'
}
$prelude = & (Join-Path $modelRoot 'Invoke-KokoroDecoderPrelude.ps1') `
    -AlignedTextFeatures $acoustic.AlignedTextFeatures `
    -F0 $acoustic.F0 -N $acoustic.N `
    -Parameters $DecoderWeights.PreludeParameters -Frames $acoustic.FrameCount
Write-Verbose 'Decoder prelude completed.'
$core = & (Join-Path $modelRoot 'Invoke-KokoroDecoderCore.ps1') `
    -Prelude $prelude -Style $acoustic.DecoderStyle `
    -Parameters $DecoderWeights.CoreParameters
Write-Verbose 'Decoder core completed.'
if ($core.Frames -ne $acoustic.F0.Length -or $core.Channels -ne 512 -or
    $core.Features.Length -ne 512 * $core.Frames) {
    throw 'Decoder features and generator F0 frames differ.'
}
$generatorArgs = @{
    InputTensor = $core.Features
    Style = $acoustic.DecoderStyle
    F0 = $acoustic.F0
    SourceMergeWeights = $GeneratorWeights.SourceMergeWeights
    SourceMergeBias = $GeneratorWeights.SourceMergeBias
    InitialChannels = 512
    Parameters = $GeneratorWeights.Parameters
}
if ($null -ne $InitialPhase) { $generatorArgs.InitialPhase = $InitialPhase }
if ($null -ne $HarmonicGaussian) { $generatorArgs.HarmonicGaussian = $HarmonicGaussian }
if ($null -ne $NoiseGaussian) { $generatorArgs.NoiseGaussian = $NoiseGaussian }
$waveform = & (Join-Path $modelRoot 'Invoke-KokoroGenerator.ps1') @generatorArgs
Write-Verbose 'Learned generator and inverse STFT completed.'
if ($waveform.Samples -ne 300 * $acoustic.F0.Length) {
    throw 'Waveform sample count differs from the stock 300x F0 clock.'
}
[pscustomobject]@{
    Pcm = $waveform.Pcm
    SampleRate = 24000
    Samples = $waveform.Samples
    DurationFrames = $acoustic.FrameCount
    TokenCount = $TokenIds.Length
}
