#requires -Version 7.4
# ALBERT self-attention, batch one, eval mode, absolute positions.
# transformers/models/albert/modeling_albert.py AlbertAttention.forward at
# 8ac2b916b042b1f78b75c9eb941c0f5d2cdd8e10.
# Bounded FP32 correctness reference; not a device implementation.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $HiddenStates,
    [Parameter(Mandatory)][System.Collections.IDictionary] $Parameters,
    [Parameter(Mandatory)][ValidateRange(2, 512)][int] $Tokens,
    [Parameter(Mandatory)][ValidateRange(2, 768)][int] $HiddenSize,
    [Parameter(Mandatory)][ValidateRange(1, 12)][int] $Heads,
    [bool[]] $KeyMask,
    [ValidateRange(0, 1)][double] $LayerNormEpsilon = 1e-12
)

$ErrorActionPreference = 'Stop'
if ($HiddenSize % $Heads -ne 0 -or $HiddenStates.Length -ne [long]$Tokens * $HiddenSize -or
    4L * $Tokens * $HiddenSize * $HiddenSize + 2L * $Tokens * $Tokens * $HiddenSize -gt 10000000 -or
    ($null -ne $KeyMask -and ($KeyMask.Length -ne $Tokens -or -not ($KeyMask -contains $true)))) {
    throw 'ALBERT attention shape exceeds the bounded reference contract.'
}
foreach ($name in @('query', 'key', 'value', 'dense')) {
    foreach ($suffix in @('weight', 'bias')) {
        $keyName = "$name.$suffix"
        $expected = if ($suffix -eq 'weight') { [long]$HiddenSize * $HiddenSize } else { $HiddenSize }
        if (-not $Parameters.Contains($keyName) -or
            $Parameters[$keyName] -isnot [float[]] -or
            $Parameters[$keyName].Length -ne $expected) {
            throw "ALBERT attention parameter shape is invalid: $keyName"
        }
    }
}
foreach ($suffix in @('weight', 'bias')) {
    $keyName = "LayerNorm.$suffix"
    if (-not $Parameters.Contains($keyName) -or
        $Parameters[$keyName] -isnot [float[]] -or
        $Parameters[$keyName].Length -ne $HiddenSize) {
        throw "ALBERT attention parameter shape is invalid: $keyName"
    }
}
foreach ($value in $HiddenStates) {
    if (-not [float]::IsFinite($value)) { throw 'ALBERT attention input is non-finite.' }
}
foreach ($name in @('query.weight', 'query.bias', 'key.weight', 'key.bias',
        'value.weight', 'value.bias', 'dense.weight', 'dense.bias',
        'LayerNorm.weight', 'LayerNorm.bias')) {
    foreach ($value in $Parameters[$name]) {
        if (-not [float]::IsFinite($value)) { throw 'ALBERT attention parameter is non-finite.' }
    }
}

function Invoke-Linear([float[]] $InputTensor, [float[]] $Weights, [float[]] $Bias) {
    $output = [float[]]::new($InputTensor.Length)
    for ($token = 0; $token -lt $Tokens; $token++) {
        for ($row = 0; $row -lt $HiddenSize; $row++) {
            $sum = [double]$Bias[$row]
            for ($column = 0; $column -lt $HiddenSize; $column++) {
                $sum += [double]$InputTensor[$token * $HiddenSize + $column] *
                    [double]$Weights[$row * $HiddenSize + $column]
            }
            $output[$token * $HiddenSize + $row] = [float]$sum
        }
    }
    return ,$output
}
$query = Invoke-Linear $HiddenStates $Parameters['query.weight'] $Parameters['query.bias']
$key = Invoke-Linear $HiddenStates $Parameters['key.weight'] $Parameters['key.bias']
$value = Invoke-Linear $HiddenStates $Parameters['value.weight'] $Parameters['value.bias']
$maskArguments = @{}
if ($null -ne $KeyMask) { $maskArguments.KeyMask = $KeyMask }
$context = & (Join-Path $PSScriptRoot 'Invoke-KokoroAlbertAttentionCore.ps1') `
    -Query $query -Key $key -Value $value -Tokens $Tokens `
    -HiddenSize $HiddenSize -Heads $Heads @maskArguments
$projected = Invoke-Linear $context $Parameters['dense.weight'] $Parameters['dense.bias']
$result = [float[]]::new($HiddenStates.Length)
for ($token = 0; $token -lt $Tokens; $token++) {
    $mean = 0.0
    for ($dimension = 0; $dimension -lt $HiddenSize; $dimension++) {
        $mean += [double]$HiddenStates[$token * $HiddenSize + $dimension] +
            [double]$projected[$token * $HiddenSize + $dimension]
    }
    $mean /= $HiddenSize
    $variance = 0.0
    for ($dimension = 0; $dimension -lt $HiddenSize; $dimension++) {
        $difference = [double]$HiddenStates[$token * $HiddenSize + $dimension] +
            [double]$projected[$token * $HiddenSize + $dimension] - $mean
        $variance += $difference * $difference
    }
    $inverseStd = 1.0 / [Math]::Sqrt($variance / $HiddenSize + $LayerNormEpsilon)
    for ($dimension = 0; $dimension -lt $HiddenSize; $dimension++) {
        $normalized = ([double]$HiddenStates[$token * $HiddenSize + $dimension] +
            [double]$projected[$token * $HiddenSize + $dimension] - $mean) * $inverseStd
        $output = $normalized * [double]$Parameters['LayerNorm.weight'][$dimension] +
            [double]$Parameters['LayerNorm.bias'][$dimension]
        if (-not [double]::IsFinite($output) -or [Math]::Abs($output) -gt [float]::MaxValue) {
            throw 'ALBERT attention output is non-finite.'
        }
        $result[$token * $HiddenSize + $dimension] = [float]$output
    }
}
Write-Output -NoEnumerate $result
