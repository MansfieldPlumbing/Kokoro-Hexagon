#requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$generic = Join-Path $root 'src/models/Invoke-KokoroWeightNormConv1d.ps1'
$specific = Join-Path $root 'src/models/Invoke-KokoroAdaInConv1d.ps1'
$inputTensor = [float[]]@(1, 2, 3)
$weights = [float[]]@(0, 1, 0)
$args = @{
    InputTensor = $inputTensor; Frames = 3; InputChannels = 1
    OutputChannels = 1; KernelSize = 3; Dilation = 1
    WeightV = $weights; WeightG = [float[]]@(1); Bias = [float[]]@(0)
}
$actual = & $generic @args
$prior = & $specific @args
if (($actual -join ',') -cne '1,2,3' -or ($actual -join ',') -cne ($prior -join ',')) {
    throw 'Generic Conv1D differs from analytic or existing AdaIN reference.'
}
Write-Output 'PASS: model-neutral weight-normalized Conv1D arithmetic and prior reference parity'
