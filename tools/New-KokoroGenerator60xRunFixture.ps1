#requires -Version 7.4
param([Parameter(Mandatory)][string[]]$BranchDirectories,[Parameter(Mandatory)][string]$AverageDirectory,[Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$build=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build'))+[IO.Path]::DirectorySeparatorChar
$out=[IO.Path]::GetFullPath($OutputDirectory)
if($BranchDirectories.Count -ne 3 -or -not $out.StartsWith($build,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path $out)){throw 'Use three branch fixtures and a new build directory'}
$average=Get-Content (Join-Path $AverageDirectory 'fixture.json') -Raw|ConvertFrom-Json
$weights=[byte[]]::new(2064384);$parameters=[byte[]]::new(147472);$coefficients=[byte[]]::new(18432);$weightAt=0;$hashes=[Collections.Generic.List[string]]::new();$sources=[Collections.Generic.List[object]]::new()
for($b=0;$b -lt 3;$b++){
 $dir=[IO.Path]::GetFullPath($BranchDirectories[$b]);if(-not $dir.StartsWith($build,[StringComparison]::OrdinalIgnoreCase)){throw 'Branch outside build'}
 $spec=Get-Content (Join-Path $dir 'runner-fixture.json') -Raw|ConvertFrom-Json
 $kernel=if($spec.Kernel){$spec.Kernel}else{3};if($kernel -ne @(3,7,11)[$b] -or $spec.Frames -ne $average.Frames -or $spec.Tiles -ne $average.Tiles){throw 'Branch shape mismatch'}
 foreach($record in $spec.Files){$file=Join-Path $dir $record.Name;if((Get-Item $file).Length -ne $record.Bytes -or (Get-FileHash $file).Hash -ne $record.SHA256){throw 'Branch fixture integrity'}}
 $input=Join-Path $dir 'activations.bin';$hashes.Add((Get-FileHash $input).Hash)
 $data=[IO.File]::ReadAllBytes((Join-Path $dir 'weights.bin'));if($data.Length -ne 98304*$kernel){throw 'Branch weight length'};[Buffer]::BlockCopy($data,0,$weights,$weightAt,$data.Length);$weightAt+=$data.Length
 $data=[IO.File]::ReadAllBytes((Join-Path $dir 'tables.bin'));if($data.Length -ne 49152){throw 'Branch parameter length'};[Buffer]::BlockCopy($data,0,$parameters,$b*49152,49152)
 $data=[IO.File]::ReadAllBytes((Join-Path $dir 'expected-coefficients.bin'));if($data.Length -ne 6144){throw 'Branch coefficient length'};[Buffer]::BlockCopy($data,0,$coefficients,$b*6144,6144)
 if((Get-FileHash (Join-Path $dir 'expected.bin')).Hash -ne (Get-FileHash (Join-Path $AverageDirectory "branch$b.bin")).Hash){throw 'Branch average input differs'}
 $sources.Add([ordered]@{Directory=$dir;ManifestSHA256=(Get-FileHash (Join-Path $dir 'runner-fixture.json')).Hash})
}
if(@($hashes|Select-Object -Unique).Count -ne 1){throw 'Three branch input tensors differ'}
$data=[IO.File]::ReadAllBytes((Join-Path $AverageDirectory 'parameters.bin'));if($data.Length -ne 16){throw 'Average parameters'};[Buffer]::BlockCopy($data,0,$parameters,147456,16)
$input=[IO.File]::ReadAllBytes((Join-Path $BranchDirectories[0] 'activations.bin'));$expected=[IO.File]::ReadAllBytes((Join-Path $AverageDirectory 'simulator-output.bin'))
if((Get-FileHash (Join-Path $AverageDirectory 'simulator-output.bin')).Hash -ne $average.ExpectedSHA256){throw 'Average simulator contract mismatch'}
[void][IO.Directory]::CreateDirectory($out)
foreach($p in @(@('activations.bin',$input),@('weights.bin',$weights),@('tables.bin',$parameters),@('expected.bin',$expected),@('expected-coefficients.bin',$coefficients))){[IO.File]::WriteAllBytes((Join-Path $out $p[0]),$p[1])}
$files=@(Get-ChildItem $out -File|ForEach-Object {[ordered]@{Name=$_.Name;Bytes=$_.Length;SHA256=(Get-FileHash $_.FullName).Hash}})
[ordered]@{Frames=$average.Frames;Tiles=$average.Tiles;Graph='Generator60x';Branches=$sources.ToArray();AverageManifestSHA256=(Get-FileHash (Join-Path $AverageDirectory 'fixture.json')).Hash;OutputScale=$average.OutputScale;Files=$files}|ConvertTo-Json -Depth 6|Set-Content (Join-Path $out 'runner-fixture.json') -Encoding utf8NoBOM
[pscustomobject]@{Graph='Generator60x';Frames=$average.Frames;Directory=$out}
