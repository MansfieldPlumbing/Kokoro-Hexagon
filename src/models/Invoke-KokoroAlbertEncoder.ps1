#requires -Version 7.4
# Kokoro CustomAlbert batch-one eval path through the shared ALBERT layer.
# Kokoro model.py forward_with_tokens and modules.py CustomAlbert at
# dfb907a02bba8152ca444717ca5d78747ccb4bec; AlbertModel and
# AlbertTransformer.forward at Transformers
# 8ac2b916b042b1f78b75c9eb941c0f5d2cdd8e10.
# This bounded FP32 reference excludes the unused pooler and does not lower.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int[]] $TokenIds,
    [Parameter(Mandatory)][System.Collections.IDictionary] $Embeddings,
    [Parameter(Mandatory)][System.Collections.IDictionary] $Projection,
    [Parameter(Mandatory)][System.Collections.IDictionary] $Attention,
    [Parameter(Mandatory)][System.Collections.IDictionary] $FeedForward,
    [ValidateRange(1, 1024)][int] $EmbeddingSize = 128,
    [ValidateRange(2, 768)][int] $HiddenSize = 768,
    [ValidateRange(1, 2048)][int] $IntermediateSize = 2048,
    [ValidateRange(1, 12)][int] $Heads = 12,
    [ValidateRange(1, 12)][int] $LayerRepeats = 12,
    [ValidateRange(1, 65536)][int] $VocabularySize = 178,
    [ValidateRange(2, 65536)][int] $MaxPositions = 512,
    [ValidateRange(1, 32)][int] $TokenTypeCount = 2
)

$ErrorActionPreference = 'Stop'
$modelRoot = $PSScriptRoot
$length = $TokenIds.Length
if ($length -lt 2 -or $length -gt 512) { throw 'ALBERT token length is invalid.' }
foreach ($name in @('word.weight', 'position.weight', 'token_type.weight',
        'LayerNorm.weight', 'LayerNorm.bias')) {
    if (-not $Embeddings.Contains($name) -or $Embeddings[$name] -isnot [float[]]) {
        throw "ALBERT embedding parameter is absent: $name"
    }
}
foreach ($name in @('weight', 'bias')) {
    if (-not $Projection.Contains($name) -or $Projection[$name] -isnot [float[]]) {
        throw "ALBERT projection parameter is absent: $name"
    }
}
[float[]]$state = & (Join-Path $modelRoot 'Invoke-KokoroAlbertEmbeddings.ps1') `
    -TokenIds $TokenIds -WordWeights $Embeddings['word.weight'] `
    -PositionWeights $Embeddings['position.weight'] `
    -TokenTypeWeights $Embeddings['token_type.weight'] `
    -LayerNormWeight $Embeddings['LayerNorm.weight'] `
    -LayerNormBias $Embeddings['LayerNorm.bias'] `
    -EmbeddingSize $EmbeddingSize -VocabularySize $VocabularySize `
    -MaxPositions $MaxPositions -TokenTypeCount $TokenTypeCount
[float[]]$state = & (Join-Path $modelRoot 'Invoke-KokoroAlbertEmbeddingProjection.ps1') `
    -Embeddings $state -Weights $Projection['weight'] -Bias $Projection['bias'] `
    -Tokens $length -EmbeddingSize $EmbeddingSize -HiddenSize $HiddenSize
for ($layer = 0; $layer -lt $LayerRepeats; $layer++) {
    [float[]]$state = & (Join-Path $modelRoot 'Invoke-KokoroAlbertAttention.ps1') `
        -HiddenStates $state -Parameters $Attention -Tokens $length `
        -HiddenSize $HiddenSize -Heads $Heads
    [float[]]$state = & (Join-Path $modelRoot 'Invoke-KokoroAlbertFeedForward.ps1') `
        -AttentionOutput $state -Parameters $FeedForward -Tokens $length `
        -HiddenSize $HiddenSize -IntermediateSize $IntermediateSize
}
Write-Output -NoEnumerate $state
