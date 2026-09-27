#requires -Version 7.4
# Build-time stock acoustic tensor admission for the PowerShell model path.
# Kokoro checkpoint revision f3ff3571791e39611d31c381e3a41a3af07b4987.
[CmdletBinding()]
param([Parameter(Mandatory)][string] $CheckpointPath)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
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
$shapes = @{}
$destinations = @{}
function Add-Spec([string] $Name, [string] $Shape, [string] $Group, [string] $Key) {
    if ($shapes.ContainsKey($Name)) { throw "Duplicate acoustic tensor declaration: $Name" }
    $shapes[$Name] = $Shape
    $destinations[$Name] = @($Group, $Key)
}

$embeddingPrefix = 'bert.module.embeddings.'
foreach ($entry in @(
    @('word.weight', 'word_embeddings.weight', '178,128'),
    @('position.weight', 'position_embeddings.weight', '512,128'),
    @('token_type.weight', 'token_type_embeddings.weight', '2,128'),
    @('LayerNorm.weight', 'LayerNorm.weight', '128'),
    @('LayerNorm.bias', 'LayerNorm.bias', '128'))) {
    Add-Spec ($embeddingPrefix + $entry[1]) $entry[2] 'AlbertEmbeddings' $entry[0]
}
Add-Spec 'bert.module.encoder.embedding_hidden_mapping_in.weight' '768,128' 'AlbertProjection' 'weight'
Add-Spec 'bert.module.encoder.embedding_hidden_mapping_in.bias' '768' 'AlbertProjection' 'bias'
$layerPrefix = 'bert.module.encoder.albert_layer_groups.0.albert_layers.0.'
foreach ($name in @('query', 'key', 'value', 'dense', 'LayerNorm')) {
    foreach ($suffix in @('weight', 'bias')) {
        $shape = if ($suffix -eq 'weight' -and $name -ne 'LayerNorm') { '768,768' } else { '768' }
        Add-Spec ($layerPrefix + "attention.$name.$suffix") $shape 'AlbertAttention' "$name.$suffix"
    }
}
$ffnShapes = @{
    'ffn.weight' = '2048,768'; 'ffn.bias' = '2048'
    'ffn_output.weight' = '768,2048'; 'ffn_output.bias' = '768'
    'full_layer_layer_norm.weight' = '768'; 'full_layer_layer_norm.bias' = '768'
}
foreach ($entry in $ffnShapes.GetEnumerator()) {
    Add-Spec ($layerPrefix + $entry.Key) $entry.Value 'AlbertFeedForward' $entry.Key
}
Add-Spec 'bert_encoder.module.weight' '512,768' 'BertEncoder' 'weight'
Add-Spec 'bert_encoder.module.bias' '512' 'BertEncoder' 'bias'

for ($layer = 0; $layer -lt 3; $layer++) {
    $lstmIndex = 2 * $layer
    $normIndex = $lstmIndex + 1
    foreach ($suffix in @('', '_reverse')) {
        foreach ($name in @('weight_ih_l0', 'weight_hh_l0', 'bias_ih_l0', 'bias_hh_l0')) {
            $shape = if ($name -eq 'weight_ih_l0') { '1024,640' }
                elseif ($name -eq 'weight_hh_l0') { '1024,256' } else { '1024' }
            $key = "lstms.$lstmIndex.$name$suffix"
            Add-Spec ('predictor.module.text_encoder.' + $key) $shape 'DurationEncoderParameters' $key
        }
    }
    foreach ($suffix in @('weight', 'bias')) {
        $key = "lstms.$normIndex.fc.$suffix"
        $shape = if ($suffix -eq 'weight') { '1024,128' } else { '1024' }
        Add-Spec ('predictor.module.text_encoder.' + $key) $shape 'DurationEncoderParameters' $key
    }
}
foreach ($suffix in @('', '_reverse')) {
    foreach ($name in @('weight_ih_l0', 'weight_hh_l0', 'bias_ih_l0', 'bias_hh_l0')) {
        $shape = if ($name -eq 'weight_ih_l0') { '1024,640' }
            elseif ($name -eq 'weight_hh_l0') { '1024,256' } else { '1024' }
        $key = "$name$suffix"
        Add-Spec ('predictor.module.lstm.' + $key) $shape 'DurationLstmParameters' $key
    }
}
Add-Spec 'predictor.module.duration_proj.linear_layer.weight' '50,512' 'DurationProjection' 'weight'
Add-Spec 'predictor.module.duration_proj.linear_layer.bias' '50' 'DurationProjection' 'bias'

$textPrefix = 'text_encoder.module.'
Add-Spec ($textPrefix + 'embedding.weight') '178,512' 'TextEncoderParameters' 'embedding.weight'
for ($layer = 0; $layer -lt 3; $layer++) {
    foreach ($entry in @(
        @("cnn.$layer.0.weight_v", '512,512,5'),
        @("cnn.$layer.0.weight_g", '512,1,1'),
        @("cnn.$layer.0.bias", '512'),
        @("cnn.$layer.1.gamma", '512'),
        @("cnn.$layer.1.beta", '512'))) {
        Add-Spec ($textPrefix + $entry[0]) $entry[1] 'TextEncoderParameters' $entry[0]
    }
}
foreach ($suffix in @('', '_reverse')) {
    foreach ($name in @('weight_ih_l0', 'weight_hh_l0', 'bias_ih_l0', 'bias_hh_l0')) {
        $shape = if ($name -eq 'weight_ih_l0') { '1024,512' }
            elseif ($name -eq 'weight_hh_l0') { '1024,256' } else { '1024' }
        $key = "lstm.$name$suffix"
        Add-Spec ($textPrefix + $key) $shape 'TextEncoderParameters' $key
    }
}

foreach ($suffix in @('', '_reverse')) {
    foreach ($name in @('weight_ih_l0', 'weight_hh_l0', 'bias_ih_l0', 'bias_hh_l0')) {
        $shape = if ($name -eq 'weight_ih_l0') { '1024,640' }
            elseif ($name -eq 'weight_hh_l0') { '1024,256' } else { '1024' }
        $key = "shared.$name$suffix"
        Add-Spec ('predictor.module.' + $key) $shape 'F0NParameters' $key
    }
}
foreach ($branch in @('F0', 'N')) {
    for ($block = 0; $block -lt 3; $block++) {
        $inputChannels = if ($block -lt 2) { 512 } else { 256 }
        $outputChannels = if ($block -eq 0) { 512 } else { 256 }
        $blockPrefix = "$branch.$block."
        foreach ($stage in 1, 2) {
            $channels = if ($stage -eq 1) { $inputChannels } else { $outputChannels }
            foreach ($entry in @(
                @("norm$stage.fc.weight", "$(2 * $channels),128"),
                @("norm$stage.fc.bias", "$(2 * $channels)"),
                @("conv$stage.weight_v", "$outputChannels,$channels,3"),
                @("conv$stage.weight_g", "$outputChannels,1,1"),
                @("conv$stage.bias", "$outputChannels"))) {
                $key = $blockPrefix + $entry[0]
                Add-Spec ('predictor.module.' + $key) $entry[1] 'F0NParameters' $key
            }
        }
        if ($block -eq 1) {
            foreach ($entry in @(
                @('pool.weight_v', '512,1,3'),
                @('pool.weight_g', '512,1,1'),
                @('pool.bias', '512'),
                @('conv1x1.weight_v', '256,512,1'),
                @('conv1x1.weight_g', '256,1,1'))) {
                $key = $blockPrefix + $entry[0]
                Add-Spec ('predictor.module.' + $key) $entry[1] 'F0NParameters' $key
            }
        }
    }
    Add-Spec "predictor.module.${branch}_proj.weight" '1,256,1' 'F0NParameters' "${branch}_proj.weight"
    Add-Spec "predictor.module.${branch}_proj.bias" '1' 'F0NParameters' "${branch}_proj.bias"
}
if ($shapes.Count -ne 171) { throw 'Acoustic tensor specification count differs.' }

foreach ($name in $shapes.Keys) {
    $descriptor = $checkpoint.Tensors[$name]
    if ($null -eq $descriptor -or $descriptor.DType -cne 'float32' -or
        ($descriptor.Shape -join ',') -cne $shapes[$name]) {
        throw "Stock acoustic tensor shape or element width differs: $name"
    }
    $expectedStride = 1L
    for ($axis = $descriptor.Shape.Length - 1; $axis -ge 0; $axis--) {
        if ($descriptor.Stride[$axis] -ne $expectedStride) {
            throw "Stock acoustic tensor is not contiguous: $name"
        }
        $expectedStride *= $descriptor.Shape[$axis]
    }
}
$sets = @{}
foreach ($group in @('AlbertEmbeddings', 'AlbertProjection', 'AlbertAttention',
        'AlbertFeedForward', 'BertEncoder', 'DurationEncoderParameters',
        'DurationLstmParameters', 'DurationProjection',
        'TextEncoderParameters', 'F0NParameters')) {
    $sets[$group] = @{}
}
foreach ($name in $shapes.Keys) {
    [byte[]]$bytes = & $reader.Bytes $checkpoint $name
    $values = [float[]]::new($bytes.Length / 4)
    [Buffer]::BlockCopy($bytes, 0, $values, 0, $bytes.Length)
    foreach ($value in $values) {
        if (-not [float]::IsFinite($value)) { throw "Stock acoustic tensor is non-finite: $name" }
    }
    $destination = $destinations[$name]
    $sets[$destination[0]][$destination[1]] = $values
}
[pscustomobject]@{
    AlbertEmbeddings = $sets.AlbertEmbeddings
    AlbertProjection = $sets.AlbertProjection
    AlbertAttention = $sets.AlbertAttention
    AlbertFeedForward = $sets.AlbertFeedForward
    BertEncoderWeights = $sets.BertEncoder.weight
    BertEncoderBias = $sets.BertEncoder.bias
    DurationEncoderParameters = $sets.DurationEncoderParameters
    DurationLstmParameters = $sets.DurationLstmParameters
    DurationWeights = $sets.DurationProjection.weight
    DurationBias = $sets.DurationProjection.bias
    TextEncoderParameters = $sets.TextEncoderParameters
    F0NParameters = $sets.F0NParameters
    TensorCount = $shapes.Count
    CheckpointSha256 = $pin[0].sha256
}
