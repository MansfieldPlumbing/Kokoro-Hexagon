#requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$stage = Join-Path $PSScriptRoot '../src/models/Invoke-KokoroAdaInResBlock1.ps1'
$parameters = @{}
for ($pass = 0; $pass -lt 3; $pass++) {
    foreach ($side in 1, 2) {
        $parameters["adain$side.$pass.fc.weight"] = [float[]]@(0, 0)
        $parameters["adain$side.$pass.fc.bias"] = [float[]]@(0, 0)
        $parameters["alpha$side.$pass"] = [float[]]@(1)
        $parameters["convs$side.$pass.weight_v"] = [float[]]@(0, 1, 0)
        $parameters["convs$side.$pass.weight_g"] = [float[]]@(1)
        $parameters["convs$side.$pass.bias"] = [float[]]@(0)
    }
}
$inputTensor = [float[]]@(1, 2, 3, 4)
[float[]]$actual = & $stage -InputTensor $inputTensor -Style ([float[]]@(0)) `
    -Frames 4 -Channels 1 -KernelSize 3 -Dilations ([int[]]@(1, 3, 5)) `
    -Parameters $parameters

# For the chosen center-tap convolutions, each convolution is the identity;
# independently evaluate the two normalized Snake stages and residual sum.
function Invoke-ExpectedNormSnake([float[]] $Values) {
    $mean = 0.0
    foreach ($value in $Values) { $mean += [double]$value }
    $mean /= $Values.Length
    $variance = 0.0
    foreach ($value in $Values) {
        $difference = [double]$value - $mean
        $variance += $difference * $difference
    }
    $variance /= $Values.Length
    $result = [float[]]::new($Values.Length)
    for ($i = 0; $i -lt $Values.Length; $i++) {
        $normalized = [float](([double]$Values[$i] - $mean) / [Math]::Sqrt($variance + 1e-5))
        $result[$i] = [float]([double]$normalized + [Math]::Pow([Math]::Sin([double]$normalized), 2))
    }
    return ,$result
}
$expected = $inputTensor
for ($pass = 0; $pass -lt 3; $pass++) {
    [float[]]$first = Invoke-ExpectedNormSnake $expected
    [float[]]$second = Invoke-ExpectedNormSnake $first
    $next = [float[]]::new($expected.Length)
    for ($i = 0; $i -lt $expected.Length; $i++) {
        $next[$i] = [float]([double]$expected[$i] + [double]$second[$i])
    }
    $expected = $next
}
if ($actual.Length -ne $expected.Length) { throw 'AdaIN residual block output shape differs.' }
for ($i = 0; $i -lt $expected.Length; $i++) {
    if ([Math]::Abs([double]$actual[$i] - [double]$expected[$i]) -gt 1e-5) {
        throw "AdaIN residual composition differs at $i."
    }
}

$parameters.Remove('adain1.0.fc.weight')
$rejected = $false
try {
    $null = & $stage -InputTensor $inputTensor -Style ([float[]]@(0)) `
        -Frames 4 -Channels 1 -KernelSize 3 -Dilations ([int[]]@(1, 3, 5)) `
        -Parameters $parameters
} catch { $rejected = $true }
if (-not $rejected) { throw 'AdaIN residual block accepted incomplete parameters.' }

Write-Output 'PASS: three-pass AdaIN, Snake, Conv1D, residual composition'
