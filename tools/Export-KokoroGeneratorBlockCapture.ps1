#requires -Version 7.4
# Relabel verified original generator tensors for the existing packing tools.
# No model equations are executed or reimplemented here.
param([Parameter(Mandatory)][string]$GeneratorCaptureDirectory,[ValidateRange(0,5)][int]$Block=4,[Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$build=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build'))+[IO.Path]::DirectorySeparatorChar
$source=[IO.Path]::GetFullPath($GeneratorCaptureDirectory);$out=[IO.Path]::GetFullPath($OutputDirectory)
if(-not $source.StartsWith($build,[StringComparison]::OrdinalIgnoreCase) -or -not $out.StartsWith($build,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path $out)){throw 'Use a verified generator capture and new output in build/'}
$capture=Get-Content (Join-Path $source 'capture.json') -Raw|ConvertFrom-Json -AsHashtable
if($capture.sourceCommit -cne 'dfb907a02bba8152ca444717ca5d78747ccb4bec' -or $capture.verifiedCheckpointTensors -ne 548 -or $capture.block -cne 'decoder.generator'){throw 'Pinned complete generator capture required'}
$prefix="generator.resblocks.$Block";$map=[ordered]@{input="$prefix.input.0";style="$prefix.input.1";output="$prefix.output"}
for($s=0;$s -lt 6;$s++){
 $branch=1+$s%2;$i=[int][math]::Floor($s/2);$map["stage$s.input"]="$prefix.adain$branch.$i.input.0";$map["stage$s.adain"]="$prefix.adain$branch.$i.output"
 $map["stage$s.snake"]="$prefix.convs$branch.$i.input.0";$map["stage$s.conv"]="$prefix.convs$branch.$i.output"
 foreach($name in 'weight','bias'){$map["stage$s.$name"]="$prefix.convs$branch.$i.$name"}
 foreach($name in 'fc.weight','fc.bias','norm.weight','norm.bias'){$map["stage$s.adain.$name"]="$prefix.adain$branch.$i.$name"}
 $map["stage$s.alpha"]="$prefix.alpha$branch.$i"
}
[void][IO.Directory]::CreateDirectory($out);$tensors=@{}
foreach($p in $map.GetEnumerator()){
 $entry=$capture.tensors[$p.Value];if(-not $entry -or $entry.file -notmatch '^[a-zA-Z0-9_.]+\.f32$'){throw "Missing captured boundary $($p.Value)"}
 $file=Join-Path $source $entry.file;if((Get-Item $file).Length -ne $entry.bytes -or (Get-FileHash $file).Hash -cne $entry.sha256){throw 'Captured tensor integrity mismatch'}
 $target=Join-Path $out ($p.Key+'.f32');Copy-Item -LiteralPath $file -Destination $target
 if((Get-FileHash $target).Hash -cne $entry.sha256){throw 'Relabeled capture digest mismatch'}
 $item=$entry.Clone();$item.file=$p.Key+'.f32';$tensors[$p.Key]=$item
}
$capture.tensors=$tensors;$capture.block="decoder.generator.resblocks.$Block";$capture.generatorManifestSHA256=(Get-FileHash (Join-Path $source 'capture.json')).Hash
$capture.relabelToolSHA256=(Get-FileHash $PSCommandPath).Hash
$capture|ConvertTo-Json -Depth 8|Set-Content (Join-Path $out 'capture.json') -Encoding utf8NoBOM
[pscustomobject]@{Block=$Block;Tensors=$tensors.Count;Frames=$tensors.input.shape[2];Kernel=$tensors['stage0.weight'].shape[2];Directory=$out}
