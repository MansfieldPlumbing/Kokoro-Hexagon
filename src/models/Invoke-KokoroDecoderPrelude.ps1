#requires -Version 7.4
# Stock Decoder.forward input preparation before its encode AdaIN block.
# Kokoro kokoro/istftnet.py at dfb907a02bba8152ca444717ca5d78747ccb4bec.
# Channel-first batch-one bounded FP32 correctness reference; no PCM.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $AlignedTextFeatures,
    [Parameter(Mandatory)][float[]] $F0,
    [Parameter(Mandatory)][float[]] $N,
    [Parameter(Mandatory)][System.Collections.IDictionary] $Parameters,
    [Parameter(Mandatory)][ValidateRange(1, 512)][int] $Frames
)

$ErrorActionPreference = 'Stop'
if ($AlignedTextFeatures.Length -ne [long]512 * $Frames -or
    $F0.Length -ne [long]2 * $Frames -or $N.Length -ne [long]2 * $Frames) {
    throw 'Decoder prelude input shape is invalid.'
}
foreach ($name in @('F0_conv.weight_v', 'F0_conv.weight_g', 'F0_conv.bias',
        'N_conv.weight_v', 'N_conv.weight_g', 'N_conv.bias',
        'asr_res.0.weight_v', 'asr_res.0.weight_g', 'asr_res.0.bias')) {
    if (-not $Parameters.Contains($name) -or $Parameters[$name] -isnot [float[]]) {
        throw "Decoder prelude parameter is absent: $name"
    }
}
$modelRoot = $PSScriptRoot
[float[]]$downF0 = & (Join-Path $modelRoot 'Invoke-KokoroWeightNormStride2Conv1d.ps1') `
    -InputTensor $F0 -WeightV $Parameters['F0_conv.weight_v'] `
    -WeightG $Parameters['F0_conv.weight_g'] -Bias $Parameters['F0_conv.bias'] `
    -Frames (2 * $Frames)
[float[]]$downN = & (Join-Path $modelRoot 'Invoke-KokoroWeightNormStride2Conv1d.ps1') `
    -InputTensor $N -WeightV $Parameters['N_conv.weight_v'] `
    -WeightG $Parameters['N_conv.weight_g'] -Bias $Parameters['N_conv.bias'] `
    -Frames (2 * $Frames)
[float[]]$asrResidual = & (Join-Path $modelRoot 'Invoke-KokoroWeightNormConv1d.ps1') `
    -InputTensor $AlignedTextFeatures -Frames $Frames -InputChannels 512 `
    -OutputChannels 64 -KernelSize 1 -Dilation 1 `
    -WeightV $Parameters['asr_res.0.weight_v'] `
    -WeightG $Parameters['asr_res.0.weight_g'] `
    -Bias $Parameters['asr_res.0.bias']
$encodeInput = [float[]]::new(514 * $Frames)
[Array]::Copy($AlignedTextFeatures, $encodeInput, $AlignedTextFeatures.Length)
[Array]::Copy($downF0, 0, $encodeInput, 512 * $Frames, $Frames)
[Array]::Copy($downN, 0, $encodeInput, 513 * $Frames, $Frames)
[pscustomobject]@{
    Frames = $Frames
    EncodeInput = $encodeInput
    AsrResidual = $asrResidual
    DownsampledF0 = $downF0
    DownsampledN = $downN
}
