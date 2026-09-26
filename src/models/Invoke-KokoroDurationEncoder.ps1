#requires -Version 7.4
# Stock DurationEncoder style-conditioned recurrent stack, batch one, eval.
# Kokoro kokoro/modules.py DurationEncoder.forward at
# dfb907a02bba8152ca444717ca5d78747ccb4bec.
# Row-major token output [time, features + style]; bounded FP32 reference.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $TokenFeatures,
    [Parameter(Mandatory)][float[]] $Style,
    [Parameter(Mandatory)][System.Collections.IDictionary] $Parameters,
    [Parameter(Mandatory)][ValidateRange(1, 512)][int] $Tokens,
    [Parameter(Mandatory)][ValidateRange(2, 1024)][int] $FeatureSize,
    [Parameter(Mandatory)][ValidateRange(1, 3)][int] $Layers
)

$ErrorActionPreference = 'Stop'
$styleSize = $Style.Length
if ($FeatureSize % 2 -ne 0 -or $styleSize -lt 1 -or $styleSize -gt 1024 -or
    $TokenFeatures.Length -ne [long]$Tokens * $FeatureSize) {
    throw 'Duration encoder input shape is invalid.'
}
$inputSize = $FeatureSize + $styleSize
$state = [float[]]::new($Tokens * $inputSize)
for ($token = 0; $token -lt $Tokens; $token++) {
    [Array]::Copy($TokenFeatures, $token * $FeatureSize,
        $state, $token * $inputSize, $FeatureSize)
    [Array]::Copy($Style, 0, $state, $token * $inputSize + $FeatureSize, $styleSize)
}
$modelRoot = $PSScriptRoot
for ($layer = 0; $layer -lt $Layers; $layer++) {
    $lstmIndex = 2 * $layer
    $normIndex = $lstmIndex + 1
    $lstmParameters = @{}
    foreach ($suffix in @('', '_reverse')) {
        foreach ($name in @('weight_ih_l0', 'weight_hh_l0', 'bias_ih_l0', 'bias_hh_l0')) {
            $key = "lstms.$lstmIndex.$name$suffix"
            if (-not $Parameters.Contains($key)) { throw "Duration encoder parameter is absent: $key" }
            $lstmParameters["$name$suffix"] = $Parameters[$key]
        }
    }
    [float[]]$state = & (Join-Path $modelRoot 'Invoke-KokoroBidirectionalLstm.ps1') `
        -InputTensor $state -Parameters $lstmParameters -Frames $Tokens `
        -InputSize $inputSize -HiddenSize ($FeatureSize / 2)
    $weightKey = "lstms.$normIndex.fc.weight"
    $biasKey = "lstms.$normIndex.fc.bias"
    if (-not $Parameters.Contains($weightKey) -or -not $Parameters.Contains($biasKey)) {
        throw 'Duration adaptive layer norm parameters are absent.'
    }
    [float[]]$state = & (Join-Path $modelRoot 'Invoke-KokoroDurationAdaLayerNorm.ps1') `
        -InputTensor $state -Style $Style -FcWeights $Parameters[$weightKey] `
        -FcBias $Parameters[$biasKey] -Frames $Tokens -Channels $FeatureSize
}
Write-Output -NoEnumerate $state
