#requires -Version 7.4
<# .SYNOPSIS
Packs offline style affine and a complete group for integer AdaIN validation.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$CaptureDirectory,
 [Parameter(Mandatory)][string]$StatisticsDirectory,
 [Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$build=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build'))+[IO.Path]::DirectorySeparatorChar
$captureRoot=(Resolve-Path -LiteralPath $CaptureDirectory).Path
$statsRoot=(Resolve-Path -LiteralPath $StatisticsDirectory).Path
$out=[IO.Path]::GetFullPath($OutputDirectory)
foreach ($path in $captureRoot,$statsRoot,$out) {
 if (-not $path.StartsWith($build,[StringComparison]::OrdinalIgnoreCase)) { throw 'Use this project build directory.' }
}
if (Test-Path -LiteralPath $out) { throw 'Choose a new fixture directory.' }
$captureFile=Join-Path $captureRoot 'capture.json'
$capture=Get-Content -LiteralPath $captureFile -Raw | ConvertFrom-Json -AsHashtable
$stats=Get-Content -LiteralPath (Join-Path $statsRoot 'fixture.json') -Raw | ConvertFrom-Json -AsHashtable
if ($capture.sourceCommit -cne 'dfb907a02bba8152ca444717ca5d78747ccb4bec' -or
 $capture.verifiedCheckpointTensors -ne 548 -or $stats.captureSha256 -cne (Get-FileHash $captureFile).Hash -or
 $stats.channels -notin 128,256 -or $stats.frames -lt 2 -or $stats.frames -gt 32768 -or $stats.stage -notin 0..5) { throw 'Pinned capture/statistics contract mismatch.' }
foreach ($pair in @(@('activations.bin','activationSha256'),@('expected.bin','expectedSha256'))) {
 if ((Get-FileHash -LiteralPath (Join-Path $statsRoot $pair[0])).Hash -cne $stats[$pair[1]]) { throw 'Statistics fixture integrity mismatch.' }
}
function Read-CapturedFloats([string]$Name,[int]$Count) {
 $tensor=$capture.tensors[$Name]
 if (-not $tensor -or $tensor.file -notmatch '^[a-zA-Z0-9_.]+\.f32$' -or $tensor.bytes -ne 4L*$Count) { throw 'Captured tensor size mismatch.' }
 $path=Join-Path $captureRoot $tensor.file
 if ((Get-FileHash -LiteralPath $path).Hash -cne $tensor.sha256 -or (Get-Item $path).Length -ne $tensor.bytes) { throw 'Captured tensor digest mismatch.' }
 $bytes=[IO.File]::ReadAllBytes($path); $values=[float[]]::new($Count)
 [Buffer]::BlockCopy($bytes,0,$values,0,$bytes.Length)
 foreach ($value in $values) { if (-not [float]::IsFinite($value)) { throw 'Nonfinite checkpoint/style value.' } }
 return ,$values
}
$channels=[int]$stats.channels; $stage=[int]$stats.stage; $prefix="stage$stage.adain."
$style=Read-CapturedFloats 'style' 128
# The decoder passes the last 128 style features to the generator's AdaIN FC.
$fcw=Read-CapturedFloats ($prefix+'fc.weight') (2*$channels*128)
$fcb=Read-CapturedFloats ($prefix+'fc.bias') (2*$channels)
$nw=Read-CapturedFloats ($prefix+'norm.weight') $channels
$nb=Read-CapturedFloats ($prefix+'norm.bias') $channels
$h=[double[]]::new(2*$channels)
for ($i=0;$i -lt 2*$channels;$i++) {
 $h[$i]=$fcb[$i]
 for ($j=0;$j -lt 128;$j++) { $h[$i]+=[double]$fcw[$i*128+$j]*$style[$j] }
}
$epsilon=1.0e-5 # Stock InstanceNorm1d default; checked by reference verifier.
$epsD=[uint64][math]::Round($epsilon*$stats.frames*$stats.frames/($stats.inputScale*$stats.inputScale),[MidpointRounding]::ToEven)
if ($epsD -lt 1) { throw 'Integer epsilon resolution requires a higher precision variance representation.' }
$parameters=[byte[]]::new($channels*16)
for ($c=0;$c -lt $channels;$c++) {
 $a=(1+$h[$c])*$nw[$c]; $b=(1+$h[$c])*$nb[$c]+$h[$channels+$c]
 $aq=[long][math]::Round($a*65536,[MidpointRounding]::ToEven)
 $bq=[long][math]::Round($b*65536,[MidpointRounding]::ToEven)
 if ($aq -le [int]::MinValue -or $aq -gt [int]::MaxValue -or $bq -lt [int]::MinValue -or $bq -gt [int]::MaxValue) { throw 'Q16 style affine outside int32.' }
 [BitConverter]::GetBytes([int]$aq).CopyTo($parameters,16*$c)
 [BitConverter]::GetBytes([int]$bq).CopyTo($parameters,16*$c+4)
 [BitConverter]::GetBytes($epsD).CopyTo($parameters,16*$c+8)
}
[void][IO.Directory]::CreateDirectory($out)
Copy-Item -LiteralPath (Join-Path $statsRoot 'activations.bin') -Destination (Join-Path $out 'activations.bin')
Copy-Item -LiteralPath (Join-Path $statsRoot 'expected.bin') -Destination (Join-Path $out 'moments.bin')
[IO.File]::WriteAllBytes((Join-Path $out 'parameters.bin'),$parameters)
$stats['epsilon']=$epsilon; $stats['epsilonVarianceNumerator']=$epsD
$stats['parameterSha256']=(Get-FileHash (Join-Path $out 'parameters.bin')).Hash
$stats['outputFractionBits']=8; $stats['captureDirectory']=$captureRoot
$stats | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $out 'fixture.json') -Encoding utf8NoBOM
[pscustomobject]@{Stage=$stage;Frames=$stats.frames;OutputDirectory=$out;EpsilonD=$epsD}
