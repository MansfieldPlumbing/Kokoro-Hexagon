#requires -Version 7.4
# Kokoro CustomAlbert input embeddings, batch one, eval mode.
# transformers/models/albert/modeling_albert.py AlbertEmbeddings.forward at
# 8ac2b916b042b1f78b75c9eb941c0f5d2cdd8e10; Kokoro CustomAlbert in
# kokoro/modules.py at dfb907a02bba8152ca444717ca5d78747ccb4bec.
# Row-major FP32 reference, not a device execution implementation.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int[]] $TokenIds,
    [Parameter(Mandatory)][float[]] $WordWeights,
    [Parameter(Mandatory)][float[]] $PositionWeights,
    [Parameter(Mandatory)][float[]] $TokenTypeWeights,
    [Parameter(Mandatory)][float[]] $LayerNormWeight,
    [Parameter(Mandatory)][float[]] $LayerNormBias,
    [ValidateRange(1, 1024)][int] $EmbeddingSize = 128,
    [ValidateRange(1, 65536)][int] $VocabularySize = 178,
    [ValidateRange(2, 65536)][int] $MaxPositions = 512,
    [ValidateRange(1, 32)][int] $TokenTypeCount = 2,
    [int[]] $TokenTypeIds,
    [ValidateRange(0, 65535)][int] $PositionOffset = 0,
    [ValidateRange(0, 1)][double] $LayerNormEpsilon = 1e-12
)

$ErrorActionPreference = 'Stop'
$length = $TokenIds.Length
if ($length -lt 2 -or $length -gt 512 -or $length + $PositionOffset -gt $MaxPositions -or
    $WordWeights.Length -ne [long]$VocabularySize * $EmbeddingSize -or
    $PositionWeights.Length -ne [long]$MaxPositions * $EmbeddingSize -or
    $TokenTypeWeights.Length -ne [long]$TokenTypeCount * $EmbeddingSize -or
    $LayerNormWeight.Length -ne $EmbeddingSize -or
    $LayerNormBias.Length -ne $EmbeddingSize -or
    ($null -ne $TokenTypeIds -and $TokenTypeIds.Length -ne $length)) {
    throw 'ALBERT embedding shape is invalid.'
}
foreach ($weights in @($WordWeights, $PositionWeights, $TokenTypeWeights,
        $LayerNormWeight, $LayerNormBias)) {
    foreach ($value in $weights) {
        if (-not [float]::IsFinite($value)) { throw 'ALBERT embedding weight is non-finite.' }
    }
}
$result = [float[]]::new($length * $EmbeddingSize)
$row = [double[]]::new($EmbeddingSize)
for ($position = 0; $position -lt $length; $position++) {
    $wordId = $TokenIds[$position]
    $typeId = if ($null -eq $TokenTypeIds) { 0 } else { $TokenTypeIds[$position] }
    if ($wordId -lt 0 -or $wordId -ge $VocabularySize -or
        $typeId -lt 0 -or $typeId -ge $TokenTypeCount) {
        throw 'ALBERT token ID is outside the pinned embedding table.'
    }
    $sum = 0.0
    for ($dimension = 0; $dimension -lt $EmbeddingSize; $dimension++) {
        $value = [double]$WordWeights[$wordId * $EmbeddingSize + $dimension] +
            [double]$TokenTypeWeights[$typeId * $EmbeddingSize + $dimension] +
            [double]$PositionWeights[($position + $PositionOffset) * $EmbeddingSize + $dimension]
        $row[$dimension] = $value
        $sum += $value
    }
    $mean = $sum / $EmbeddingSize
    $squares = 0.0
    for ($dimension = 0; $dimension -lt $EmbeddingSize; $dimension++) {
        $difference = $row[$dimension] - $mean
        $squares += $difference * $difference
    }
    $inverseStd = 1.0 / [Math]::Sqrt($squares / $EmbeddingSize + $LayerNormEpsilon)
    for ($dimension = 0; $dimension -lt $EmbeddingSize; $dimension++) {
        $value = ($row[$dimension] - $mean) * $inverseStd *
            [double]$LayerNormWeight[$dimension] + [double]$LayerNormBias[$dimension]
        if (-not [double]::IsFinite($value) -or [Math]::Abs($value) -gt [float]::MaxValue) {
            throw 'ALBERT embedding output is non-finite.'
        }
        $result[$position * $EmbeddingSize + $dimension] = [float]$value
    }
}
Write-Output -NoEnumerate $result
