#requires -Version 7.4
<# .SYNOPSIS
Packs a connected resblocks.3 experiment from verified stock captures.
Uses stock ranges for calibration only. All live model math runs in emitted DSP code.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$CaptureDirectory,
 [Parameter(Mandatory)][string]$InitialStatisticsDirectory,
 [Parameter(Mandatory)][string]$OutputDirectory,
 [string]$EncodingFile)
$ErrorActionPreference='Stop'
$build=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build'))+[IO.Path]::DirectorySeparatorChar
$captureRoot=(Resolve-Path -LiteralPath $CaptureDirectory).Path
$statsRoot=(Resolve-Path -LiteralPath $InitialStatisticsDirectory).Path
$out=[IO.Path]::GetFullPath($OutputDirectory)
foreach ($path in $captureRoot,$statsRoot,$out) { if (-not $path.StartsWith($build,[StringComparison]::OrdinalIgnoreCase)) { throw 'Use project build/.' } }
if (Test-Path $out) { throw 'Choose a new fixture directory.' }
$captureFile=Join-Path $captureRoot 'capture.json'
$capture=Get-Content $captureFile -Raw | ConvertFrom-Json -AsHashtable
$stats=Get-Content (Join-Path $statsRoot 'fixture.json') -Raw | ConvertFrom-Json -AsHashtable
$encoding=$null
if ($EncodingFile) {
 $encoding=Get-Content -LiteralPath $EncodingFile -Raw | ConvertFrom-Json -AsHashtable
 if ($encoding.schema -ne 1 -or $encoding.sourceCommit -cne $capture.sourceCommit -or $encoding.scales.Count -ne 16) { throw 'Encoding contract mismatch.' }
 foreach ($v in $encoding.scales.Values) { if (-not [double]::IsFinite($v) -or $v -le 0 -or $v -gt 1000000) { throw 'Invalid frozen scale.' } }
 if ([double]$stats.inputScale -ne [double]$encoding.scales['stage0.input']) { throw 'Initial input does not use frozen scale.' }
 if (@($encoding.calibrationCaptures | Where-Object sha256 -CEQ (Get-FileHash $captureFile).Hash).Count) { throw 'Connected evaluation requires a separate holdout.' }
}
if ($capture.sourceCommit -cne 'dfb907a02bba8152ca444717ca5d78747ccb4bec' -or $capture.verifiedCheckpointTensors -ne 548 -or
 $stats.captureSha256 -cne (Get-FileHash $captureFile).Hash -or $stats.stage -ne 0 -or $stats.tiles -gt 1024 -or
 (Get-FileHash (Join-Path $statsRoot 'activations.bin')).Hash -cne $stats.activationSha256) { throw 'Capture/input identity mismatch.' }
function Read-Tensor([string]$Name,[int]$Count) {
 $item=$capture.tensors[$Name]; if (-not $item -or $item.bytes -ne 4L*$Count -or $item.file -notmatch '^[a-zA-Z0-9_.]+\.f32$') { throw 'Capture size contract mismatch.' }
 $path=Join-Path $captureRoot $item.file
 if ((Get-FileHash $path).Hash -cne $item.sha256 -or (Get-Item $path).Length -ne $item.bytes) { throw 'Capture tensor digest mismatch.' }
 $values=[float[]]::new($Count); $bytes=[IO.File]::ReadAllBytes($path)
 [Buffer]::BlockCopy($bytes,0,$values,0,$bytes.Length)
 foreach ($v in $values) { if (-not [float]::IsFinite($v)) { throw 'Nonfinite capture value.' } }
 return ,$values
}
function Get-RangeScale([string]$Name) {
 if ($encoding) { if (-not $encoding.scales.ContainsKey($Name)) { throw 'Missing frozen boundary.' }; return [double]$encoding.scales[$Name] }
 $values=Read-Tensor $Name (128*$stats.frames); $max=0.0
 foreach ($v in $values) { $max=[math]::Max($max,[math]::Abs([double]$v)) }
 if ($max -le 0) { throw 'Nonpositive calibration range.' }
 return $max/127
}
$style=Read-Tensor 'style' 128
[void][IO.Directory]::CreateDirectory($out)
Copy-Item (Join-Path $statsRoot 'activations.bin') (Join-Path $out 'input.bin')
$stages=[Collections.Generic.List[hashtable]]::new(); $inputScale=[double]$stats.inputScale; $skipScale=$inputScale
for ($stage=0;$stage -lt 6;$stage++) {
 $dir=Join-Path $out "stage$stage"
 $extra=@{}
 if ($encoding) { $extra=@{InputScale=(Get-RangeScale "stage$stage.snake");OutputScale=(Get-RangeScale "stage$stage.conv")} }
 $convFixture=& (Join-Path $PSScriptRoot 'New-KokoroHmxCaptureFixture.ps1') -CaptureDirectory $captureRoot -Stage $stage -StartFrame 0 -Tiles 1 -OutputDirectory $dir @extra
 $conv=Get-Content (Join-Path $dir 'fixture.json') -Raw | ConvertFrom-Json -AsHashtable
 $prefix="stage$stage.adain."
 $fcw=Read-Tensor ($prefix+'fc.weight') (256*128); $fcb=Read-Tensor ($prefix+'fc.bias') 256
 $nw=Read-Tensor ($prefix+'norm.weight') 128; $nb=Read-Tensor ($prefix+'norm.bias') 128
 $h=[double[]]::new(256)
 for ($i=0;$i -lt 256;$i++) { $h[$i]=$fcb[$i]; for ($j=0;$j -lt 128;$j++) { $h[$i]+=[double]$fcw[$i*128+$j]*$style[$j] } }
 $epsD=[uint64][math]::Round(1e-5*$stats.frames*$stats.frames/($inputScale*$inputScale),[MidpointRounding]::ToEven)
 if ($epsD -lt 1) { throw 'Insufficient integer epsilon precision.' }
 $norm=[byte[]]::new(2048)
 $snake=[byte[]]::new(2048); $alpha=Read-Tensor "stage$stage.alpha" 128
 $req=[int][math]::Round(65536/(256*$conv.inputScale),[MidpointRounding]::ToEven)
 if ($req -lt 1 -or $req -gt 65535) { throw 'Snake requantization outside implemented precision.' }
 for ($c=0;$c -lt 128;$c++) {
  $aq=[long][math]::Round((1+$h[$c])*$nw[$c]*65536,[MidpointRounding]::ToEven)
  $bq=[long][math]::Round(((1+$h[$c])*$nb[$c]+$h[128+$c])*65536,[MidpointRounding]::ToEven)
  if ($aq -le [int]::MinValue -or $aq -gt [int]::MaxValue -or $bq -lt [int]::MinValue -or $bq -gt [int]::MaxValue) { throw 'Style affine overflow.' }
  [BitConverter]::GetBytes([int]$aq).CopyTo($norm,16*$c); [BitConverter]::GetBytes([int]$bq).CopyTo($norm,16*$c+4)
  [BitConverter]::GetBytes($epsD).CopyTo($norm,16*$c+8)
  if ($alpha[$c] -eq 0) { throw 'Stock Snake alpha is zero.' }
  $phase=[long][math]::Round($alpha[$c]/[math]::PI*65536,[MidpointRounding]::ToEven)
  $inv=[long][math]::Round(256/$alpha[$c],[MidpointRounding]::ToEven)
  if ($phase -eq 0 -or $phase -lt [int]::MinValue -or $phase -gt [int]::MaxValue -or $inv -eq 0 -or [math]::Abs($inv) -gt 65535) { throw 'Snake parameter precision bounds.' }
  [BitConverter]::GetBytes([int]$phase).CopyTo($snake,4*$c)
  [BitConverter]::GetBytes([int]$inv).CopyTo($snake,512+4*$c)
  [BitConverter]::GetBytes($req).CopyTo($snake,1024+4*$c)
 }
 for ($i=0;$i -lt 256;$i++) {
  $sn=[math]::Sin([math]::PI*$i/256); $q=[uint16][math]::Round($sn*$sn*32767,[MidpointRounding]::ToEven)
  $chunk=[int][math]::Floor($i/64); $at=$i%64; $index=2*($at%32)+[int][math]::Floor($at/32)
  [BitConverter]::GetBytes($q).CopyTo($snake,1536+128*$chunk+2*$index)
 }
 [IO.File]::WriteAllBytes((Join-Path $dir 'adain-parameters.bin'),$norm)
 [IO.File]::WriteAllBytes((Join-Path $dir 'snake-parameters.bin'),$snake)
 $record=@{stage=$stage;inputScale=$inputScale;snakeScale=$conv.inputScale;convScale=$conv.outputScale;dilation=$conv.dilation;kernel=$conv.kernel}
 $inputScale=[double]$conv.outputScale
 if ($stage%2 -eq 1) {
  $next=if ($stage -lt 5) { "stage$($stage+1).input" } else { 'output' }
  $outScale=Get-RangeScale $next
  $rx=[long][math]::Round($skipScale/$outScale*65536,[MidpointRounding]::ToEven)
  $ry=[long][math]::Round($inputScale/$outScale*65536,[MidpointRounding]::ToEven)
  $bias=128L*65536-128L*($rx+$ry)+32768
  if ($rx -lt 1 -or $ry -lt 1 -or $rx+$ry -gt 8000000 -or $bias -lt [int]::MinValue -or $bias+255*($rx+$ry) -gt [int]::MaxValue) { throw 'Residual int32 bounds.' }
  $res=[byte[]]::new(12)
  [BitConverter]::GetBytes([int]$rx).CopyTo($res,0); [BitConverter]::GetBytes([int]$ry).CopyTo($res,4); [BitConverter]::GetBytes([int]$bias).CopyTo($res,8)
  [IO.File]::WriteAllBytes((Join-Path $dir 'residual-parameters.bin'),$res)
  $record['residualScale']=$outScale; $inputScale=$outScale; $skipScale=$outScale
 }
 $stages.Add($record)
 Write-Host "Packed connected stage $stage; dilation $($conv.dilation)"
}
 $files=@(Get-ChildItem -LiteralPath $out -Recurse -File | Where-Object { $_.Name -in 'input.bin','weights.bin','tables.bin','adain-parameters.bin','snake-parameters.bin','residual-parameters.bin' } |
 ForEach-Object { @{path=[IO.Path]::GetRelativePath($out,$_.FullName);bytes=$_.Length;sha256=(Get-FileHash $_.FullName).Hash} })
@{frames=$stats.frames;tiles=$stats.tiles;channels=128;stages=@($stages.ToArray());files=$files;
 sourceCommit=$capture.sourceCommit;captureDirectory=$captureRoot;captureSha256=$stats.captureSha256;
 calibration=$(if ($encoding) { $encoding.method } else { 'Stock captured ranges, experiment only' });
 encodingSha256=$(if ($encoding) { (Get-FileHash -LiteralPath $EncodingFile).Hash } else { $null });
 epsilon=1e-5;initialInputScale=$stats.inputScale} |
 ConvertTo-Json -Depth 8 | Set-Content (Join-Path $out 'connected-fixture.json') -Encoding utf8NoBOM
[pscustomobject]@{Frames=$stats.frames;Stages=6;Residuals=3;Directory=$out}
