#requires -Version 7.4
[CmdletBinding()]
param(
    [string]$QkvFixtureDirectory=(Join-Path $PSScriptRoot '..\build\albert-qkv-vector-fixture-001'),
    [string]$OutputDirectory=(Join-Path $PSScriptRoot '..\build\albert-attention3-fixture-001')
)
$ErrorActionPreference='Stop'
$sourceManifestPath=Join-Path $QkvFixtureDirectory 'fixture.json';$sourceBytes=[IO.File]::ReadAllBytes($sourceManifestPath);$sourceDocument=[Text.Json.JsonDocument]::Parse([Text.Encoding]::UTF8.GetString($sourceBytes))
try{
    $source=$sourceDocument.RootElement;$record=$source.GetProperty('Expected');$sourcePath=Join-Path $QkvFixtureDirectory $record.GetProperty('Name').GetString();$inputBytes=[IO.File]::ReadAllBytes($sourcePath)
    if($source.GetProperty('Role').GetString() -ne 'stock_albert_attention_fused_qkv_differential_fixture' -or $inputBytes.Length -ne 27648 -or (Get-FileHash $sourcePath).Hash -ne $record.GetProperty('SHA256').GetString()){throw 'QKV fixture contract or integrity differs.'}
    $qkv=[float[]]::new(6912);[Buffer]::BlockCopy($inputBytes,0,$qkv,0,$inputBytes.Length)
    $context=& (Join-Path $PSScriptRoot '..\src\models\Invoke-KokoroAlbertAttention3Approximation.ps1') -Qkv $qkv
    $expectedBytes=[byte[]]::new(9216);[Buffer]::BlockCopy($context,0,$expectedBytes,0,$expectedBytes.Length)
    [void][IO.Directory]::CreateDirectory($OutputDirectory)
    $inputPath=Join-Path $OutputDirectory 'input-qkv.f32';$expectedPath=Join-Path $OutputDirectory 'expected-context.f32';$manifestPath=Join-Path $OutputDirectory 'fixture.json'
    foreach($path in $inputPath,$expectedPath,$manifestPath){if(Test-Path $path){throw "Fixture output already exists: $path"}}
    [IO.File]::WriteAllBytes($inputPath,$inputBytes);[IO.File]::WriteAllBytes($expectedPath,$expectedBytes)
    $manifest=[ordered]@{Schema=1;Role='stock_albert_attention3_differential_fixture';Tokens=3;Heads=12;HeadWidth=64;InputLayout='row_then_query_key_value';OutputLayout='row_then_head_channel';SourceManifestSHA256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($sourceBytes));Input=[ordered]@{Name='input-qkv.f32';Bytes=$inputBytes.Length;SHA256=(Get-FileHash $inputPath).Hash};Expected=[ordered]@{Name='expected-context.f32';Bytes=$expectedBytes.Length;SHA256=(Get-FileHash $expectedPath).Hash}}
    [IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 5));[pscustomobject]@{Path=$OutputDirectory;ManifestSHA256=(Get-FileHash $manifestPath).Hash}
}finally{$sourceDocument.Dispose();foreach($buffer in @($inputBytes,$qkv,$context,$expectedBytes)){if($null-ne$buffer){[Array]::Clear($buffer,0,$buffer.Length)}}}
