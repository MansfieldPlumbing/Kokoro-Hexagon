#requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$stage = Join-Path $PSScriptRoot '../src/models/ConvertTo-KokoroAdaIn.ps1'
$inputTensor = [float[]]@(1, 2, 3, 4, 8, 8, 8, 8)
$normWeight = [float[]]@(2, 3)
$normBias = [float[]]@(-1, 0.25)
$gain = [float[]]@(1.5, 0.5)
$shift = [float[]]@(0.25, -2)
[float[]]$actual = & $stage -InputTensor $inputTensor -Frames 4 -Channels 2 `
    -NormWeight $normWeight -NormBias $normBias -Gain $gain -Shift $shift
if ($actual.Length -ne 8) { throw 'AdaIN output shape differs.' }

# Channel zero has mean 2.5 and population variance 1.25. Channel one is
# constant, so epsilon must keep the normalization finite and exactly zero.
$inverseStd = 1.0 / [Math]::Sqrt(1.25 + 1e-5)
for ($i = 0; $i -lt 4; $i++) {
    $expected = (($i + 1 - 2.5) * $inverseStd * 2 - 1) * 1.5 + 0.25
    if ([Math]::Abs([double]$actual[$i] - $expected) -gt 1e-6) {
        throw "AdaIN affine or population variance differs at frame $i."
    }
    if ([Math]::Abs([double]$actual[$i + 4] - (-1.875)) -gt 1e-6) {
        throw "AdaIN constant-channel result differs at frame $i."
    }
}

$bad = [float[]]::new($inputTensor.Length)
[Array]::Copy($inputTensor, $bad, $bad.Length)
$bad[0] = [float]::NaN
$rejected = $false
try {
    $null = & $stage -InputTensor $bad -Frames 4 -Channels 2 `
        -NormWeight $normWeight -NormBias $normBias -Gain $gain -Shift $shift
} catch { $rejected = $true }
if (-not $rejected) { throw 'AdaIN accepted a non-finite input.' }

Write-Output 'PASS: AdaIN population variance, affine, constant channel, finite-input gate'
