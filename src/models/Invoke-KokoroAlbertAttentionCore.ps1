#requires -Version 7.4
# ALBERT score -> stable softmax -> context, batch one, eval mode.
# Source contract: transformers AlbertAttention.forward at
# 8ac2b916b042b1f78b75c9eb941c0f5d2cdd8e10. FP32 oracle only.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $Query,
    [Parameter(Mandatory)][float[]] $Key,
    [Parameter(Mandatory)][float[]] $Value,
    [Parameter(Mandatory)][ValidateRange(2, 512)][int] $Tokens,
    [Parameter(Mandatory)][ValidateRange(2, 768)][int] $HiddenSize,
    [Parameter(Mandatory)][ValidateRange(1, 12)][int] $Heads,
    [bool[]] $KeyMask
)

$ErrorActionPreference = 'Stop'
$elements = [long]$Tokens * $HiddenSize
if ($HiddenSize % $Heads -ne 0 -or
    $Query.Length -ne $elements -or $Key.Length -ne $elements -or $Value.Length -ne $elements -or
    2L * $Tokens * $Tokens * $HiddenSize -gt 10000000 -or
    ($null -ne $KeyMask -and ($KeyMask.Length -ne $Tokens -or -not ($KeyMask -contains $true)))) {
    throw 'ALBERT attention-core shape exceeds the bounded reference contract.'
}
foreach ($tensor in @($Query, $Key, $Value)) {
    foreach ($element in $tensor) {
        if (-not [float]::IsFinite($element)) { throw 'ALBERT attention-core input is non-finite.' }
    }
}

$context = [float[]]::new([int]$elements)
$headWidth = [int]($HiddenSize / $Heads)
$scale = 1.0 / [Math]::Sqrt($headWidth)
$scores = [double[]]::new($Tokens)
for ($head = 0; $head -lt $Heads; $head++) {
    $headOffset = $head * $headWidth
    for ($queryToken = 0; $queryToken -lt $Tokens; $queryToken++) {
        $maxScore = [double]::NegativeInfinity
        for ($keyToken = 0; $keyToken -lt $Tokens; $keyToken++) {
            if ($null -ne $KeyMask -and -not $KeyMask[$keyToken]) {
                $scores[$keyToken] = [double]::NegativeInfinity
                continue
            }
            $dot = 0.0
            for ($dimension = 0; $dimension -lt $headWidth; $dimension++) {
                $offset = $headOffset + $dimension
                $dot += [double]$Query[$queryToken * $HiddenSize + $offset] *
                    [double]$Key[$keyToken * $HiddenSize + $offset]
            }
            $scores[$keyToken] = $dot * $scale
            $maxScore = [Math]::Max($maxScore, $scores[$keyToken])
        }
        $denominator = 0.0
        for ($keyToken = 0; $keyToken -lt $Tokens; $keyToken++) {
            if ([double]::IsNegativeInfinity($scores[$keyToken])) { continue }
            $scores[$keyToken] = [Math]::Exp($scores[$keyToken] - $maxScore)
            $denominator += $scores[$keyToken]
        }
        if ($denominator -le 0 -or -not [double]::IsFinite($denominator)) {
            throw 'ALBERT attention-core softmax is invalid.'
        }
        for ($dimension = 0; $dimension -lt $headWidth; $dimension++) {
            $offset = $headOffset + $dimension
            $sum = 0.0
            for ($keyToken = 0; $keyToken -lt $Tokens; $keyToken++) {
                if ([double]::IsNegativeInfinity($scores[$keyToken])) { continue }
                $sum += ($scores[$keyToken] / $denominator) *
                    [double]$Value[$keyToken * $HiddenSize + $offset]
            }
            if (-not [double]::IsFinite($sum) -or [Math]::Abs($sum) -gt [float]::MaxValue) {
                throw 'ALBERT attention-core output is non-finite.'
            }
            $context[$queryToken * $HiddenSize + $offset] = [float]$sum
        }
    }
}
Write-Output -NoEnumerate $context
