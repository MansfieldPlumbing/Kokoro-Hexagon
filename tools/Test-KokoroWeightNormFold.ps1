#requires -Version 7.4
# Source-defined folding gate using one pinned generator convolution.
[CmdletBinding()]
param([string]$CheckpointPath = 'C:\models\Kokoro-82M\kokoro-v1_0.pth')

$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$weightsRecord = & (Join-Path $repo 'src/models/Read-KokoroGeneratorWeights.ps1') `
    -CheckpointPath $CheckpointPath -SkipFiniteScan
$prefix = 'resblocks.3.convs1.0'
[float[]]$v = $weightsRecord.Parameters["$prefix.weight_v"]
[float[]]$g = $weightsRecord.Parameters["$prefix.weight_g"]
[float[]]$bias = $weightsRecord.Parameters["$prefix.bias"]
if ($v.Length -ne 49152 -or $g.Length -ne 128 -or $bias.Length -ne 128) {
    throw 'Pinned generator convolution has an unexpected shape.'
}
[float[]]$inputTensor = [float[]]::new(128 * 8)
for ($i = 0; $i -lt $inputTensor.Length; $i++) { $inputTensor[$i] = [float](($i % 19 - 9) / 13.0) }
$args = @{ InputTensor = $inputTensor; Frames = 8; InputChannels = 128; OutputChannels = 128; KernelSize = 3; Dilation = 1; WeightV = $v; WeightG = $g; Bias = $bias }
[float[]]$reference = & (Join-Path $repo 'src/models/Invoke-KokoroWeightNormConv1d.ps1') @args
[float[]]$folded = & (Join-Path $repo 'src/models/ConvertTo-KokoroWeightNormConv1dWeights.ps1') `
    -InputChannels 128 -OutputChannels 128 -KernelSize 3 -WeightV $v -WeightG $g
[float[]]$actual = & (Join-Path $repo 'src/models/Invoke-KokoroFoldedConv1d.ps1') `
    -InputTensor $inputTensor -Frames 8 -InputChannels 128 -OutputChannels 128 -KernelSize 3 -Dilation 1 -Weights $folded -Bias $bias
[double]$maxError = 0
for ($i = 0; $i -lt $actual.Length; $i++) { $maxError = [Math]::Max($maxError, [Math]::Abs([double]$actual[$i] - [double]$reference[$i])) }
if ($maxError -gt 1e-6) { throw 'Folded weight_norm convolution differs from the source-defined reference.' }
[pscustomobject]@{ Passed = $true; CheckpointSHA256 = $weightsRecord.CheckpointSha256; Operator = "decoder.module.generator.$prefix"; MaxAbsError = $maxError }
