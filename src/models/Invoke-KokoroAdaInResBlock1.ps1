#requires -Version 7.4
# Complete stock AdaINResBlock1 composition for one batch item.
# kokoro/istftnet.py:34-78 at dfb907a02bba8152ca444717ca5d78747ccb4bec.
# Parameters use suffixes under one generator.resblocks.N checkpoint prefix.
# This bounded scalar reference is not the emitted Hexagon implementation.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $InputTensor,
    [Parameter(Mandatory)][float[]] $Style,
    [Parameter(Mandatory)][ValidateRange(2, 32768)][int] $Frames,
    [Parameter(Mandatory)][ValidateRange(1, 1024)][int] $Channels,
    [Parameter(Mandatory)][ValidateSet(3, 7, 11)][int] $KernelSize,
    [Parameter(Mandatory)][int[]] $Dilations,
    [Parameter(Mandatory)][System.Collections.IDictionary] $Parameters
)

$ErrorActionPreference = 'Stop'
if ($Dilations.Length -ne 3 -or $InputTensor.Length -ne [long]$Frames * $Channels -or
    $Style.Length -lt 1 -or $Style.Length -gt 1024) {
    throw 'AdaIN residual block dimensions are invalid.'
}
foreach ($dilation in $Dilations) {
    if ($dilation -lt 1 -or $dilation -gt 32) { throw 'AdaIN residual block dilation is invalid.' }
}
for ($pass = 0; $pass -lt 3; $pass++) {
    foreach ($side in 1, 2) {
        $prefix = "adain$side.$pass."
        foreach ($name in @("${prefix}fc.weight", "${prefix}fc.bias", "alpha$side.$pass",
            "convs$side.$pass.weight_v", "convs$side.$pass.weight_g", "convs$side.$pass.bias")) {
            if (-not $Parameters.Contains($name) -or $Parameters[$name] -isnot [float[]]) {
                throw "AdaIN residual block parameter is absent or has the wrong type: $name"
            }
        }
    }
}

$modelRoot = $PSScriptRoot
$styleScript = Join-Path $modelRoot 'ConvertTo-KokoroAdaInStyle.ps1'
$normScript = Join-Path $modelRoot 'ConvertTo-KokoroAdaIn.ps1'
$snakeScript = Join-Path $modelRoot 'Invoke-KokoroAdaInSnake.ps1'
$convScript = Join-Path $modelRoot 'Invoke-KokoroAdaInConv1d.ps1'
$state = $InputTensor
for ($pass = 0; $pass -lt 3; $pass++) {
    $next = $state
    foreach ($side in 1, 2) {
        $prefix = "adain$side.$pass."
        $affine = & $styleScript -Style $Style -Weights $Parameters["${prefix}fc.weight"] `
            -Bias $Parameters["${prefix}fc.bias"] -Channels $Channels
        [float[]]$next = & $normScript -InputTensor $next -Frames $Frames -Channels $Channels `
            -Gain $affine.Gain -Shift $affine.Shift
        [float[]]$next = & $snakeScript -InputTensor $next -Frames $Frames -Channels $Channels `
            -Alpha $Parameters["alpha$side.$pass"]
        $dilation = if ($side -eq 1) { $Dilations[$pass] } else { 1 }
        [float[]]$next = & $convScript -InputTensor $next -Frames $Frames `
            -InputChannels $Channels -OutputChannels $Channels -KernelSize $KernelSize `
            -Dilation $dilation -WeightV $Parameters["convs$side.$pass.weight_v"] `
            -WeightG $Parameters["convs$side.$pass.weight_g"] `
            -Bias $Parameters["convs$side.$pass.bias"]
    }
    $sum = [float[]]::new($state.Length)
    for ($i = 0; $i -lt $state.Length; $i++) {
        $value = [double]$state[$i] + [double]$next[$i]
        if (-not [double]::IsFinite($value) -or [Math]::Abs($value) -gt [float]::MaxValue) {
            throw 'AdaIN residual block output is non-finite.'
        }
        $sum[$i] = [float]$value
    }
    $state = $sum
}
Write-Output -NoEnumerate $state
