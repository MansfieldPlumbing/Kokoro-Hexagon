#requires -Version 7.4
[CmdletBinding()]
param([string] $CheckpointPath)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stage = Join-Path $root 'src/models/Invoke-KokoroAlbertEmbeddings.ps1'
$word = [float[]]@(0, 1, 2, 3, 4, 5, 6, 7)
$position = [float[]]@(0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0)
$types = [float[]]@(0, 0, 0, 0, 0, 0, 0, 0)
$gain = [float[]]@(1, 1, 1, 1)
$bias = [float[]]@(0, 0, 0, 0)
$actual = & $stage -TokenIds ([int[]]@(0, 1)) -WordWeights $word `
    -PositionWeights $position -TokenTypeWeights $types `
    -LayerNormWeight $gain -LayerNormBias $bias -EmbeddingSize 4 `
    -VocabularySize 2 -MaxPositions 3 -TokenTypeCount 2
$expectedFirst = [double[]]@(-1.3416407865, -0.4472135955, 0.4472135955, 1.3416407865)
$expectedSecond = [double[]]@(-0.9045340337, -0.9045340337, 0.3015113446, 1.5075567229)
for ($i = 0; $i -lt 4; $i++) {
    if ([Math]::Abs([double]$actual[$i] - $expectedFirst[$i]) -gt 1e-6 -or
        [Math]::Abs([double]$actual[$i + 4] - $expectedSecond[$i]) -gt 1e-6) {
        throw 'Analytic ALBERT embedding differs.'
    }
}
$rejected = $false
try {
    $null = & $stage -TokenIds ([int[]]@(0, 2)) -WordWeights $word `
        -PositionWeights $position -TokenTypeWeights $types `
        -LayerNormWeight $gain -LayerNormBias $bias -EmbeddingSize 4 `
        -VocabularySize 2 -MaxPositions 3 -TokenTypeCount 2
} catch { $rejected = $true }
if (-not $rejected) { throw 'Out-of-range ALBERT token ID was admitted.' }
$projection = Join-Path $root 'src/models/Invoke-KokoroAlbertEmbeddingProjection.ps1'
$projected = & $projection -Embeddings ([float[]]@(1, 2, 3, 4, 5, 6)) `
    -Weights ([float[]]@(1, 0, -1, 0, 1, 1)) -Bias ([float[]]@(0.5, -1)) `
    -Tokens 2 -EmbeddingSize 3 -HiddenSize 2
if ($projected.Length -ne 4 -or $projected[0] -ne -1.5 -or
    $projected[1] -ne 4 -or $projected[2] -ne -1.5 -or $projected[3] -ne 10) {
    throw 'Analytic ALBERT embedding projection differs.'
}

if ($CheckpointPath) {
    $pin = @(([IO.File]::ReadAllText((Join-Path $root 'lib/manifest.json')) |
        ConvertFrom-Json -AsHashtable).model.files | Where-Object { $_.path -ceq 'kokoro-v1_0.pth' })
    $path = (Resolve-Path -LiteralPath $CheckpointPath).Path
    if ($pin.Count -ne 1 -or (Get-Item -LiteralPath $path).Length -ne [long]$pin[0].bytes -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $pin[0].sha256) {
        throw 'Stock checkpoint does not match the pinned digest.'
    }
    $reader = [scriptblock]::Create([IO.File]::ReadAllText(
        (Join-Path $root 'src/runspace/Torch.Checkpoint.psm1'))).InvokeReturnAsIs()
    $checkpoint = & $reader.Read $path
    $prefix = 'bert.module.embeddings.'
    $specs = [ordered]@{
        'word_embeddings.weight' = '178,128'
        'position_embeddings.weight' = '512,128'
        'token_type_embeddings.weight' = '2,128'
        'LayerNorm.weight' = '128'
        'LayerNorm.bias' = '128'
    }
    $tensors = @{}
    foreach ($suffix in $specs.Keys) {
        $name = $prefix + $suffix
        $descriptor = $checkpoint.Tensors[$name]
        if ($null -eq $descriptor -or ($descriptor.Shape -join ',') -cne $specs[$suffix]) {
            throw 'Stock ALBERT embedding tensor shape differs.'
        }
        [byte[]]$bytes = & $reader.Bytes $checkpoint $name
        [float[]]$values = [float[]]::new($bytes.Length / 4)
        [Buffer]::BlockCopy($bytes, 0, $values, 0, $bytes.Length)
        $tensors[$suffix] = $values
    }
    $stock = & $stage -TokenIds ([int[]]@(0, 43, 0)) `
        -WordWeights $tensors['word_embeddings.weight'] `
        -PositionWeights $tensors['position_embeddings.weight'] `
        -TokenTypeWeights $tensors['token_type_embeddings.weight'] `
        -LayerNormWeight $tensors['LayerNorm.weight'] `
        -LayerNormBias $tensors['LayerNorm.bias']
    if ($stock.Length -ne 384) { throw 'Stock ALBERT embedding output shape differs.' }
    foreach ($value in $stock) {
        if (-not [float]::IsFinite($value)) { throw 'Stock ALBERT embedding output is non-finite.' }
    }
    $projectionNames = @{
        Weight = 'bert.module.encoder.embedding_hidden_mapping_in.weight'
        Bias = 'bert.module.encoder.embedding_hidden_mapping_in.bias'
    }
    $projectionTensors = @{}
    foreach ($entry in $projectionNames.GetEnumerator()) {
        $descriptor = $checkpoint.Tensors[$entry.Value]
        $expectedShape = if ($entry.Key -eq 'Weight') { '768,128' } else { '768' }
        if ($null -eq $descriptor -or ($descriptor.Shape -join ',') -cne $expectedShape) {
            throw 'Stock ALBERT projection tensor shape differs.'
        }
        [byte[]]$bytes = & $reader.Bytes $checkpoint $entry.Value
        [float[]]$values = [float[]]::new($bytes.Length / 4)
        [Buffer]::BlockCopy($bytes, 0, $values, 0, $bytes.Length)
        $projectionTensors[$entry.Key] = $values
    }
    $stockProjection = & $projection -Embeddings $stock `
        -Weights $projectionTensors.Weight -Bias $projectionTensors.Bias -Tokens 3
    if ($stockProjection.Length -ne 2304) { throw 'Stock ALBERT projected shape differs.' }
    foreach ($value in $stockProjection) {
        if (-not [float]::IsFinite($value)) { throw 'Stock ALBERT projection is non-finite.' }
    }
}
Write-Output 'PASS: ALBERT embeddings and projection arithmetic, bounds, and optional pinned checkpoint shapes'
