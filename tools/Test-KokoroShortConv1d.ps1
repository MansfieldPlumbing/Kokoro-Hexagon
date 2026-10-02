#requires -Version 7.4
# Independent impulse fixtures for same-zero-padding cross-correlation.
# Stock generator topology: kokoro/istftnet.py at
# dfb907a02bba8152ca444717ca5d78747ccb4bec, AdaINResBlock1.
# This host oracle gate does not resolve the historical QNN discrepancy.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$modelRoot = Join-Path $PSScriptRoot '../src/models'
$weightV = [float[]]@(0, 3, 4)
$weightG = [float[]]@(5)
$bias = [float[]]@(7)
$folded = & (Join-Path $modelRoot 'ConvertTo-KokoroWeightNormConv1dWeights.ps1') `
    -WeightV $weightV -WeightG $weightG -InputChannels 1 -OutputChannels 1 -KernelSize 3
$cases = 0
foreach ($frames in @(8, 16, 64)) {
    foreach ($dilation in @(1, 3, 5)) {
        foreach ($position in @(0, [int]($frames / 2), ($frames - 1))) {
            $inputTensor = [float[]]::new($frames)
            $inputTensor[$position] = 1
            # Cross-correlation places the right tap before the impulse and
            # the center tap at it. The left tap is zero; bias fills the rest.
            $expected = [float[]]::new($frames)
            [Array]::Fill($expected, [float]7)
            $expected[$position] = 10
            if ($position -ge $dilation) { $expected[$position - $dilation] = 11 }
            $common = @{
                InputTensor = $inputTensor; Frames = $frames; InputChannels = 1
                OutputChannels = 1; KernelSize = 3; Dilation = $dilation; Bias = $bias
            }
            $outputs = @(
                (,(& (Join-Path $modelRoot 'Invoke-KokoroWeightNormConv1d.ps1') @common -WeightV $weightV -WeightG $weightG)),
                (,(& (Join-Path $modelRoot 'Invoke-KokoroAdaInConv1d.ps1') @common -WeightV $weightV -WeightG $weightG)),
                (,(& (Join-Path $modelRoot 'Invoke-KokoroFoldedConv1d.ps1') @common -Weights $folded))
            )
            foreach ($wrapped in $outputs) {
                $actual = $wrapped[0]
                if ($actual.Length -ne $frames) { throw 'Short Conv1D changed the frame count.' }
                for ($i = 0; $i -lt $frames; $i++) {
                    if ($actual[$i] -ne $expected[$i]) { throw 'Short Conv1D impulse, dilation, or zero-padding differs.' }
                }
            }
            $cases++
        }
    }
}
[pscustomobject]@{ Passed = $true; FixtureCount = $cases; OperatorCount = 3; DeviceExecuted = $false }
