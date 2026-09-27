#requires -Version 7.4
# Kokoro model.py forward_with_tokens, through aligned ASR and F0/N curves.
# Source: dfb907a02bba8152ca444717ca5d78747ccb4bec.
# Bounded PowerShell FP32 correctness path; decoder/PCM are not included.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int[]] $TokenIds,
    [Parameter(Mandatory)][float[]] $VoiceRow,
    [Parameter(Mandatory)][System.Collections.IDictionary] $AlbertEmbeddings,
    [Parameter(Mandatory)][System.Collections.IDictionary] $AlbertProjection,
    [Parameter(Mandatory)][System.Collections.IDictionary] $AlbertAttention,
    [Parameter(Mandatory)][System.Collections.IDictionary] $AlbertFeedForward,
    [Parameter(Mandatory)][float[]] $BertEncoderWeights,
    [Parameter(Mandatory)][float[]] $BertEncoderBias,
    [Parameter(Mandatory)][System.Collections.IDictionary] $DurationEncoderParameters,
    [Parameter(Mandatory)][System.Collections.IDictionary] $DurationLstmParameters,
    [Parameter(Mandatory)][float[]] $DurationWeights,
    [Parameter(Mandatory)][float[]] $DurationBias,
    [Parameter(Mandatory)][System.Collections.IDictionary] $TextEncoderParameters,
    [Parameter(Mandatory)][System.Collections.IDictionary] $F0NParameters,
    [Parameter(Mandatory)][ValidateRange(0.001, 100)][double] $Speed,
    [ValidateRange(1, 12)][int] $AlbertLayerRepeats = 12,
    [ValidateRange(1, 3)][int] $DurationEncoderLayers = 3,
    [ValidateRange(1, 3)][int] $TextEncoderLayers = 3
)

$ErrorActionPreference = 'Stop'
$tokens = $TokenIds.Length
if ($tokens -lt 2 -or $tokens -gt 510 -or $VoiceRow.Length -ne 256 -or
    $TokenIds[0] -ne 0 -or $TokenIds[$tokens - 1] -ne 0) {
    throw 'Acoustic branch token boundaries or voice-row shape differ.'
}
$modelRoot = $PSScriptRoot
$stageClock = [Diagnostics.Stopwatch]::StartNew()
$durationStyle = [float[]]::new(128)
$decoderStyle = [float[]]::new(128)
[Array]::Copy($VoiceRow, 128, $durationStyle, 0, 128)
[Array]::Copy($VoiceRow, 0, $decoderStyle, 0, 128)
[float[]]$bert = & (Join-Path $modelRoot 'Invoke-KokoroAlbertEncoder.ps1') `
    -TokenIds $TokenIds -Embeddings $AlbertEmbeddings `
    -Projection $AlbertProjection -Attention $AlbertAttention `
    -FeedForward $AlbertFeedForward -LayerRepeats $AlbertLayerRepeats
Write-Verbose "ALBERT encoder completed in $($stageClock.Elapsed.TotalSeconds.ToString('F1')) s."
$stageClock.Restart()
[float[]]$tokenFeatures = & (Join-Path $modelRoot 'Invoke-KokoroLinear.ps1') `
    -InputTensor $bert -Weights $BertEncoderWeights -Bias $BertEncoderBias `
    -Rows $tokens -InputChannels 768 -OutputChannels 512
Write-Verbose "BERT projection completed in $($stageClock.Elapsed.TotalSeconds.ToString('F1')) s."
$stageClock.Restart()
$duration = & (Join-Path $modelRoot 'Invoke-KokoroDurationBranch.ps1') `
    -TokenFeatures $tokenFeatures -Style $durationStyle `
    -EncoderParameters $DurationEncoderParameters `
    -LstmParameters $DurationLstmParameters `
    -DurationWeights $DurationWeights -DurationBias $DurationBias `
    -TokenCount $tokens -Speed $Speed -EncoderLayers $DurationEncoderLayers
Write-Verbose "Duration branch completed in $($stageClock.Elapsed.TotalSeconds.ToString('F1')) s; frames=$($duration.FrameCount)."
$stageClock.Restart()
[float[]]$textTokens = & (Join-Path $modelRoot 'Invoke-KokoroTextEncoder.ps1') `
    -TokenIds $TokenIds -Parameters $TextEncoderParameters `
    -Layers $TextEncoderLayers
Write-Verbose "Text encoder completed in $($stageClock.Elapsed.TotalSeconds.ToString('F1')) s."
$stageClock.Restart()
[float[]]$alignedText = & (Join-Path $modelRoot 'Expand-KokoroAlignedFeatures.ps1') `
    -Features $textTokens -Channels 512 -TokenCount $tokens `
    -FrameToToken $duration.FrameToToken
Write-Verbose "Text alignment completed in $($stageClock.Elapsed.TotalSeconds.ToString('F1')) s."
$stageClock.Restart()
$f0n = & (Join-Path $modelRoot 'Invoke-KokoroF0NBranch.ps1') `
    -AlignedFeatures $duration.AlignedPredictorFeatures `
    -Style $durationStyle -Parameters $F0NParameters -Frames $duration.FrameCount
Write-Verbose "F0/N branch completed in $($stageClock.Elapsed.TotalSeconds.ToString('F1')) s."
[pscustomobject]@{
    TokenCount = $tokens
    FrameCount = $duration.FrameCount
    FrameToToken = $duration.FrameToToken
    AlignedTextFeatures = $alignedText
    F0 = $f0n.F0
    N = $f0n.N
    DurationStyle = $durationStyle
    DecoderStyle = $decoderStyle
}
