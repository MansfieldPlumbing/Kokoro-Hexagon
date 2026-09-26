#requires -Version 7.4
# Stock TextEncoder: token embedding, three weight-normalized Conv1D /
# channel LayerNorm / LeakyReLU blocks, then bidirectional LSTM. Batch one,
# all supplied token positions valid, eval mode. Kokoro kokoro/modules.py
# TextEncoder.forward at dfb907a02bba8152ca444717ca5d78747ccb4bec.
# Output [channels, tokens], bounded FP32 correctness reference.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int[]] $TokenIds,
    [Parameter(Mandatory)][System.Collections.IDictionary] $Parameters,
    [ValidateRange(2, 1024)][int] $Channels = 512,
    [ValidateRange(1, 65536)][int] $VocabularySize = 178,
    [ValidateRange(1, 31)][int] $KernelSize = 5,
    [ValidateRange(1, 3)][int] $Layers = 3
)

$ErrorActionPreference = 'Stop'
$tokens = $TokenIds.Length
if ($tokens -lt 2 -or $tokens -gt 512 -or $Channels % 2 -ne 0 -or
    ($KernelSize % 2) -ne 1 -or
    -not $Parameters.Contains('embedding.weight') -or
    $Parameters['embedding.weight'] -isnot [float[]] -or
    $Parameters['embedding.weight'].Length -ne [long]$VocabularySize * $Channels) {
    throw 'Text encoder embedding shape is invalid.'
}
$embeddings = [float[]]$Parameters['embedding.weight']
$state = [float[]]::new($Channels * $tokens)
for ($token = 0; $token -lt $tokens; $token++) {
    $id = $TokenIds[$token]
    if ($id -lt 0 -or $id -ge $VocabularySize) {
        throw 'Text encoder token ID is outside the vocabulary.'
    }
    for ($channel = 0; $channel -lt $Channels; $channel++) {
        $value = $embeddings[$id * $Channels + $channel]
        if (-not [float]::IsFinite($value)) { throw 'Text encoder embedding is non-finite.' }
        $state[$channel * $tokens + $token] = $value
    }
}
$modelRoot = $PSScriptRoot
for ($layer = 0; $layer -lt $Layers; $layer++) {
    $prefix = "cnn.$layer."
    foreach ($key in @('0.weight_v', '0.weight_g', '0.bias', '1.gamma', '1.beta')) {
        if (-not $Parameters.Contains($prefix + $key) -or
            $Parameters[$prefix + $key] -isnot [float[]]) {
            throw 'Text encoder CNN parameter is absent.'
        }
    }
    [float[]]$state = & (Join-Path $modelRoot 'Invoke-KokoroWeightNormConv1d.ps1') `
        -InputTensor $state -Frames $tokens -InputChannels $Channels `
        -OutputChannels $Channels -KernelSize $KernelSize -Dilation 1 `
        -WeightV $Parameters[$prefix + '0.weight_v'] `
        -WeightG $Parameters[$prefix + '0.weight_g'] `
        -Bias $Parameters[$prefix + '0.bias']
    [float[]]$gamma = $Parameters[$prefix + '1.gamma']
    [float[]]$beta = $Parameters[$prefix + '1.beta']
    if ($gamma.Length -ne $Channels -or $beta.Length -ne $Channels) {
        throw 'Text encoder LayerNorm parameter shape differs.'
    }
    for ($token = 0; $token -lt $tokens; $token++) {
        $mean = 0.0
        for ($channel = 0; $channel -lt $Channels; $channel++) {
            $mean += [double]$state[$channel * $tokens + $token]
        }
        $mean /= $Channels
        $variance = 0.0
        for ($channel = 0; $channel -lt $Channels; $channel++) {
            $difference = [double]$state[$channel * $tokens + $token] - $mean
            $variance += $difference * $difference
        }
        $inverseStd = 1.0 / [Math]::Sqrt($variance / $Channels + 1e-5)
        for ($channel = 0; $channel -lt $Channels; $channel++) {
            $value = (([double]$state[$channel * $tokens + $token] - $mean) *
                $inverseStd) * [double]$gamma[$channel] + [double]$beta[$channel]
            if (-not [double]::IsFinite($value)) { throw 'Text encoder LayerNorm output is non-finite.' }
            $state[$channel * $tokens + $token] = [float]$(if ($value -ge 0) { $value } else { 0.2 * $value })
        }
    }
}
$rowMajor = [float[]]::new($Channels * $tokens)
for ($token = 0; $token -lt $tokens; $token++) {
    for ($channel = 0; $channel -lt $Channels; $channel++) {
        $rowMajor[$token * $Channels + $channel] = $state[$channel * $tokens + $token]
    }
}
$lstmParameters = @{}
foreach ($suffix in @('', '_reverse')) {
    foreach ($name in @('weight_ih_l0', 'weight_hh_l0', 'bias_ih_l0', 'bias_hh_l0')) {
        $key = "lstm.$name$suffix"
        if (-not $Parameters.Contains($key)) { throw "Text encoder LSTM parameter is absent: $key" }
        $lstmParameters["$name$suffix"] = $Parameters[$key]
    }
}
[float[]]$encodedRows = & (Join-Path $modelRoot 'Invoke-KokoroBidirectionalLstm.ps1') `
    -InputTensor $rowMajor -Parameters $lstmParameters -Frames $tokens `
    -InputSize $Channels -HiddenSize ($Channels / 2)
$result = [float[]]::new($Channels * $tokens)
for ($token = 0; $token -lt $tokens; $token++) {
    for ($channel = 0; $channel -lt $Channels; $channel++) {
        $result[$channel * $tokens + $token] = $encodedRows[$token * $Channels + $channel]
    }
}
Write-Output -NoEnumerate $result
