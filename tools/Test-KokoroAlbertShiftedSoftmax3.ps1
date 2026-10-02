#requires -Version 7.4
[CmdletBinding()]
param(
    [string] $QkvFixture = (Join-Path $PSScriptRoot '..\build\albert-qkv-vector-fixture-001\expected.f32')
)

$ErrorActionPreference = 'Stop'
$operator = Join-Path $PSScriptRoot '..\src\models\Invoke-KokoroAlbertShiftedSoftmax3.ps1'

function Get-ExactSoftmax3 {
    param([float[]] $Scores, [bool[]] $Mask)
    $maximum = [double]::NegativeInfinity
    for ($index = 0; $index -lt 3; $index++) {
        if ($null -eq $Mask -or $Mask[$index]) { $maximum = [Math]::Max($maximum, $Scores[$index]) }
    }
    $values = [double[]]::new(3)
    $sum = 0.0
    for ($index = 0; $index -lt 3; $index++) {
        if ($null -ne $Mask -and -not $Mask[$index]) { continue }
        $values[$index] = [Math]::Exp([double]$Scores[$index] - $maximum)
        $sum += $values[$index]
    }
    [double[]]@(($values[0] / $sum), ($values[1] / $sum), ($values[2] / $sum))
}

function Test-OneSoftmax3 {
    param([float[]] $Scores, [bool[]] $Mask)
    $maximum = [float]::NegativeInfinity
    for ($index = 0; $index -lt 3; $index++) {
        if ($null -eq $Mask -or $Mask[$index]) { $maximum = [Math]::Max($maximum, $Scores[$index]) }
    }
    $shifted = [float[]]::new(3)
    for ($index = 0; $index -lt 3; $index++) {
        if ($null -eq $Mask -or $Mask[$index]) { $shifted[$index] = [float]($Scores[$index] - $maximum) }
    }
    $actual = if ($null -eq $Mask) {
        & $operator -ShiftedScores $shifted
    } else {
        & $operator -ShiftedScores $shifted -KeyMask $Mask
    }
    $expected = Get-ExactSoftmax3 $Scores $Mask
    $maximumError = 0.0
    $sum = 0.0
    for ($index = 0; $index -lt 3; $index++) {
        $maximumError = [Math]::Max($maximumError, [Math]::Abs([double]$actual[$index] - $expected[$index]))
        $sum += $actual[$index]
    }
    if ([Math]::Abs($sum - 1.0) -gt 2e-7) { throw "Approximate probabilities do not sum to one: $sum" }
    $maximumError
}

$domain = [float[]]@(-64,-48,-32,-24,-16,-12,-8,-6,-4,-3,-2,-1,-0.5,0)
$domainMaximumError = 0.0
$cases = 0
foreach ($a in $domain) { foreach ($b in $domain) { foreach ($c in $domain) {
    $domainMaximumError = [Math]::Max($domainMaximumError, (Test-OneSoftmax3 ([float[]]@($a,$b,$c)) $null))
    $cases++
} } }
foreach ($mask in @([bool[]]@($true,$true,$false),[bool[]]@($true,$false,$true),[bool[]]@($false,$true,$true),[bool[]]@($true,$false,$false))) {
    $domainMaximumError = [Math]::Max($domainMaximumError, (Test-OneSoftmax3 ([float[]]@(-8,-2,0)) $mask))
    $cases++
}
if ($domainMaximumError -gt 2e-6) { throw "Softmax approximation domain error $domainMaximumError exceeds 2e-6." }

$rejections = 0
foreach ($invalid in @(
    @{ ShiftedScores=[float[]]@(-65,0,0) },
    @{ ShiftedScores=[float[]]@(-1,-2,-3) },
    @{ ShiftedScores=[float[]]@([float]::NaN,0,0) },
    @{ ShiftedScores=[float[]]@(0,0,0); KeyMask=[bool[]]@($false,$false,$false) }
)) {
    try { $null = & $operator @invalid } catch { $rejections++ }
}
if ($rejections -ne 4) { throw "Invalid shifted-softmax3 inputs were admitted: $rejections of 4 rejected." }

$fixtureCases = 0
$fixtureMaximumError = 0.0
if (Test-Path -LiteralPath $QkvFixture) {
    $bytes = [IO.File]::ReadAllBytes($QkvFixture)
    if ($bytes.Length -ne 3 * 2304 * 4) { throw 'QKV fixture has an unexpected length.' }
    $qkv = [float[]]::new(3 * 2304)
    [Buffer]::BlockCopy($bytes, 0, $qkv, 0, $bytes.Length)
    $scale = 1.0 / [Math]::Sqrt(64.0)
    for ($head = 0; $head -lt 12; $head++) {
        for ($queryToken = 0; $queryToken -lt 3; $queryToken++) {
            $scores = [float[]]::new(3)
            for ($keyToken = 0; $keyToken -lt 3; $keyToken++) {
                $dot = 0.0
                for ($dimension = 0; $dimension -lt 64; $dimension++) {
                    $q = $qkv[$queryToken * 2304 + $head * 64 + $dimension]
                    $k = $qkv[$keyToken * 2304 + 768 + $head * 64 + $dimension]
                    $dot += [double]$q * $k
                }
                $scores[$keyToken] = [float]($dot * $scale)
            }
            $minimum = ($scores | Measure-Object -Minimum).Minimum
            $maximum = ($scores | Measure-Object -Maximum).Maximum
            if ($minimum - $maximum -lt -64.0) { throw 'QKV fixture exceeds the admitted shifted-score domain.' }
            $fixtureMaximumError = [Math]::Max($fixtureMaximumError, (Test-OneSoftmax3 $scores $null))
            $fixtureCases++
        }
    }
    if ($fixtureMaximumError -gt 2e-6) { throw "QKV fixture error $fixtureMaximumError exceeds 2e-6." }
}

[pscustomobject]@{
    DomainCases = $cases
    DomainMaximumAbsoluteError = $domainMaximumError
    InvalidCasesRejected = $rejections
    QkvFixtureCases = $fixtureCases
    QkvFixtureMaximumAbsoluteError = $fixtureMaximumError
}
