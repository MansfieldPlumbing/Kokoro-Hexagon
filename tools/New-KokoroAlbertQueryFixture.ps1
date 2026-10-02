#requires -Version 7.4
# Connected stock-weight fixture: admitted tokens through ALBERT input mapping,
# then the first attention query projection. Runtime tensor math remains on DSP.
[CmdletBinding()]
param(
    [string] $CheckpointPath = 'C:\models\Kokoro-82M\kokoro-v1_0.pth',
    [string] $OutputDirectory = (Join-Path $PSScriptRoot '../build/albert-query-vector-fixture'),
    [ValidateSet('Query','Key','Value')][string] $Projection = 'Query',
    [switch] $Scalar
)

$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$build = [IO.Path]::GetFullPath((Join-Path $repo 'build'))
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $output.StartsWith($build + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase) -or
    ([IO.Directory]::Exists($output) -and @(Get-ChildItem -LiteralPath $output -Force).Count)) {
    throw 'Fixture output must be a new or empty directory under build.'
}
[void][IO.Directory]::CreateDirectory($output)
$modelRoot = Join-Path $repo 'src/models'
$weights = & (Join-Path $modelRoot 'Read-KokoroAcousticWeights.ps1') `
    -CheckpointPath $CheckpointPath -SkipFiniteScan
$projectionName = $Projection.ToLowerInvariant()
$weightKey = "$projectionName.weight"; $biasKey = "$projectionName.bias"
[int[]] $tokens = @(0, 43, 0)
[float[]] $embedding = & (Join-Path $modelRoot 'Invoke-KokoroAlbertEmbeddings.ps1') `
    -TokenIds $tokens -WordWeights $weights.AlbertEmbeddings.'word.weight' `
    -PositionWeights $weights.AlbertEmbeddings.'position.weight' `
    -TokenTypeWeights $weights.AlbertEmbeddings.'token_type.weight' `
    -LayerNormWeight $weights.AlbertEmbeddings.'LayerNorm.weight' `
    -LayerNormBias $weights.AlbertEmbeddings.'LayerNorm.bias'
[float[]] $hidden = & (Join-Path $modelRoot 'Invoke-KokoroAlbertEmbeddingProjection.ps1') `
    -Embeddings $embedding -Weights $weights.AlbertProjection.weight `
    -Bias $weights.AlbertProjection.bias -Tokens 3
[float[]] $expected = & (Join-Path $modelRoot 'Invoke-KokoroAlbertEmbeddingProjection.ps1') `
    -Embeddings $hidden -Weights $weights.AlbertAttention[$weightKey] `
    -Bias $weights.AlbertAttention[$biasKey] -Tokens 3 `
    -EmbeddingSize 768 -HiddenSize 768

[float[]] $packed = [float[]]::new(768 * 768 + 768)
if ($Scalar) {
    [Array]::Copy($weights.AlbertAttention[$weightKey], 0, $packed, 0, 768 * 768)
} else {
    for ($inputChannel = 0; $inputChannel -lt 768; $inputChannel++) {
        for ($outputChannel = 0; $outputChannel -lt 768; $outputChannel++) {
            $packed[$inputChannel * 768 + $outputChannel] =
                $weights.AlbertAttention[$weightKey][$outputChannel * 768 + $inputChannel]
        }
    }
}
[Array]::Copy($weights.AlbertAttention[$biasKey], 0, $packed, 768 * 768, 768)
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
$receipt = [ordered]@{
    Schema = 1; Role = "stock_albert_attention_${projectionName}_differential_fixture"
    CheckpointSHA256 = $weights.CheckpointSha256; TokenIds = $tokens
    Rows = 3; InputChannels = 768; OutputChannels = 768
    WeightLayout = $(if ($Scalar) { 'output_input_bias' } else { 'input_output_bias' })
    Input = (& $write 'input.f32' $hidden)
    WeightsAndBias = (& $write 'weights-bias.f32' $packed)
    Expected = (& $write 'expected.f32' $expected)
    Oracle = 'Invoke-KokoroAlbertEmbeddingProjection.ps1'
}
$json = [Text.Encoding]::UTF8.GetBytes((($receipt | ConvertTo-Json -Depth 5) + "`n"))
$manifestPath = Join-Path $output 'fixture.json'
$stream = [IO.File]::Open($manifestPath, [IO.FileMode]::CreateNew,
    [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $stream.Write($json); $stream.Flush($true) } finally { $stream.Dispose() }
[pscustomobject]@{ Directory = $output; Values = $expected.Length
    FixtureSHA256 = (Get-FileHash -LiteralPath $manifestPath).Hash }
