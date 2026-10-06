#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string] $CheckpointPath)

$ErrorActionPreference = 'Stop'
$reader = Join-Path $PSScriptRoot '../src/models/Read-KokoroDecoderWeights.ps1'
$result = & $reader -CheckpointPath $CheckpointPath
if ($result.TensorCount -ne 72 -or $result.PreludeParameters.Count -ne 9 -or
    $result.CoreParameters.Count -ne 63 -or
    $result.PreludeParameters['F0_conv.weight_v'].Length -ne 3 -or
    $result.CoreParameters['decode.3.pool.weight_v'].Length -ne 3270) {
    throw 'Stock decoder weight map is incomplete.'
}
Write-Output 'PASS: pinned stock decoder 72-tensor map'
