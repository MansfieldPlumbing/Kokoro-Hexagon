#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string] $CheckpointPath)

$ErrorActionPreference = 'Stop'
$reader = Join-Path $PSScriptRoot '../src/models/Read-KokoroAcousticWeights.ps1'
$result = & $reader -CheckpointPath $CheckpointPath
if ($result.TensorCount -ne 171 -or
    $result.AlbertEmbeddings.Count -ne 5 -or
    $result.AlbertProjection.Count -ne 2 -or
    $result.AlbertAttention.Count -ne 10 -or
    $result.AlbertFeedForward.Count -ne 6 -or
    $result.DurationEncoderParameters.Count -ne 30 -or
    $result.DurationLstmParameters.Count -ne 8 -or
    $result.TextEncoderParameters.Count -ne 24 -or
    $result.F0NParameters.Count -ne 82 -or
    $result.BertEncoderWeights.Length -ne 512 * 768 -or
    $result.DurationWeights.Length -ne 50 * 512) {
    throw 'Stock acoustic weight map is incomplete.'
}
Write-Output 'PASS: pinned stock acoustic 171-tensor map'
