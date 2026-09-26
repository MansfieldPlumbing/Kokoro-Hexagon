#requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$stage = Join-Path $PSScriptRoot '../src/models/Invoke-KokoroDepthwiseTransposeConv1d.ps1'
$actual = & $stage -InputTensor ([float[]]@(1, 2)) `
    -WeightV ([float[]]@(0, 1, 0)) -WeightG ([float[]]@(1)) `
    -Bias ([float[]]@(0)) -Frames 2 -Channels 1
if (($actual -join ',') -cne '1,0,2,0') {
    throw 'Analytic depthwise transposed Conv1D stride or padding differs.'
}
Write-Output 'PASS: depthwise transposed Conv1D stride, padding, and output length'
