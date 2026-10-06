#requires -Version 7.4
param([Parameter(Mandatory)][string]$ConnectedDirectory,[Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$source=[IO.Path]::GetFullPath($ConnectedDirectory);$out=[IO.Path]::GetFullPath($OutputDirectory)
$build=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build'))+[IO.Path]::DirectorySeparatorChar
if(-not $out.StartsWith($build,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path $out)){throw 'Use a new directory in build/'}
$fixture=Get-Content (Join-Path $source 'connected-fixture.json') -Raw | ConvertFrom-Json
if($fixture.channels -ne 128 -or $fixture.frames -lt 2 -or $fixture.frames -gt 32768 -or $fixture.tiles -ne [math]::Ceiling($fixture.frames/32)){throw 'Invalid connected fixture shape'}
foreach($record in $fixture.files) {
 $path=[IO.Path]::GetFullPath((Join-Path $source $record.path))
 if(-not $path.StartsWith($source+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Get-Item $path).Length -ne $record.bytes -or (Get-FileHash $path).Hash -ne $record.sha256){throw 'Connected fixture integrity mismatch'}
}
$kernel=if ($fixture.stages[0].kernel) { [int]$fixture.stages[0].kernel } else { 3 }
if ($kernel -notin 3,7,11) {throw 'Unsupported generator kernel'}
$weightBytes=16384*$kernel
$bytes=[int]$fixture.tiles*8192;$weights=[byte[]]::new(6*$weightBytes);$parameters=[byte[]]::new(49152);$coefficients=[byte[]]::new(6144)
for($s=0;$s -lt 6;$s++) {
 $dir=Join-Path $source "stage$s"
 foreach($spec in @(@('weights.bin',$weightBytes,$weights,($s*$weightBytes)),@('adain-parameters.bin',2048,$parameters,($s*8192)),@('snake-parameters.bin',2048,$parameters,($s*8192+2048)),@('tables.bin',1024,$parameters,($s*8192+4096)),@('connected-coefficients.bin',1024,$coefficients,($s*1024)))) {
  $data=[IO.File]::ReadAllBytes((Join-Path $dir $spec[0]));if($data.Length -ne $spec[1]){throw 'Unexpected stage file length'}
  [Buffer]::BlockCopy($data,0,$spec[2],$spec[3],$data.Length)
 }
 if($s%2){$data=[IO.File]::ReadAllBytes((Join-Path $dir 'residual-parameters.bin'));if($data.Length -ne 12){throw 'Residual length'};[Buffer]::BlockCopy($data,0,$parameters,$s*8192+5120,12)}
}
$input=[IO.File]::ReadAllBytes((Join-Path $source 'input.bin'));$expected=[IO.File]::ReadAllBytes((Join-Path $source 'stage5/connected-residual.bin'))
if($input.Length -ne $bytes -or $expected.Length -ne $bytes){throw 'Connected output length'}
[void][IO.Directory]::CreateDirectory($out)
foreach($spec in @(@('activations.bin',$input),@('weights.bin',$weights),@('tables.bin',$parameters),@('expected.bin',$expected),@('expected-coefficients.bin',$coefficients))){[IO.File]::WriteAllBytes((Join-Path $out $spec[0]),$spec[1])}
$files=@(Get-ChildItem $out -File | ForEach-Object {[ordered]@{Name=$_.Name;Bytes=$_.Length;SHA256=(Get-FileHash $_.FullName).Hash}})
[ordered]@{Frames=$fixture.frames;Kernel=$kernel;Tiles=$fixture.tiles;SourceDirectory=$source;SourceManifestSHA256=(Get-FileHash (Join-Path $source 'connected-fixture.json')).Hash;Calibration=$fixture.calibration;Files=$files}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $out 'runner-fixture.json') -Encoding utf8NoBOM
[pscustomobject]@{Frames=$fixture.frames;Kernel=$kernel;Tiles=$fixture.tiles;Directory=$out}
