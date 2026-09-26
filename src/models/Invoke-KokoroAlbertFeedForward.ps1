#requires -Version 7.4
# ALBERT shared-layer feed-forward: Linear -> gelu_new -> Linear -> residual
# -> LayerNorm. transformers/models/albert/modeling_albert.py AlbertLayer and
# transformers/activations.py NewGELUActivation at
# 8ac2b916b042b1f78b75c9eb941c0f5d2cdd8e10.
# Bounded FP32 correctness reference, batch one, eval mode.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $AttentionOutput,
    [Parameter(Mandatory)][System.Collections.IDictionary] $Parameters,
    [Parameter(Mandatory)][ValidateRange(2, 512)][int] $Tokens,
    [Parameter(Mandatory)][ValidateRange(2, 768)][int] $HiddenSize,
    [Parameter(Mandatory)][ValidateRange(1, 2048)][int] $IntermediateSize,
    [ValidateRange(0, 1)][double] $LayerNormEpsilon = 1e-12
)

$ErrorActionPreference = 'Stop'
if ($AttentionOutput.Length -ne [long]$Tokens * $HiddenSize -or
    2L * $Tokens * $HiddenSize * $IntermediateSize -gt 10000000) {
    throw 'ALBERT feed-forward shape exceeds the bounded reference contract.'
}
$shapes = @{
    'ffn.weight' = [long]$IntermediateSize * $HiddenSize
    'ffn.bias' = $IntermediateSize
    'ffn_output.weight' = [long]$HiddenSize * $IntermediateSize
    'ffn_output.bias' = $HiddenSize
    'full_layer_layer_norm.weight' = $HiddenSize
    'full_layer_layer_norm.bias' = $HiddenSize
}
foreach ($entry in $shapes.GetEnumerator()) {
    if (-not $Parameters.Contains($entry.Key) -or
        $Parameters[$entry.Key] -isnot [float[]] -or
        $Parameters[$entry.Key].Length -ne $entry.Value) {
        throw "ALBERT feed-forward parameter shape is invalid: $($entry.Key)"
    }
}
foreach ($value in $AttentionOutput) {
    if (-not [float]::IsFinite($value)) { throw 'ALBERT feed-forward input is non-finite.' }
}
foreach ($name in $shapes.Keys) {
    foreach ($value in $Parameters[$name]) {
        if (-not [float]::IsFinite($value)) { throw 'ALBERT feed-forward weight is non-finite.' }
    }
}
$result = [float[]]::new($AttentionOutput.Length)
$intermediate = [double[]]::new($IntermediateSize)
$residual = [double[]]::new($HiddenSize)
$geluScale = [Math]::Sqrt(2.0 / [Math]::PI)
for ($token = 0; $token -lt $Tokens; $token++) {
    for ($row = 0; $row -lt $IntermediateSize; $row++) {
        $sum = [double]$Parameters['ffn.bias'][$row]
        for ($column = 0; $column -lt $HiddenSize; $column++) {
            $sum += [double]$AttentionOutput[$token * $HiddenSize + $column] *
                [double]$Parameters['ffn.weight'][$row * $HiddenSize + $column]
        }
        $intermediate[$row] = 0.5 * $sum *
            (1.0 + [Math]::Tanh($geluScale * ($sum + 0.044715 * $sum * $sum * $sum)))
    }
    $mean = 0.0
    for ($row = 0; $row -lt $HiddenSize; $row++) {
        $sum = [double]$Parameters['ffn_output.bias'][$row] +
            [double]$AttentionOutput[$token * $HiddenSize + $row]
        for ($column = 0; $column -lt $IntermediateSize; $column++) {
            $sum += $intermediate[$column] *
                [double]$Parameters['ffn_output.weight'][$row * $IntermediateSize + $column]
        }
        $residual[$row] = $sum
        $mean += $sum
    }
    $mean /= $HiddenSize
    $variance = 0.0
    for ($row = 0; $row -lt $HiddenSize; $row++) {
        $difference = $residual[$row] - $mean
        $variance += $difference * $difference
    }
    $inverseStd = 1.0 / [Math]::Sqrt($variance / $HiddenSize + $LayerNormEpsilon)
    for ($row = 0; $row -lt $HiddenSize; $row++) {
        $output = ($residual[$row] - $mean) * $inverseStd *
            [double]$Parameters['full_layer_layer_norm.weight'][$row] +
            [double]$Parameters['full_layer_layer_norm.bias'][$row]
        if (-not [double]::IsFinite($output) -or [Math]::Abs($output) -gt [float]::MaxValue) {
            throw 'ALBERT feed-forward output is non-finite.'
        }
        $result[$token * $HiddenSize + $row] = [float]$output
    }
}
Write-Output -NoEnumerate $result
