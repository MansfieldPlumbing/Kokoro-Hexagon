#requires -Version 7.4
param([Parameter(Mandatory)][string]$InputPath,[Parameter(Mandatory)][double]$InputScale,[Parameter(Mandatory)][double]$OutputScale,[ValidateSet(.01,.1)][double]$NegativeSlope=.01,[ValidateSet(128,256)][int]$Channels=128,[ValidateRange(2,32768)][int]$Frames,[Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop';$build=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build'))+[IO.Path]::DirectorySeparatorChar
$inputFile=[IO.Path]::GetFullPath($InputPath);$out=[IO.Path]::GetFullPath($OutputDirectory)
if(-not $inputFile.StartsWith($build,[StringComparison]::OrdinalIgnoreCase) -or -not $out.StartsWith($build,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path $out)){throw 'Use a project build input and new output directory'}
if(-not [double]::IsFinite($InputScale) -or -not [double]::IsFinite($OutputScale) -or $InputScale -le 0 -or $OutputScale -le 0){throw 'Finite positive scales required'}
$tiles=[int][math]::Ceiling($Frames/32);$length=$tiles*$Channels*64
$data=[IO.File]::ReadAllBytes($inputFile);if($data.Length -ne $length){throw 'Native input length mismatch'}
$positive=[long][math]::Round($InputScale/$OutputScale*65536,[MidpointRounding]::ToEven)
$negative=[long][math]::Round($InputScale/$OutputScale*$NegativeSlope*65536,[MidpointRounding]::ToEven)
$bias=128L*65536-128L*($positive+$negative)+32768
if($positive -lt 1 -or $negative -lt 1 -or $positive+$negative -gt 8000000 -or $bias -lt [int]::MinValue -or $bias+255*($positive+$negative) -gt [int]::MaxValue -or 255*($positive+$negative) -gt [int]::MaxValue){throw 'LeakyReLU int32 precision bounds'}
$expected=[byte[]]::new($length)
for($i=1;$i -lt $length;$i+=2){$u=[long]$data[$i];$value=$positive*[math]::Max($u,128L)+$negative*[math]::Min($u,128L)+$bias;$q=[long][math]::Floor($value/65536.0);$expected[$i]=[byte][math]::Clamp($q,0L,255L)}
$params=[byte[]]::new(12);[BitConverter]::GetBytes([int]$positive).CopyTo($params,0);[BitConverter]::GetBytes([int]$negative).CopyTo($params,4);[BitConverter]::GetBytes([int]$bias).CopyTo($params,8)
[void][IO.Directory]::CreateDirectory($out)
foreach($pair in @(@('input.bin',$data),@('parameters.bin',$params),@('expected.bin',$expected))){[IO.File]::WriteAllBytes((Join-Path $out $pair[0]),$pair[1])}
[ordered]@{Frames=$Frames;Tiles=$tiles;Channels=$Channels;InputScale=$InputScale;OutputScale=$OutputScale;NegativeSlope=$NegativeSlope;PositiveMultiplier=$positive;NegativeMultiplier=$negative;Bias=$bias;InputSHA256=(Get-FileHash $inputFile).Hash;ExpectedSHA256=(Get-FileHash (Join-Path $out 'expected.bin')).Hash}|ConvertTo-Json|Set-Content (Join-Path $out 'fixture.json') -Encoding utf8NoBOM
[pscustomobject]@{Frames=$Frames;Channels=$Channels;Directory=$out}
