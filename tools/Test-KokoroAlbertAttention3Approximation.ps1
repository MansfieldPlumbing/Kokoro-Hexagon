#requires -Version 7.4
[CmdletBinding()]
param([string]$QkvFixture=(Join-Path $PSScriptRoot '..\build\albert-qkv-vector-fixture-001\expected.f32'))
$ErrorActionPreference='Stop'
$bytes=[IO.File]::ReadAllBytes($QkvFixture);if($bytes.Length -ne 27648){throw 'QKV fixture length differs.'}
$qkv=[float[]]::new(6912);[Buffer]::BlockCopy($bytes,0,$qkv,0,$bytes.Length)
$actual=& (Join-Path $PSScriptRoot '..\src\models\Invoke-KokoroAlbertAttention3Approximation.ps1') -Qkv $qkv
$query=[float[]]::new(2304);$key=[float[]]::new(2304);$value=[float[]]::new(2304)
for($row=0;$row -lt 3;$row++){[Array]::Copy($qkv,$row*2304,$query,$row*768,768);[Array]::Copy($qkv,$row*2304+768,$key,$row*768,768);[Array]::Copy($qkv,$row*2304+1536,$value,$row*768,768)}
$expected=& (Join-Path $PSScriptRoot '..\src\models\Invoke-KokoroAlbertAttentionCore.ps1') -Query $query -Key $key -Value $value -Tokens 3 -HiddenSize 768 -Heads 12
$maxError=0.0;$sumSquared=0.0
for($i=0;$i -lt $actual.Length;$i++){$error=[double]$actual[$i]-$expected[$i];$maxError=[Math]::Max($maxError,[Math]::Abs($error));$sumSquared+=$error*$error}
if($maxError -gt 0.00001){throw "Attention3 approximation error $maxError exceeds 1e-5."}
[pscustomobject]@{Values=$actual.Length;MaximumAbsoluteError=$maxError;RootMeanSquareError=[Math]::Sqrt($sumSquared/$actual.Length)}
