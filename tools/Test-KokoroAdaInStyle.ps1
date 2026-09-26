#requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot '../src/models/ConvertTo-KokoroAdaInStyle.ps1'
$normalize = Join-Path $PSScriptRoot '../src/models/ConvertTo-KokoroAdaIn.ps1'

# Two channels, two style features; rows are gamma0, gamma1, beta0, beta1.
$style = [float[]]@(2, 3)
$weights = [float[]]@(1, 0, 0, 2, 0.5, -0.5, -1, 1)
$bias = [float[]]@(0.25, -1, 0.5, -0.25)
$affine = & $project -Style $style -Weights $weights -Bias $bias -Channels 2
if (($affine.Gain -join ',') -cne '3.25,6' -or
    ($affine.Shift -join ',') -cne '0,0.75') {
    throw 'AdaIN style projection or gamma/beta split differs.'
}

$inputTensor = [float[]]@(1, 2, 3, 8, 8, 8)
$normWeight = [float[]]@(1, 1)
$normBias = [float[]]@(0, 0)
[float[]]$output = & $normalize -InputTensor $inputTensor -Frames 3 -Channels 2 `
    -Gain $affine.Gain -Shift $affine.Shift
[float[]]$explicitIdentity = & $normalize -InputTensor $inputTensor -Frames 3 -Channels 2 `
    -NormWeight $normWeight -NormBias $normBias -Gain $affine.Gain -Shift $affine.Shift
if (($output -join ',') -cne ($explicitIdentity -join ',')) {
    throw 'Omitted stock norm affine differs from explicit identity parameters.'
}
for ($i = 0; $i -lt 3; $i++) {
    if ([Math]::Abs([double]$output[3 + $i] - 0.75) -gt 1e-6) {
        throw 'Projected style did not feed the constant-channel AdaIN stage.'
    }
}

$bad = [float[]]@(2, [float]::NaN)
$rejected = $false
try { $null = & $project -Style $bad -Weights $weights -Bias $bias -Channels 2 } catch { $rejected = $true }
if (-not $rejected) { throw 'Non-finite style vector was accepted.' }

Write-Output 'PASS: style projection, gamma/beta split, AdaIN composition, finite-input gate'
