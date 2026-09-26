#requires -Version 7.4
[CmdletBinding()]
param([string] $CheckpointPath)

$ErrorActionPreference = 'Stop'
$stage = Join-Path $PSScriptRoot '../src/models/Invoke-KokoroAlbertEncoder.ps1'
$identity = [float[]]@(1, 0, 0, 1)
$zero = [float[]]@(0, 0)
$embeddings = @{
    'word.weight' = [float[]]@(1, 0, 0, 1)
    'position.weight' = [float[]]@(0, 0, 0, 0)
    'token_type.weight' = [float[]]@(0, 0)
    'LayerNorm.weight' = [float[]]@(1, 1)
    'LayerNorm.bias' = $zero
}
$projection = @{ weight = $identity; bias = $zero }
$attention = @{
    'query.weight' = $identity; 'query.bias' = $zero
    'key.weight' = $identity; 'key.bias' = $zero
    'value.weight' = $identity; 'value.bias' = $zero
    'dense.weight' = $identity; 'dense.bias' = $zero
    'LayerNorm.weight' = [float[]]@(1, 1)
    'LayerNorm.bias' = $zero
}
$feedForward = @{
    'ffn.weight' = [float[]]@(0, 0, 0, 0)
    'ffn.bias' = $zero
    'ffn_output.weight' = [float[]]@(0, 0, 0, 0)
    'ffn_output.bias' = $zero
    'full_layer_layer_norm.weight' = [float[]]@(1, 1)
    'full_layer_layer_norm.bias' = $zero
}
$result = & $stage -TokenIds ([int[]]@(0, 1)) -Embeddings $embeddings `
    -Projection $projection -Attention $attention -FeedForward $feedForward `
    -EmbeddingSize 2 -HiddenSize 2 -IntermediateSize 2 -Heads 1 `
    -LayerRepeats 2 -VocabularySize 2 -MaxPositions 2 -TokenTypeCount 1
if ($result.Length -ne 4 -or
    [Math]::Abs([double]$result[0] - 1) -gt 1e-5 -or
    [Math]::Abs([double]$result[1] + 1) -gt 1e-5 -or
    [Math]::Abs([double]$result[2] + 1) -gt 1e-5 -or
    [Math]::Abs([double]$result[3] - 1) -gt 1e-5) {
    throw 'Analytic ALBERT encoder composition differs.'
}
if ($CheckpointPath) {
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
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
    $read = {
        param([string] $Name, [string] $Shape)
        $descriptor = $checkpoint.Tensors[$Name]
        if ($null -eq $descriptor -or ($descriptor.Shape -join ',') -cne $Shape) {
            throw 'Stock ALBERT encoder tensor shape differs.'
        }
        [byte[]]$bytes = & $reader.Bytes $checkpoint $Name
        [float[]]$values = [float[]]::new($bytes.Length / 4)
        [Buffer]::BlockCopy($bytes, 0, $values, 0, $bytes.Length)
        return ,$values
    }
    $embeddingPrefix = 'bert.module.embeddings.'
    $stockEmbeddings = @{
        'word.weight' = & $read ($embeddingPrefix + 'word_embeddings.weight') '178,128'
        'position.weight' = & $read ($embeddingPrefix + 'position_embeddings.weight') '512,128'
        'token_type.weight' = & $read ($embeddingPrefix + 'token_type_embeddings.weight') '2,128'
        'LayerNorm.weight' = & $read ($embeddingPrefix + 'LayerNorm.weight') '128'
        'LayerNorm.bias' = & $read ($embeddingPrefix + 'LayerNorm.bias') '128'
    }
    $stockProjection = @{
        weight = & $read 'bert.module.encoder.embedding_hidden_mapping_in.weight' '768,128'
        bias = & $read 'bert.module.encoder.embedding_hidden_mapping_in.bias' '768'
    }
    $layerPrefix = 'bert.module.encoder.albert_layer_groups.0.albert_layers.0.'
    $stockAttention = @{}
    foreach ($name in @('query', 'key', 'value', 'dense', 'LayerNorm')) {
        foreach ($suffix in @('weight', 'bias')) {
            $shape = if ($suffix -eq 'weight' -and $name -ne 'LayerNorm') { '768,768' } else { '768' }
            $stockAttention["$name.$suffix"] = & $read ($layerPrefix + "attention.$name.$suffix") $shape
        }
    }
    $stockFeedForward = @{}
    $ffnShapes = @{
        'ffn.weight' = '2048,768'; 'ffn.bias' = '2048'
        'ffn_output.weight' = '768,2048'; 'ffn_output.bias' = '768'
        'full_layer_layer_norm.weight' = '768'; 'full_layer_layer_norm.bias' = '768'
    }
    foreach ($entry in $ffnShapes.GetEnumerator()) {
        $stockFeedForward[$entry.Key] = & $read ($layerPrefix + $entry.Key) $entry.Value
    }
    $stock = & $stage -TokenIds ([int[]]@(0, 43)) -Embeddings $stockEmbeddings `
        -Projection $stockProjection -Attention $stockAttention `
        -FeedForward $stockFeedForward -LayerRepeats 1
    if ($stock.Length -ne 1536) { throw 'Stock ALBERT encoder output shape differs.' }
    foreach ($value in $stock) {
        if (-not [float]::IsFinite($value)) { throw 'Stock ALBERT encoder output is non-finite.' }
    }
}
Write-Output 'PASS: ALBERT shared layer composition and optional stock-weight one-layer gate'
