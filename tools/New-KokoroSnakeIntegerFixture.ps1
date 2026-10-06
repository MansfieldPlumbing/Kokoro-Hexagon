#requires -Version 7.4
<# .SYNOPSIS
Packs a shared periodic integer Snake table and checkpoint per-channel alpha.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$AdaInDirectory,
 [Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$build=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build'))+[IO.Path]::DirectorySeparatorChar
$adain=(Resolve-Path -LiteralPath $AdaInDirectory).Path
$out=[IO.Path]::GetFullPath($OutputDirectory)
if (-not $adain.StartsWith($build,[StringComparison]::OrdinalIgnoreCase) -or
 -not $out.StartsWith($build,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path $out)) { throw 'Use project build/ and a new output directory.' }
$spec=Get-Content -LiteralPath (Join-Path $adain 'fixture.json') -Raw | ConvertFrom-Json -AsHashtable
$result=Get-Content -LiteralPath (Join-Path $adain 'comparison.json') -Raw | ConvertFrom-Json -AsHashtable
$channels=[int]$spec.channels;if($channels -notin 128,256){throw 'Unsupported Snake channel count'};$inputFile=Join-Path $adain 'simulator-affine.bin'
if ($result.coefficientMismatches -ne 0 -or $result.affineMismatches -ne 0 -or
 (Get-FileHash $inputFile).Hash -cne $result.outputSha256 -or (Get-Item $inputFile).Length -ne $spec.tiles*$channels*64) { throw 'Verified emitted integer AdaIN output required.' }
$captureRoot=[string]$spec.captureDirectory
$captureFile=Join-Path $captureRoot 'capture.json'
if (-not $captureRoot.StartsWith($build,[StringComparison]::OrdinalIgnoreCase) -or
 (Get-FileHash $captureFile).Hash -cne $spec.captureSha256) { throw 'Capture integrity mismatch.' }
$capture=Get-Content -LiteralPath $captureFile -Raw | ConvertFrom-Json -AsHashtable
function Read-Capture([string]$Name,[int]$Count) {
 $item=$capture.tensors[$Name]
 if ($item.file -notmatch '^[a-zA-Z0-9_.]+\.f32$' -or $item.bytes -ne 4L*$Count) { throw 'Tensor contract mismatch.' }
 $path=Join-Path $captureRoot $item.file
 if ((Get-FileHash $path).Hash -cne $item.sha256 -or (Get-Item $path).Length -ne $item.bytes) { throw 'Tensor integrity mismatch.' }
 $bytes=[IO.File]::ReadAllBytes($path); $values=[float[]]::new($Count)
 [Buffer]::BlockCopy($bytes,0,$values,0,$bytes.Length)
 foreach ($v in $values) { if (-not [float]::IsFinite($v)) { throw 'Nonfinite captured value.' } }
 return ,$values
}
$alpha=Read-Capture ("stage$($spec.stage).alpha") $channels
$snake=Read-Capture ("stage$($spec.stage).snake") ($channels*$spec.frames)
$maximum=0.0; foreach ($v in $snake) { $maximum=[math]::Max($maximum,[math]::Abs([double]$v)) }
if ($maximum -le 0) { throw 'Invalid calibration range.' }
$scale=$maximum/127
$requant=[int][math]::Round(65536/(256*$scale),[MidpointRounding]::ToEven)
if ($requant -lt 1 -or $requant -gt 65535) { throw 'Snake output scale needs a wider multiplier implementation.' }
$params=[byte[]]::new($channels*12+512)
for ($c=0;$c -lt $channels;$c++) {
 if ($alpha[$c] -eq 0) { throw 'Stock Snake alpha is zero.' }
 $phase=[long][math]::Round($alpha[$c]/[math]::PI*65536,[MidpointRounding]::ToEven)
 $inverse=[long][math]::Round(256/$alpha[$c],[MidpointRounding]::ToEven)
 if ($phase -eq 0 -or $phase -lt [int]::MinValue -or $phase -gt [int]::MaxValue -or $inverse -eq 0 -or [math]::Abs($inverse) -gt 65535) { throw 'Snake alpha needs a wider precision path.' }
 [BitConverter]::GetBytes([int]$phase).CopyTo($params,4*$c)
 [BitConverter]::GetBytes([int]$inverse).CopyTo($params,$channels*4+4*$c)
 [BitConverter]::GetBytes($requant).CopyTo($params,$channels*8+4*$c)
}
for ($i=0;$i -lt 256;$i++) {
 $value=[math]::Sin([math]::PI*$i/256)
 $q=[uint16][math]::Round($value*$value*32767,[MidpointRounding]::ToEven)
 $chunk=[int][math]::Floor($i/64); $at=$i%64
 $halfword=2*($at%32)+[int][math]::Floor($at/32)
 [BitConverter]::GetBytes($q).CopyTo($params,$channels*12+128*$chunk+2*$halfword)
}
[void][IO.Directory]::CreateDirectory($out)
Copy-Item -LiteralPath $inputFile -Destination (Join-Path $out 'input.bin')
[IO.File]::WriteAllBytes((Join-Path $out 'parameters.bin'),$params)
@{frames=$spec.frames;tiles=$spec.tiles;channels=$channels;stage=$spec.stage;inputFractionBits=8;
 outputScale=$scale;requantQ16=$requant;inputSha256=$result.outputSha256;
 parameterSha256=(Get-FileHash (Join-Path $out 'parameters.bin')).Hash;
 captureDirectory=$captureRoot;captureSha256=$spec.captureSha256;
 tablePoints=256;tableFractionBits=15;phaseFractionBits=16;inverseAlphaFractionBits=8;
 calibration='Stock captured Snake range; experiment only, not production calibration.'} |
 ConvertTo-Json | Set-Content -LiteralPath (Join-Path $out 'fixture.json') -Encoding utf8NoBOM
[pscustomobject]@{Stage=$spec.stage;Frames=$spec.frames;Scale=$scale;OutputDirectory=$out}
