#requires -Version 7.4
# Fused stock Q/K/V fixture. Three source affines are concatenated along the
# output-channel axis so one directly emitted job can reuse the same input.
[CmdletBinding()]
param(
    [string] $CheckpointPath = 'C:\models\Kokoro-82M\kokoro-v1_0.pth',
    [string] $OutputDirectory = (Join-Path $PSScriptRoot '../build/albert-qkv-vector-fixture')
)
$ErrorActionPreference = 'Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$build=[IO.Path]::GetFullPath((Join-Path $repo 'build'))
$output=[IO.Path]::GetFullPath($OutputDirectory)
if(-not $output.StartsWith($build+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or
   ([IO.Directory]::Exists($output) -and @(Get-ChildItem -LiteralPath $output -Force).Count)){
    throw 'Fixture output must be a new or empty directory under build.'
}
[void][IO.Directory]::CreateDirectory($output)
$modelRoot=Join-Path $repo 'src/models'
$weights=& (Join-Path $modelRoot 'Read-KokoroAcousticWeights.ps1') -CheckpointPath $CheckpointPath -SkipFiniteScan
[int[]]$tokens=@(0,43,0)
[float[]]$embedding=& (Join-Path $modelRoot 'Invoke-KokoroAlbertEmbeddings.ps1') `
    -TokenIds $tokens -WordWeights $weights.AlbertEmbeddings.'word.weight' `
    -PositionWeights $weights.AlbertEmbeddings.'position.weight' `
    -TokenTypeWeights $weights.AlbertEmbeddings.'token_type.weight' `
    -LayerNormWeight $weights.AlbertEmbeddings.'LayerNorm.weight' `
    -LayerNormBias $weights.AlbertEmbeddings.'LayerNorm.bias'
[float[]]$hidden=& (Join-Path $modelRoot 'Invoke-KokoroAlbertEmbeddingProjection.ps1') `
    -Embeddings $embedding -Weights $weights.AlbertProjection.weight `
    -Bias $weights.AlbertProjection.bias -Tokens 3
$outputs=@{}
foreach($name in 'query','key','value'){
    [float[]]$outputs[$name]=& (Join-Path $modelRoot 'Invoke-KokoroAlbertEmbeddingProjection.ps1') `
        -Embeddings $hidden -Weights $weights.AlbertAttention["$name.weight"] `
        -Bias $weights.AlbertAttention["$name.bias"] -Tokens 3 -EmbeddingSize 768 -HiddenSize 768
}
[float[]]$expected=[float[]]::new(3*2304)
for($row=0;$row -lt 3;$row++){
    for($group=0;$group -lt 3;$group++){
        $name=@('query','key','value')[$group]
        [Array]::Copy($outputs[$name],$row*768,$expected,$row*2304+$group*768,768)
    }
}
[float[]]$packed=[float[]]::new(768*2304+2304)
for($inputChannel=0;$inputChannel -lt 768;$inputChannel++){
    for($group=0;$group -lt 3;$group++){
        $name=@('query','key','value')[$group]
        for($outputChannel=0;$outputChannel -lt 768;$outputChannel++){
            $packed[$inputChannel*2304+$group*768+$outputChannel]=
                $weights.AlbertAttention["$name.weight"][$outputChannel*768+$inputChannel]
        }
    }
}
for($group=0;$group -lt 3;$group++){
    $name=@('query','key','value')[$group]
    [Array]::Copy($weights.AlbertAttention["$name.bias"],0,$packed,768*2304+$group*768,768)
}
$write={param([string]$Name,[float[]]$Values)
    [byte[]]$bytes=[byte[]]::new(4*$Values.Length);[Buffer]::BlockCopy($Values,0,$bytes,0,$bytes.Length)
    $path=Join-Path $output $Name;$stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes);$stream.Flush($true)}finally{$stream.Dispose()}
    [ordered]@{Name=$Name;Bytes=$bytes.Length;SHA256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))}
}
$receipt=[ordered]@{
    Schema=1;Role='stock_albert_attention_fused_qkv_differential_fixture'
    CheckpointSHA256=$weights.CheckpointSha256;TokenIds=$tokens
    Rows=3;InputChannels=768;OutputChannels=2304;WeightLayout='input_output_bias'
    OutputLayout='row_then_query_key_value';Input=(& $write 'input.f32' $hidden)
    WeightsAndBias=(& $write 'weights-bias.f32' $packed);Expected=(& $write 'expected.f32' $expected)
    Oracle='three Invoke-KokoroAlbertEmbeddingProjection.ps1 results concatenated per row'
}
$json=[Text.Encoding]::UTF8.GetBytes((($receipt|ConvertTo-Json -Depth 5)+"`n"))
$manifestPath=Join-Path $output 'fixture.json';$stream=[IO.File]::Open($manifestPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try{$stream.Write($json);$stream.Flush($true)}finally{$stream.Dispose()}
[pscustomobject]@{Directory=$output;Values=$expected.Length;FixtureSHA256=(Get-FileHash $manifestPath).Hash}
