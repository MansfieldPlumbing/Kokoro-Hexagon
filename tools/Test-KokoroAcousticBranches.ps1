#requires -Version 7.4
# Connected stock-checkpoint shape/finite gate. The component tests expose
# their digest-verified stock dictionaries in this test's scope.
[CmdletBinding()]
param([Parameter(Mandatory)][string] $CheckpointPath)

$ErrorActionPreference = 'Stop'
$path = (Resolve-Path -LiteralPath $CheckpointPath).Path
. (Join-Path $PSScriptRoot 'Test-KokoroAlbertEncoder.ps1') -CheckpointPath $path | Out-Null
$albertEmbeddings = $stockEmbeddings
$albertProjection = $stockProjection
$albertAttention = $stockAttention
$albertFeedForward = $stockFeedForward
. (Join-Path $PSScriptRoot 'Test-KokoroDurationBranch.ps1') -CheckpointPath $path | Out-Null
$durationEncoder = $stockEncoder
$durationLstm = $stockLstm
$durationWeight = $stockWeight
$durationBias = $stockBias
. (Join-Path $PSScriptRoot 'Test-KokoroTextEncoder.ps1') -CheckpointPath $path | Out-Null
$textEncoder = $stock
. (Join-Path $PSScriptRoot 'Test-KokoroF0NBranch.ps1') -CheckpointPath $path | Out-Null
$f0n = $parameters
$bertWeight = & $read 'bert_encoder.module.weight' '512,768'
$bertBias = & $read 'bert_encoder.module.bias' '512'
$voice = [float[]]::new(256)
for ($i = 0; $i -lt 128; $i++) { $voice[$i] = [float]0.01 }
for ($i = 128; $i -lt 256; $i++) { $voice[$i] = [float]0.02 }
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$result = & (Join-Path $root 'src/models/Invoke-KokoroAcousticBranches.ps1') `
    -TokenIds ([int[]]@(0, 43, 0)) -VoiceRow $voice `
    -AlbertEmbeddings $albertEmbeddings -AlbertProjection $albertProjection `
    -AlbertAttention $albertAttention -AlbertFeedForward $albertFeedForward `
    -BertEncoderWeights $bertWeight -BertEncoderBias $bertBias `
    -DurationEncoderParameters $durationEncoder `
    -DurationLstmParameters $durationLstm `
    -DurationWeights $durationWeight -DurationBias $durationBias `
    -TextEncoderParameters $textEncoder -F0NParameters $f0n `
    -Speed 100 -AlbertLayerRepeats 1 -DurationEncoderLayers 1 `
    -TextEncoderLayers 1
if ($result.TokenCount -ne 3 -or $result.FrameCount -ne 3 -or
    ($result.FrameToToken -join ',') -cne '0,1,2' -or
    $result.AlignedTextFeatures.Length -ne 3 * 512 -or
    $result.F0.Length -ne 6 -or $result.N.Length -ne 6 -or
    $result.DurationStyle[0] -ne [float]0.02 -or
    $result.DecoderStyle[0] -ne [float]0.01) {
    throw 'Connected acoustic branch control or output shape differs.'
}
foreach ($values in @($result.AlignedTextFeatures, $result.F0, $result.N)) {
    foreach ($value in $values) {
        if (-not [float]::IsFinite($value)) {
            throw 'Connected acoustic branch output is non-finite.'
        }
    }
}
Write-Output 'PASS: connected acoustic branches stock-weight shape and finite-output gate'
