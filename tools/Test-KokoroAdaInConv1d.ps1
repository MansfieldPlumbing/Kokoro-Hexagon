#requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$stage = Join-Path $PSScriptRoot '../src/models/Invoke-KokoroAdaInConv1d.ps1'
$inputTensor = [float[]]@(1, 2, 3, 4, 5, 10, 20, 30, 40, 50)
$weightV = [float[]]@(1, 2, 3, 0, 0, 0, 0, 0, 0, 0, 1, 0)
$weightG = [float[]]@([Math]::Sqrt(14), 1)
$bias = [float[]]@(0, 0.5)
[float[]]$actual = & $stage -InputTensor $inputTensor -Frames 5 -InputChannels 2 `
    -OutputChannels 2 -KernelSize 3 -Dilation 2 -WeightV $weightV -WeightG $weightG -Bias $bias
$expected = [double[]]@(11, 16, 22, 10, 13, 10.5, 20.5, 30.5, 40.5, 50.5)
if ($actual.Length -ne $expected.Length) { throw 'AdaIN Conv1D output shape differs.' }
for ($i = 0; $i -lt $expected.Length; $i++) {
    if ([Math]::Abs([double]$actual[$i] - $expected[$i]) -gt 1e-6) {
        throw "AdaIN Conv1D weight norm, dilation, or padding differs at $i."
    }
}
$bad = [float[]]::new($weightV.Length)
[Array]::Copy($weightV, $bad, $bad.Length)
$bad[0] = [float]::NaN
$rejected = $false
try {
    $null = & $stage -InputTensor $inputTensor -Frames 5 -InputChannels 2 `
        -OutputChannels 2 -KernelSize 3 -Dilation 2 -WeightV $bad -WeightG $weightG -Bias $bias
} catch { $rejected = $true }
if (-not $rejected) { throw 'AdaIN Conv1D accepted a non-finite weight.' }
Write-Output 'PASS: AdaIN Conv1D weight norm, dilation, padding, finite-input gate'
