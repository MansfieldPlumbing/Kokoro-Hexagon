#Requires -Version 7.4
<# .SYNOPSIS
Packs a complete stock-captured AdaIN input group and exact integer moment checks.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$CaptureDirectory,
    [ValidateRange(0,5)][int]$Stage=0,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateRange(0,1000000)][double]$InputScale=0)
$ErrorActionPreference='Stop'
$buildRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build'))+[IO.Path]::DirectorySeparatorChar
$captureRoot=(Resolve-Path -LiteralPath $CaptureDirectory).Path
$out=[IO.Path]::GetFullPath($OutputDirectory)
if (-not $captureRoot.StartsWith($buildRoot,[StringComparison]::OrdinalIgnoreCase) -or
    -not $out.StartsWith($buildRoot,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)) { throw 'Use project build/ and a new statistics fixture directory.' }
$capturePath=Join-Path $captureRoot 'capture.json'
$capture=Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -AsHashtable
if ($capture.sourceCommit -cne 'dfb907a02bba8152ca444717ca5d78747ccb4bec' -or $capture.verifiedCheckpointTensors -le 0) { throw 'Verified stock capture required.' }
$tensor=$capture.tensors["stage$Stage.input"]
if ($tensor.file -notmatch '^[a-zA-Z0-9_.]+\.f32$' -or $tensor.shape.Count -ne 3 -or $tensor.shape[0] -ne 1 -or $tensor.shape[1] -notin 128,256) { throw 'Expected a 128- or 256-channel stock AdaIN group.' }
$channels=[int]$tensor.shape[1];$blocks=$channels/32; $frames=[int]$tensor.shape[2]
if ($frames -lt 2 -or $frames -gt 32768 -or $tensor.bytes -ne 4L*$channels*$frames) { throw 'Statistics tensor length is out of bounds.' }
$path=Join-Path $captureRoot $tensor.file
if ((Get-Item -LiteralPath $path).Length -ne $tensor.bytes -or (Get-FileHash -LiteralPath $path).Hash -cne $tensor.sha256) { throw 'Stock AdaIN input integrity mismatch.' }
$bytes=[IO.File]::ReadAllBytes($path); $values=[float[]]::new($channels*$frames)
[Buffer]::BlockCopy($bytes,0,$values,0,$bytes.Length)
$maximum=0.0
foreach ($value in $values) {
    if (-not [float]::IsFinite($value)) { throw 'Nonfinite captured activation.' }
    $maximum=[math]::Max($maximum,[math]::Abs([double]$value))
}
if ($maximum -eq 0) { throw 'Zero-range input needs explicit scale handling.' }
$scale=$maximum/127; $tiles=[int][math]::Ceiling($frames/32)
if ($InputScale -gt 0) { $scale=$InputScale }
# Padding is u8 ZERO for reduction, not the convolution's zero point 128.
$act=[byte[]]::new($tiles*$blocks*2048)
$sum=[uint32[]]::new($channels); $square=[uint32[]]::new($channels)
for ($c=0; $c -lt $channels; $c++) { for ($t=0; $t -lt $frames; $t++) {
    $q=[int][math]::Round($values[$c*$frames+$t]/$scale,[MidpointRounding]::ToEven)+128
    $q=[math]::Clamp($q,1,255)
    $sum[$c]+=[uint32]$q; $square[$c]+=[uint32]($q*$q)
    $idx=64*[int][math]::Floor(($t%32)/2)+2*($c%32)+($t%2)
    $act[([int][math]::Floor($t/32)*$blocks+[int][math]::Floor($c/32))*2048+2*$idx+1]=[byte]$q
} }
$expected=[byte[]]::new($channels*8)
for ($c=0; $c -lt $channels; $c++) {
    $base=[int][math]::Floor($c/32)*256+4*($c%32)
    [BitConverter]::GetBytes($sum[$c]).CopyTo($expected,$base)
    [BitConverter]::GetBytes($square[$c]).CopyTo($expected,$base+128)
}
[void][IO.Directory]::CreateDirectory($out)
[IO.File]::WriteAllBytes((Join-Path $out 'activations.bin'),$act)
[IO.File]::WriteAllBytes((Join-Path $out 'expected.bin'),$expected)
@{ frames=$frames; tiles=$tiles; channels=$channels; inputScale=$scale; stage=$Stage; paddingU8=0;
    captureSha256=(Get-FileHash -LiteralPath $capturePath).Hash;
    activationSha256=(Get-FileHash -LiteralPath (Join-Path $out 'activations.bin')).Hash;
    expectedSha256=(Get-FileHash -LiteralPath (Join-Path $out 'expected.bin')).Hash } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $out 'fixture.json') -Encoding utf8NoBOM
[pscustomobject]@{ Frames=$frames; Tiles=$tiles; Directory=$out; MomentValues=(2*$channels) }
