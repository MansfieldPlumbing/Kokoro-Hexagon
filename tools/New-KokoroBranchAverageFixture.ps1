#requires -Version 7.4
param([ValidateSet(128,256)][int]$Channels=128,[Parameter(Mandatory)][string[]]$Inputs,[Parameter(Mandatory)][double[]]$InputScales,[Parameter(Mandatory)][double]$OutputScale,[ValidateRange(2,32768)][int]$Frames,[Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop';$build=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build'))+[IO.Path]::DirectorySeparatorChar
$out=[IO.Path]::GetFullPath($OutputDirectory);if(-not $out.StartsWith($build,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path $out)){throw 'Use a new branch fixture in build/'}
if($Inputs.Count -ne 3 -or $InputScales.Count -ne 3 -or -not [double]::IsFinite($OutputScale) -or $OutputScale -le 0){throw 'Three finite-scale branches required'}
$tiles=[int][math]::Ceiling($Frames/32);$length=$tiles*$Channels*64;$data=[Collections.Generic.List[byte[]]]::new();$multipliers=[int[]]::new(3);$sum=0L
for($i=0;$i -lt 3;$i++){
 $path=[IO.Path]::GetFullPath($Inputs[$i]);if(-not $path.StartsWith($build,[StringComparison]::OrdinalIgnoreCase) -or (Get-Item $path).Length -ne $length -or -not [double]::IsFinite($InputScales[$i]) -or $InputScales[$i] -le 0){throw 'Native branch shape/scale mismatch'}
 $m=[long][math]::Round($InputScales[$i]/(3*$OutputScale)*65536,[MidpointRounding]::ToEven);if($m -lt 1 -or $m -gt 8000000){throw 'Branch scale precision outside implemented bounds'}
 $multipliers[$i]=$m;$sum+=$m;$data.Add([IO.File]::ReadAllBytes($path))
}
$bias=128L*65536-128L*$sum+32768
if($bias -lt [int]::MinValue -or $bias+255*$sum -gt [int]::MaxValue -or 255*$sum -gt [int]::MaxValue){throw 'Branch sum exceeds signed int32'}
$expected=[byte[]]::new($length)
for($i=1;$i -lt $length;$i+=2){$v=[long]$multipliers[0]*$data[0][$i]+[long]$multipliers[1]*$data[1][$i]+[long]$multipliers[2]*$data[2][$i]+$bias;$q=[long][math]::Floor($v/65536.0);$expected[$i]=[byte][math]::Clamp($q,0L,255L)}
$parameters=[byte[]]::new(16);for($i=0;$i -lt 3;$i++){[BitConverter]::GetBytes($multipliers[$i]).CopyTo($parameters,4*$i)};[BitConverter]::GetBytes([int]$bias).CopyTo($parameters,12)
[void][IO.Directory]::CreateDirectory($out)
for($i=0;$i -lt 3;$i++){[IO.File]::WriteAllBytes((Join-Path $out "branch$i.bin"),$data[$i])}
[IO.File]::WriteAllBytes((Join-Path $out 'parameters.bin'),$parameters);[IO.File]::WriteAllBytes((Join-Path $out 'expected.bin'),$expected)
[ordered]@{Frames=$Frames;Tiles=$tiles;Channels=$Channels;InputScales=$InputScales;OutputScale=$OutputScale;Multipliers=$multipliers;Bias=$bias;Inputs=@($Inputs|ForEach-Object{[ordered]@{Path=[IO.Path]::GetFullPath($_);SHA256=(Get-FileHash $_).Hash}});ExpectedSHA256=(Get-FileHash (Join-Path $out 'expected.bin')).Hash}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $out 'fixture.json') -Encoding utf8NoBOM
[pscustomobject]@{Tiles=$tiles;Frames=$Frames;Directory=$out}
