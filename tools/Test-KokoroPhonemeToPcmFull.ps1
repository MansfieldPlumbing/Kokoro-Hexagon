#requires -Version 7.4
# Complete stock-layer bounded PowerShell reference gate; intentionally slow.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $CheckpointPath,
    [Parameter(Mandatory)][string] $VoicePath,
    [string] $OutputPcmPath = (Join-Path $PSScriptRoot '../build/reference-one-phoneme.f32le')
)

$ErrorActionPreference = 'Stop'
$buildRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build'))
$outputPath = [IO.Path]::GetFullPath($OutputPcmPath)
if (-not $outputPath.StartsWith($buildRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase) -or
    [IO.File]::Exists($outputPath)) {
    throw 'Reference PCM destination must be a new file under ignored build.'
}
$modelRoot = Join-Path $PSScriptRoot '../src/models'
# This exact digest already passed all three exhaustive finite-value gates.
# Recheck SHA-256 and shape here; readers reject reuse if the pin changes.
$acousticWeights = & (Join-Path $modelRoot 'Read-KokoroAcousticWeights.ps1') `
    -CheckpointPath $CheckpointPath -SkipFiniteScan
$decoderWeights = & (Join-Path $modelRoot 'Read-KokoroDecoderWeights.ps1') `
    -CheckpointPath $CheckpointPath -SkipFiniteScan
$generatorWeights = & (Join-Path $modelRoot 'Read-KokoroGeneratorWeights.ps1') `
    -CheckpointPath $CheckpointPath -SkipFiniteScan
Write-Output 'GATE: pinned acoustic, decoder, and generator weights admitted'
[float[]]$voice = & (Join-Path $modelRoot 'Read-KokoroVoiceRow.ps1') `
    -VoicePath $VoicePath -PhonemeCount 1
Write-Output 'GATE: pinned voice row admitted; executing full stock layer counts'
$result = & (Join-Path $modelRoot 'Invoke-KokoroPhonemeToPcm.ps1') `
    -TokenIds ([int[]]@(0, 43, 0)) -VoiceRow $voice -Speed 100 `
    -AcousticWeights $acousticWeights -DecoderWeights $decoderWeights `
    -GeneratorWeights $generatorWeights -Verbose
if ($result.SampleRate -ne 24000 -or $result.TokenCount -ne 3 -or
    $result.Samples -lt 600 -or $result.Pcm.Length -ne $result.Samples) {
    throw 'Complete phoneme-to-PCM output shape differs.'
}
foreach ($sample in $result.Pcm) {
    if (-not [float]::IsFinite($sample)) { throw 'Complete phoneme-to-PCM output is non-finite.' }
}
[byte[]]$bytes = [byte[]]::new($result.Pcm.Length * 4)
[Buffer]::BlockCopy($result.Pcm, 0, $bytes, 0, $bytes.Length)
[IO.File]::WriteAllBytes($outputPath, $bytes)
Write-Output "PASS: complete stock-layer phoneme-to-PCM shape and finite output; samples=$($result.Samples)"
