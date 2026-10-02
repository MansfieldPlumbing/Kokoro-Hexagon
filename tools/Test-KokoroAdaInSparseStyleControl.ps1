#requires -Version 7.4
# Verifies that sparse descriptor updates equal a fresh stock style projection.
# This is a build-time/oracle gate, not an inference implementation.
[CmdletBinding()]
param(
    [string]$CheckpointPath = 'C:\models\Kokoro-82M\kokoro-v1_0.pth',
    [string]$VoicePath = 'C:\models\Kokoro-82M\voices\af_heart.pt',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../build/adain-sparse-style-control')
)

$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$build = Join-Path $repo 'build'
$outDir = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $outDir.StartsWith($build + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Directory]::Exists($outDir)) { throw 'Test output must be a new directory inside ignored build.' }

$weightsRecord = & (Join-Path $repo 'src/models/Read-KokoroGeneratorWeights.ps1') `
    -CheckpointPath $CheckpointPath -SkipFiniteScan
$key = 'resblocks.3.adain1.0.fc'
[float[]]$weights = $weightsRecord.Parameters["$key.weight"]
[float[]]$bias = $weightsRecord.Parameters["$key.bias"]
if ($weights.Length -ne 32768 -or $bias.Length -ne 256) {
    throw 'Pinned AdaIN projection has an unexpected shape.'
}

[float[]]$voice = & (Join-Path $repo 'src/models/Read-KokoroVoiceRow.ps1') -VoicePath $VoicePath -PhonemeCount 7
[float[]]$baseStyle = [float[]]::new(128)
[Array]::Copy($voice, 0, $baseStyle, 0, 128)
$base = & (Join-Path $repo 'src/models/ConvertTo-KokoroAdaInStyle.ps1') `
    -Style $baseStyle -Weights $weights -Bias $bias -Channels 128

$descriptor = & (Join-Path $repo 'src/models/New-KokoroStyleControlDescriptor.ps1') `
    -Schema 1 -Revision 17 -CommitWatermark 42 -Voice af_heart -StyleDimension 128 -Mutations @(
        [pscustomobject]@{ Index = 3; Delta = 0.015 },
        [pscustomobject]@{ Index = 41; Delta = -0.01 },
        [pscustomobject]@{ Index = 97; Delta = 0.02 }
    )
[float[]]$mutatedStyle = [float[]]::new(128)
[Array]::Copy($baseStyle, $mutatedStyle, 128)
foreach ($mutation in $descriptor.Mutations) {
    $mutatedStyle[$mutation.Index] = [float]([double]$mutatedStyle[$mutation.Index] + [double]$mutation.Delta)
}
$fresh = & (Join-Path $repo 'src/models/ConvertTo-KokoroAdaInStyle.ps1') `
    -Style $mutatedStyle -Weights $weights -Bias $bias -Channels 128

# The compiled form keeps the stock base projection and adds only the columns
# selected by the descriptor. It is algebraically the same Linear(style).
$maxError = 0.0
for ($row = 0; $row -lt 256; $row++) {
    [double]$compiled = if ($row -lt 128) { [double]$base.Gain[$row] } else { [double]$base.Shift[$row - 128] }
    foreach ($mutation in $descriptor.Mutations) {
        $compiled += [double]$weights[$row * 128 + $mutation.Index] * [double]$mutation.Delta
    }
    [double]$expected = if ($row -lt 128) { [double]$fresh.Gain[$row] } else { [double]$fresh.Shift[$row - 128] }
    $maxError = [Math]::Max($maxError, [Math]::Abs($compiled - $expected))
}
if ($maxError -gt 1e-5) { throw 'Sparse style-control update differs from fresh stock projection.' }

[void][IO.Directory]::CreateDirectory($outDir)
$receipt = [ordered]@{
    Schema = 1
    Scope = 'one_stock_adain_site_sparse_style_control_equivalence'
    CheckpointSHA256 = $weightsRecord.CheckpointSha256
    Voice = 'af_heart'
    VoicePhonemeCount = 7
    Operator = "decoder.module.generator.$key"
    StyleDimension = 128
    DescriptorRevision = $descriptor.Revision
    CommitWatermark = $descriptor.CommitWatermark
    SparseMutationCount = $descriptor.Mutations.Count
    MaxAbsError = $maxError
    Conclusion = 'base_projection_plus_sparse_columns_matches_fresh_stock_style_projection'
}
$path = Join-Path $outDir 'receipt.json'
[IO.File]::WriteAllText($path, (($receipt | ConvertTo-Json -Depth 5) + "`n"), [Text.UTF8Encoding]::new($false))
[pscustomobject]@{ Passed = $true; Receipt = $path; MaxAbsError = $maxError; Mutations = $descriptor.Mutations.Count }
