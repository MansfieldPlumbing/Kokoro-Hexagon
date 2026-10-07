#requires -Version 7.4
<#
.SYNOPSIS
Checks a generator tail output buffer (simulator or phone) and writes WAV files.

.DESCRIPTION
Decodes the coarse and fine conv_post code tensors the job wrote by DMA, recomputes the
integer iSTFT from the fixture's own parameter bytes (tables.bin), and requires the job's
PCM to equal it bit for bit. Reports SNR of the PCM against the stock capture's audio and
writes 16-bit mono 24 kHz WAV files of both into the output's directory.
#>
param(
    [Parameter(Mandatory)][string] $FixtureDirectory,
    [Parameter(Mandatory)][string] $OutputPath,
    [Parameter(Mandatory)][string] $LayoutPath
)
$ErrorActionPreference = 'Stop'
$fixtureRoot = [IO.Path]::GetFullPath($FixtureDirectory)
$fixture = Get-Content (Join-Path $fixtureRoot 'fixture.json') -Raw | ConvertFrom-Json
$layout = Get-Content $LayoutPath -Raw | ConvertFrom-Json
$buffer = [IO.File]::ReadAllBytes($OutputPath)
$parameters = [IO.File]::ReadAllBytes((Join-Path $fixtureRoot 'tables.bin'))
$frames = [int]$fixture.Frames; $samples = [int]$fixture.Samples; $tensorBytes = [int]$layout.InputBytes
if ($buffer.Length -ne [int]$layout.OutputBytes) { throw 'Output length differs from the layout' }
$word = { param([byte[]]$b, [int]$at) [BitConverter]::ToInt32($b, $at) }
$codesOffset = & $word $buffer 40
if ((& $word $buffer 44) -ne 1 -or $codesOffset -lt [int]$layout.CodesFloor -or $codesOffset + 2 * $tensorBytes -gt $buffer.Length) { throw 'Job did not complete or codes offset is invalid' }

# Native crouton byte of (frame, channel < 32): tile*8192 + 2*IDX(row, c) + 1.
$decode = { param([int]$base)
    $codes = [byte[]]::new(22 * $frames)
    for ($f = 0; $f -lt $frames; $f++) { $row = $f % 32; $tileBase = $base + [math]::Floor($f / 32) * 8192
        for ($c = 0; $c -lt 22; $c++) { $codes[22 * $f + $c] = $buffer[$tileBase + 2 * (64 * [math]::Floor($row / 2) + 2 * $c + $row % 2) + 1] } }
    , $codes }
$coarse = & $decode $codesOffset; $fine = & $decode ($codesOffset + $tensorBytes)

$p = $fixture.ParameterLayout
$table = { param([int]$block, [int]$which, [int]$k, [int]$q) [long](& $word $parameters ($block + 11264 * $which + 4 * (256 * $k + $q))) }
$acc = [int[]]::new(20 + 5 * ($frames - 1)); $re = [long[]]::new(11); $im = [long[]]::new(11)
$coefA = [long[]]::new(220); $coefB = [long[]]::new(220)
for ($i = 0; $i -lt 220; $i++) { $coefA[$i] = & $word $parameters ($p.CoefA + 4 * $i); $coefB[$i] = & $word $parameters ($p.CoefB + 4 * $i) }
for ($f = 0; $f -lt $frames; $f++) {
    for ($k = 0; $k -lt 11; $k++) {
        $qm = $fine[22 * $f + $k]; $bm = $p.PassFine; if ($qm -eq 0 -or $qm -eq 255) { $qm = $coarse[22 * $f + $k]; $bm = $p.PassCoarse }
        $qp = $fine[22 * $f + 11 + $k]; $bp = $p.PassFine; if ($qp -eq 0 -or $qp -eq 255) { $qp = $coarse[22 * $f + 11 + $k]; $bp = $p.PassCoarse }
        $e = & $table $bm 0 $k $qm
        $re[$k] = ($e * (& $table $bp 1 $k $qp) + 16384) -shr 15; $im[$k] = ($e * (& $table $bp 2 $k $qp) + 16384) -shr 15
    }
    for ($n = 0; $n -lt 20; $n++) {
        $sum = 2097152L; for ($k = 0; $k -lt 11; $k++) { $sum += $coefA[11 * $n + $k] * $re[$k] + $coefB[11 * $n + $k] * $im[$k] }
        $acc[5 * $f + $n] += [int]($sum -shr 22)
    }
}
$reference = [int16[]]::new($samples)
for ($j = 0; $j -lt $samples; $j++) {
    $v = [long]$acc[$j + 10]
    $edge = if ($j -lt 5) { $j } elseif ($j -ge $samples - 5) { $j - $samples + 10 } else { -1 }
    if ($edge -ge 0) { $v = ($v * (& $word $parameters ($p.EdgeGain + 4 * $edge)) + 8192) -shr 14 }
    $reference[$j] = [int16][math]::Clamp(($v + 256) -shr 9, -32768L, 32767L)
}
$pcm = [int16[]]::new($samples); [Buffer]::BlockCopy($buffer, [int]$layout.PcmOffset, $pcm, 0, 2 * $samples)
$mismatch = 0; for ($j = 0; $j -lt $samples; $j++) { if ($pcm[$j] -ne $reference[$j]) { $mismatch++ } }
if ($mismatch -ne 0) { throw "Integer tail PCM mismatch: $mismatch of $samples samples" }

$stockBytes = [IO.File]::ReadAllBytes($fixture.StockAudio.File)
if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stockBytes)) -ne $fixture.StockAudio.SHA256) { throw 'Stock audio integrity' }
$stock = [float[]]::new($samples); [Buffer]::BlockCopy($stockBytes, 0, $stock, 0, 4 * $samples)
$signal = 0.0; $noise = 0.0; $peak = 0; $clipped = 0
for ($j = 0; $j -lt $samples; $j++) { $r = [double]$stock[$j] * 32768; $d = $pcm[$j] - $r; $signal += $r * $r; $noise += $d * $d
    $peak = [math]::Max($peak, [math]::Abs([int]$pcm[$j])); if ($pcm[$j] -eq 32767 -or $pcm[$j] -eq -32768) { $clipped++ } }

$writeWav = { param([string]$Path, [int16[]]$Data)
    $stream = [IO.MemoryStream]::new(); $w = [IO.BinaryWriter]::new($stream)
    $w.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $w.Write([int](36 + 2 * $Data.Length)); $w.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
    $w.Write([int]16); $w.Write([int16]1); $w.Write([int16]1); $w.Write([int]24000); $w.Write([int]48000); $w.Write([int16]2); $w.Write([int16]16)
    $w.Write([Text.Encoding]::ASCII.GetBytes('data')); $w.Write([int](2 * $Data.Length)); foreach ($x in $Data) { $w.Write($x) }
    $w.Flush(); [IO.File]::WriteAllBytes($Path, $stream.ToArray()) }
$dir = Split-Path ([IO.Path]::GetFullPath($OutputPath)) -Parent; $name = [IO.Path]::GetFileNameWithoutExtension($OutputPath)
$stockPcm = [int16[]]::new($samples); for ($j = 0; $j -lt $samples; $j++) { $stockPcm[$j] = [int16][math]::Clamp([math]::Round([double]$stock[$j] * 32768), -32768, 32767) }
& $writeWav (Join-Path $dir "$name.wav") $pcm
& $writeWav (Join-Path $dir 'stock-reference.wav') $stockPcm
$pcmBytes = [byte[]]::new(2 * $samples); [Buffer]::BlockCopy($pcm, 0, $pcmBytes, 0, $pcmBytes.Length)
[pscustomobject]@{
    Samples = $samples; PcmMismatches = $mismatch; PcmSHA256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($pcmBytes))
    SnrDb = [math]::Round(10 * [math]::Log10($signal / [math]::Max($noise, 1e-30)), 2); Peak = $peak; Clipped = $clipped
    RegionMs = [math]::Round(((& $word $buffer 8) - (& $word $buffer 0)) / 19200.0, 3); Wav = (Join-Path $dir "$name.wav")
}
