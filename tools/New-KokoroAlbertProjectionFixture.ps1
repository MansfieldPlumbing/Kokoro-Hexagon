#requires -Version 7.4
# Stock-weight fixture for the first connected ALBERT affine boundary.
# The PowerShell result is a numerical oracle; product inference executes on DSP.
[CmdletBinding()]
param(
    [string] $CheckpointPath = 'C:\models\Kokoro-82M\kokoro-v1_0.pth',
    [string] $OutputDirectory = (Join-Path $PSScriptRoot '../build/albert-embedding-projection-fixture'),
    [switch] $VectorOutputTiles
)

$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$build = [IO.Path]::GetFullPath((Join-Path $repo 'build'))
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $output.StartsWith($build + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Fixture output must remain under the repository build directory.'
}
if ([IO.Directory]::Exists($output) -and
    @(Get-ChildItem -LiteralPath $output -Force).Count -ne 0) {
    throw 'Fixture output directory must be new or empty.'
}
[void][IO.Directory]::CreateDirectory($output)

$modelRoot = Join-Path $repo 'src/models'
$weights = & (Join-Path $modelRoot 'Read-KokoroAcousticWeights.ps1') `
    -CheckpointPath $CheckpointPath -SkipFiniteScan
[int[]] $tokens = @(0, 43, 0)
[float[]] $embedding = & (Join-Path $modelRoot 'Invoke-KokoroAlbertEmbeddings.ps1') `
    -TokenIds $tokens `
    -WordWeights $weights.AlbertEmbeddings.'word.weight' `
    -PositionWeights $weights.AlbertEmbeddings.'position.weight' `
    -TokenTypeWeights $weights.AlbertEmbeddings.'token_type.weight' `
    -LayerNormWeight $weights.AlbertEmbeddings.'LayerNorm.weight' `
    -LayerNormBias $weights.AlbertEmbeddings.'LayerNorm.bias'
[float[]] $expected = & (Join-Path $modelRoot 'Invoke-KokoroAlbertEmbeddingProjection.ps1') `
    -Embeddings $embedding -Weights $weights.AlbertProjection.weight `
    -Bias $weights.AlbertProjection.bias -Tokens $tokens.Length

[float[]] $packedWeights = [float[]]::new(
    $weights.AlbertProjection.weight.Length + $weights.AlbertProjection.bias.Length)
if ($VectorOutputTiles) {
    for ($inputChannel = 0; $inputChannel -lt 128; $inputChannel++) {
        for ($outputChannel = 0; $outputChannel -lt 768; $outputChannel++) {
            $packedWeights[$inputChannel * 768 + $outputChannel] =
                $weights.AlbertProjection.weight[$outputChannel * 128 + $inputChannel]
        }
    }
} else {
    [Array]::Copy($weights.AlbertProjection.weight, 0, $packedWeights, 0,
        $weights.AlbertProjection.weight.Length)
}
[Array]::Copy($weights.AlbertProjection.bias, 0, $packedWeights,
    $weights.AlbertProjection.weight.Length, $weights.AlbertProjection.bias.Length)

$write = {
    param([string] $Name, [float[]] $Values)
    [byte[]] $bytes = [byte[]]::new(4 * $Values.Length)
    [Buffer]::BlockCopy($Values, 0, $bytes, 0, $bytes.Length)
    $path = Join-Path $output $Name
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
    [ordered]@{ Name = $Name; Bytes = $bytes.Length
        SHA256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) }
}
$inputRecord = & $write 'input.f32' $embedding
$weightRecord = & $write 'weights-bias.f32' $packedWeights
$expectedRecord = & $write 'expected.f32' $expected
$receipt = [ordered]@{
    Schema = 1
    Role = 'stock_albert_embedding_projection_differential_fixture'
    CheckpointSHA256 = $weights.CheckpointSha256
    TokenIds = $tokens
    Rows = $tokens.Length
    InputChannels = 128
    OutputChannels = 768
    WeightLayout = $(if ($VectorOutputTiles) { 'input_output_bias' } else { 'output_input_bias' })
    Input = $inputRecord
    WeightsAndBias = $weightRecord
    Expected = $expectedRecord
    Oracle = 'Invoke-KokoroAlbertEmbeddingProjection.ps1'
}
$json = [Text.Encoding]::UTF8.GetBytes((($receipt | ConvertTo-Json -Depth 5) + "`n"))
$manifestPath = Join-Path $output 'fixture.json'
$stream = [IO.File]::Open($manifestPath, [IO.FileMode]::CreateNew,
    [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $stream.Write($json); $stream.Flush($true) } finally { $stream.Dispose() }
[pscustomobject]@{ Directory = $output; Rows = $tokens.Length
    InputChannels = 128; OutputChannels = 768; Values = $expected.Length
    FixtureSHA256 = (Get-FileHash -LiteralPath $manifestPath).Hash }
