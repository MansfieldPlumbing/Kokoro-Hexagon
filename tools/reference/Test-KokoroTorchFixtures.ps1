#requires -Version 7.4
# Bounded original-source differential. Python/Torch remain reference-only.
[CmdletBinding()]
param([Parameter(Mandatory)][string] $EvidenceDirectory,
    [Parameter(Mandatory)][string] $PythonPath,
    [switch] $IncludeAlbertEncoder,
    [switch] $IncludeDecoderCore,
    [switch] $IncludeHistoricalShortFrames)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$evidence = [IO.Path]::GetFullPath($EvidenceDirectory)
if (-not $evidence.StartsWith((Join-Path $root 'build') + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) { throw 'Reference evidence must remain under repository build.' }
$oracle = Join-Path $evidence 'torch-oracle'
$manifest = Get-Content -LiteralPath (Join-Path $root 'lib/manifest.json') -Raw | ConvertFrom-Json
$inputRoot = Join-Path $root ('build/inputs/kokoro/' + $manifest.model.revision)
$checkpoint = Join-Path $inputRoot 'kokoro-v1_0.pth'
$voicePath = Join-Path $inputRoot 'voices/af_heart.pt'
$modelRoot = Join-Path $root 'src/models'
$acoustic = & (Join-Path $modelRoot 'Read-KokoroAcousticWeights.ps1') -CheckpointPath $checkpoint -SkipFiniteScan
$generator = & (Join-Path $modelRoot 'Read-KokoroGeneratorWeights.ps1') -CheckpointPath $checkpoint -SkipFiniteScan
$voice = & (Join-Path $modelRoot 'Read-KokoroVoiceRow.ps1') -VoicePath $voicePath -PhonemeCount 7
function Read-Floats([string] $Path, [int] $Count) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ne 4L * $Count) { throw 'Reference input byte count differs.' }
    $values = [float[]]::new($Count)
    [Buffer]::BlockCopy($bytes, 0, $values, 0, $bytes.Length)
    return ,$values
}
function Write-Floats([string] $Path, [float[]] $Values) {
    $bytes = [byte[]]::new(4 * $Values.Length)
    [Buffer]::BlockCopy($Values, 0, $bytes, 0, $bytes.Length)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
}
$hidden = Read-Floats (Join-Path $evidence 'fixtures/albert-qkv/input.f32') 2304
$attention = & (Join-Path $modelRoot 'Invoke-KokoroAlbertAttention.ps1') `
    -HiddenStates $hidden -Parameters $acoustic.AlbertAttention -Tokens 3 -HiddenSize 768 -Heads 12
Write-Floats (Join-Path $oracle 'albert-attention.reference.f32') $attention
$parameters = @{}
foreach ($name in $generator.Parameters.Keys) {
    if ($name.StartsWith('resblocks.3.', [StringComparison]::Ordinal)) {
        $parameters[$name.Substring(12)] = $generator.Parameters[$name]
    }
}
if ($parameters.Count -ne 36) { throw 'Stock residual parameter count differs.' }
$style = [float[]]::new(128)
[Array]::Copy($voice, 0, $style, 0, 128)
$fullInput = Read-Floats (Join-Path $evidence 'fixtures/adain-resblock/stock-block.input.bin') 8192
foreach ($frames in @(8, 16, 64)) {
    $inputTensor = [float[]]::new(128 * $frames)
    for ($channel = 0; $channel -lt 128; $channel++) {
        [Array]::Copy($fullInput, $channel * 64, $inputTensor, $channel * $frames, $frames)
    }
    Write-Floats (Join-Path $oracle "adain-$frames.input.f32") $inputTensor
    if ($frames -eq 64) {
        $reference = Read-Floats (Join-Path $evidence 'fixtures/adain-resblock/stock-block.reference.bin') 8192
    } else {
        $reference = & (Join-Path $modelRoot 'Invoke-KokoroAdaInResBlock1.ps1') `
            -InputTensor $inputTensor -Style $style -Parameters $parameters `
            -Frames $frames -Channels 128 -KernelSize 3 -Dilations @(1, 3, 5)
    }
    Write-Floats (Join-Path $oracle "adain-$frames.reference.f32") $reference
}
& (Join-Path $PSScriptRoot 'New-KokoroStftFixture.ps1') -OutputDirectory $oracle
if ($IncludeDecoderCore) {
    & (Join-Path $PSScriptRoot 'New-KokoroDecoderFixture.ps1') -OutputDirectory $oracle
}
if ($IncludeHistoricalShortFrames) {
    foreach ($frames in @(8, 16)) {
        & (Join-Path $root 'tools/New-KokoroAdaInR0Fixture.ps1') -CheckpointPath $checkpoint `
            -OutDir (Join-Path $oracle "r0-$frames") -Frames $frames
    }
}
if ($IncludeAlbertEncoder) {
    $encoder = & (Join-Path $modelRoot 'Invoke-KokoroAlbertEncoder.ps1') `
        -TokenIds ([int[]]@(0, 43, 0)) -Embeddings $acoustic.AlbertEmbeddings `
        -Projection $acoustic.AlbertProjection -Attention $acoustic.AlbertAttention `
        -FeedForward $acoustic.AlbertFeedForward -LayerRepeats 12
    Write-Floats (Join-Path $oracle 'albert-encoder.reference.f32') $encoder
}
$oracleScript = Join-Path $PSScriptRoot 'Test-KokoroTorchFixtures.py'
& $PythonPath -c 'import ast,sys; ast.parse(open(sys.argv[1],encoding="utf-8").read())' $oracleScript
if ($LASTEXITCODE) { throw 'Reference Python source does not parse.' }
& $PythonPath $oracleScript --site (Join-Path $oracle 'site') --directory $oracle
if ($LASTEXITCODE) { throw 'Bounded original-source differential failed; inspect torch-differential.json.' }
