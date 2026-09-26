#requires -Version 7.4
# Stock duration branch from 512-channel token features and style to aligned
# predictor features and frame map. Kokoro model.py forward_with_tokens and
# modules.py DurationEncoder at dfb907a02bba8152ca444717ca5d78747ccb4bec.
# Bounded PowerShell FP32 reference. This does not synthesize audio.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $TokenFeatures,
    [Parameter(Mandatory)][float[]] $Style,
    [Parameter(Mandatory)][System.Collections.IDictionary] $EncoderParameters,
    [Parameter(Mandatory)][System.Collections.IDictionary] $LstmParameters,
    [Parameter(Mandatory)][float[]] $DurationWeights,
    [Parameter(Mandatory)][float[]] $DurationBias,
    [Parameter(Mandatory)][ValidateRange(1, 512)][int] $TokenCount,
    [Parameter(Mandatory)][ValidateRange(0.001, 100)][double] $Speed,
    [ValidateRange(1, 3)][int] $EncoderLayers = 3,
    [ValidateRange(1, 65536)][int] $MaxFrames = 65536
)

$ErrorActionPreference = 'Stop'
if ($TokenFeatures.Length -ne [long]$TokenCount * 512 -or $Style.Length -ne 128) {
    throw 'Stock duration branch input shape is invalid.'
}
$modelRoot = $PSScriptRoot
[float[]]$encoded = & (Join-Path $modelRoot 'Invoke-KokoroDurationEncoder.ps1') `
    -TokenFeatures $TokenFeatures -Style $Style -Parameters $EncoderParameters `
    -Tokens $TokenCount -FeatureSize 512 -Layers $EncoderLayers
[float[]]$lstm = & (Join-Path $modelRoot 'Invoke-KokoroBidirectionalLstm.ps1') `
    -InputTensor $encoded -Parameters $LstmParameters -Frames $TokenCount `
    -InputSize 640 -HiddenSize 256
$map = & (Join-Path $modelRoot 'Invoke-KokoroDurationPrediction.ps1') `
    -LstmOutput $lstm -Weights $DurationWeights -Bias $DurationBias `
    -TokenCount $TokenCount -Speed $Speed -MaxFrames $MaxFrames
$channelMajor = [float[]]::new(640 * $TokenCount)
for ($token = 0; $token -lt $TokenCount; $token++) {
    for ($channel = 0; $channel -lt 640; $channel++) {
        $channelMajor[$channel * $TokenCount + $token] = $encoded[$token * 640 + $channel]
    }
}
[float[]]$aligned = & (Join-Path $modelRoot 'Expand-KokoroAlignedFeatures.ps1') `
    -Features $channelMajor -Channels 640 -TokenCount $TokenCount `
    -FrameToToken $map.FrameToToken
[pscustomobject]@{
    TokenCount = $TokenCount
    FrameCount = $map.FrameCount
    Counts = $map.Counts
    FrameToToken = $map.FrameToToken
    EncodedTokenFeatures = $encoded
    AlignedPredictorFeatures = $aligned
}
