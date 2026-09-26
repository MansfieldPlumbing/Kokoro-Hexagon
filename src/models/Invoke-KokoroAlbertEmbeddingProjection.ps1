#requires -Version 7.4
# ALBERT embedding_hidden_mapping_in from the pinned Transformers source.
# transformers/models/albert/modeling_albert.py AlbertTransformer.forward at
# 8ac2b916b042b1f78b75c9eb941c0f5d2cdd8e10.
# Row-major FP32 reference for batch one; no device lowering.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $Embeddings,
    [Parameter(Mandatory)][float[]] $Weights,
    [Parameter(Mandatory)][float[]] $Bias,
    [Parameter(Mandatory)][ValidateRange(2, 512)][int] $Tokens,
    [ValidateRange(1, 1024)][int] $EmbeddingSize = 128,
    [ValidateRange(1, 4096)][int] $HiddenSize = 768
)

$ErrorActionPreference = 'Stop'
if ($Embeddings.Length -ne [long]$Tokens * $EmbeddingSize -or
    $Weights.Length -ne [long]$HiddenSize * $EmbeddingSize -or
    $Bias.Length -ne $HiddenSize) {
    throw 'ALBERT embedding projection shape is invalid.'
}
foreach ($values in @($Embeddings, $Weights, $Bias)) {
    foreach ($value in $values) {
        if (-not [float]::IsFinite($value)) {
            throw 'ALBERT embedding projection input is non-finite.'
        }
    }
}
$result = [float[]]::new($Tokens * $HiddenSize)
for ($token = 0; $token -lt $Tokens; $token++) {
    $inputBase = $token * $EmbeddingSize
    $outputBase = $token * $HiddenSize
    for ($output = 0; $output -lt $HiddenSize; $output++) {
        $weightBase = $output * $EmbeddingSize
        $sum = [double]$Bias[$output]
        for ($input = 0; $input -lt $EmbeddingSize; $input++) {
            $sum += [double]$Embeddings[$inputBase + $input] *
                [double]$Weights[$weightBase + $input]
        }
        if (-not [double]::IsFinite($sum) -or [Math]::Abs($sum) -gt [float]::MaxValue) {
            throw 'ALBERT embedding projection output is non-finite.'
        }
        $result[$outputBase + $output] = [float]$sum
    }
}
Write-Output -NoEnumerate $result
