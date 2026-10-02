#requires -Version 7.4
# Three-key ALBERT softmax approximation for direct scalar Hexagon lowering.
# Input scores are already max-shifted.  The approximation evaluates
# exp(x) as Taylor7(x / 64)^64 using only FP32 add and multiply operations.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $ShiftedScores,
    [bool[]] $KeyMask
)

$ErrorActionPreference = 'Stop'
if ($ShiftedScores.Length -ne 3 -or
    ($null -ne $KeyMask -and ($KeyMask.Length -ne 3 -or -not ($KeyMask -contains $true)))) {
    throw 'ALBERT shifted-softmax3 requires three scores and at least one admitted key.'
}

$hasZero = $false
for ($index = 0; $index -lt 3; $index++) {
    $score = $ShiftedScores[$index]
    if (-not [float]::IsFinite($score)) {
        throw 'ALBERT shifted-softmax3 score is non-finite.'
    }
    if ($null -ne $KeyMask -and -not $KeyMask[$index]) { continue }
    if ($score -gt 0.0 -or $score -lt -64.0) {
        throw 'ALBERT shifted-softmax3 score is outside the admitted [-64, 0] domain.'
    }
    if ($score -eq 0.0) { $hasZero = $true }
}
if (-not $hasZero) {
    throw 'ALBERT shifted-softmax3 requires an admitted zero maximum.'
}

$exponentials = [float[]]::new(3)
$coefficients = [float[]]@(
    [float](1.0 / 5040.0),
    [float](1.0 / 720.0),
    [float](1.0 / 120.0),
    [float](1.0 / 24.0),
    [float](1.0 / 6.0),
    [float]0.5,
    [float]1.0,
    [float]1.0
)
$denominator = [float]0.0
for ($index = 0; $index -lt 3; $index++) {
    if ($null -ne $KeyMask -and -not $KeyMask[$index]) { continue }
    $reduced = [float]($ShiftedScores[$index] * ([float]1.0 / [float]64.0))
    $value = $coefficients[0]
    for ($coefficient = 1; $coefficient -lt $coefficients.Length; $coefficient++) {
        $value = [float]([float]($value * $reduced) + $coefficients[$coefficient])
    }
    for ($square = 0; $square -lt 6; $square++) {
        $value = [float]($value * $value)
    }
    $exponentials[$index] = $value
    $denominator = [float]($denominator + $value)
}
if (-not [float]::IsFinite($denominator) -or $denominator -le 0.0) {
    throw 'ALBERT shifted-softmax3 denominator is invalid.'
}

$probabilities = [float[]]::new(3)
for ($index = 0; $index -lt 3; $index++) {
    if ($null -eq $KeyMask -or $KeyMask[$index]) {
        $probabilities[$index] = [float]($exponentials[$index] / $denominator)
    }
}
Write-Output -NoEnumerate $probabilities
