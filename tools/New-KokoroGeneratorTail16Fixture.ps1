#requires -Version 7.4
<# .SYNOPSIS
Packs the 16-bit generator tail (LeakyReLU, conv_post, exp/sin, iSTFT) for Kokoro.GeneratorTail16Run.ps1.
.DESCRIPTION
Stock Kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec istftnet.py Generator.forward (leaky_relu 0.01, conv_post,
exp of channels 0..10, sin of 11..21) and TorchSTFT.inverse (torch.istft n_fft 20, hop 5, periodic Hann 20,
center: irfft with 1/N, window, overlap-add, division by the overlap-added squared window, 10 samples trimmed at
each end; PyTorch v2.14.0 2b3ec34829036a65cd9d1398ea72a0167dc37470 aten/src/ATen/native/SpectralOps.cpp istft).
Build-time arithmetic only. Integer contract:
  input      the 60x stage's final tensor: biased u16 croutons, per-channel scale sR (stage fixture.json).
  leaky      on the integers (Kokoro.LeakyRelu16.ps1); sR folds into conv_post's weights: W'[o][i] = W[o][i] sR_i.
  conv_post  three-group HMX conv (Kokoro.HmxConvPlanes.ps1, 128 -> 64, K 7), W8x2 per output channel, outputs
             placed so magnitude bin k is channels k (fine) and 11 + k (coarse) and phase bin k channel 32 + k;
             output units 2^(L+8) sW.
  spectrum   Kokoro.TailSpectrum16.ps1: Re, Im = exp(z) (cos, sin)(sin(z')) / sS, one scale sS.
  iSTFT      one HMX conv 64 -> 64 (outputs 0..4 used), K 7 with taps at frame shifts -1..2: output frame m,
             channel r is PCM sample 5m + r (= stock overlap-add position 5m + r + 10), in units 2^-15
             (window units 2^(L+8) sW_r = 2^-15 exactly). Weights A[n][k] sS, B[n][k] sS for n = r + 5j,
             j = 2 - shift, with A = w[n] c_k cos(2 pi k n / 20) / (20 * 1.5), B = -w[n] c_k sin(...) / (20 * 1.5),
             c_0 = c_10 = 1, else 2. The first and last five samples take G = 1.5 / envelope (Q14).
Outputs (new build/ directory): activations.bin (128-channel input croutons), weights.bin (conv_post Wh, Wl, then
iSTFT Wh, Wl), tables.bin (16384 B: conv_post column tables at 0, iSTFT column tables at 4096, spectrum constants
at 8192, edge gains int32[10] at 14336), expected-pcm-f32.bin (stock PCM), fixture.json.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $StageFixture,
    [Parameter(Mandatory)][string] $CaptureDirectory,
    [string[]] $CalibrationDirectory,
    [Parameter(Mandatory)][string] $OutputDirectory,
    [ValidateRange(1.0, 4.0)][double] $Margin = 1.25,
    # Magnitude logits only feed exp(): their 16-bit window spans +-max(MagnitudeRange, margin * calibrated max)
    # instead of their full negative range (stock reaches -60), for a finer LSB; a second, coarse copy covers the
    # full range and is taken where the fine window saturates (Kokoro.TailSpectrum16.ps1).
    [ValidateRange(4.0, 64.0)][double] $MagnitudeRange = 10
)
$ErrorActionPreference = 'Stop'
$build = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build')) + [IO.Path]::DirectorySeparatorChar
$out = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $out.StartsWith($build, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)) { throw 'Use a new directory in build/.' }
Import-Module (Join-Path $PSScriptRoot 'Kokoro.CaptureMath.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Kokoro.CaptureKernels.psm1') -Force
. (Join-Path $PSScriptRoot '../src/emit/Kokoro.TailSpectrum16.ps1')
function Get-Even([double]$x) { [math]::Round($x, [MidpointRounding]::ToEven) }

$stageDir = [IO.Path]::GetFullPath($StageFixture)
$stage = Get-Content -LiteralPath (Join-Path $stageDir 'fixture.json') -Raw | ConvertFrom-Json
$frames = [int]$stage.Frames; $tiles = [int]$stage.Tiles; $sR = [double[]]@($stage.OutputScales)
$cap = Read-KokoroCapture -Directory $CaptureDirectory
if ($cap.Json.block -cne 'decoder.generator') { throw 'The evaluated capture must be a whole-generator capture.' }
$cals = @(if ($CalibrationDirectory) { foreach ($d in $CalibrationDirectory) { Read-KokoroCapture -Directory $d } } else { $cap })
$weight = Read-KokoroCaptureTensor -Capture $cap -Name 'generator.conv_post.weight'      # [22][128][7]
$bias = Read-KokoroCaptureTensor -Capture $cap -Name 'generator.conv_post.bias'
$pcmRef = Read-KokoroCaptureTensor -Capture $cap -Name 'output'
$logitRef = Read-KokoroCaptureTensor -Capture $cap -Name 'generator.conv_post.output'
if ($logitRef.Length -ne 22 * $frames) { throw 'conv_post frames differ from the stage fixture.' }
$samples = 5 * ($frames - 1)
if ($pcmRef.Length -ne $samples) { throw 'Stock PCM length is not 5 (frames - 1).' }

# Input: the stock mean of resblocks.3-5 (the stage's expected output) at the stage's residual scales.
$meanBytes = [IO.File]::ReadAllBytes((Join-Path $stageDir 'expected-f32.bin')); $mean = [float[]]::new($meanBytes.Length / 4); [Buffer]::BlockCopy($meanBytes, 0, $mean, 0, $meanBytes.Length)
$act = [byte[]]::new($tiles * 8192); $zero16 = [uint16[]]::new($tiles * 4096); [Array]::Fill($zero16, [uint16]0x8000); [Buffer]::BlockCopy($zero16, 0, $act, 0, $act.Length)
(Get-QuantizeCroutons16Kernel).Invoke($mean, $frames, $sR, $act)

# Calibration ranges: per stock conv_post channel absmax; the largest spectrum magnitude.
$outMax = [double[]]::new(22); $posMax = [double[]]::new(22); $eMax = 0.0
foreach ($c in $cals) {
    $z = Read-KokoroCaptureTensor -Capture $c -Name 'generator.conv_post.output'; $st = Get-KokoroChannelStats -Values $z -Channels 22
    for ($o = 0; $o -lt 22; $o++) { $outMax[$o] = [math]::Max($outMax[$o], $st.AbsMax[$o]) }
    for ($o = 0; $o -lt 11; $o++) { $seg = [float[]]::new($z.Length / 22); [Array]::Copy($z, $o * $seg.Length, $seg, 0, $seg.Length); $posMax[$o] = [math]::Max($posMax[$o], [Linq.Enumerable]::Max($seg)) }
    for ($o = 0; $o -lt 11; $o++) { $seg = [float[]]::new($z.Length / 22); [Array]::Copy($z, $o * $seg.Length, $seg, 0, $seg.Length); $eMax = [math]::Max($eMax, [math]::Exp([Linq.Enumerable]::Max($seg))) }
}
$sS = $eMax * $Margin / 32767

# Column tables of a three-group plane conv (as tools/New-KokoroGenerator60x16Fixture.ps1): per output block ob,
# planes 0..5 at (6 ob + plane) * 256: 32 fp16-exponent scale words then 32 bias words.
function Write-ColumnTables([byte[]]$Dest, [int]$At, [int[]]$Shift, [long[]]$SumH, [long[]]$SumL, [long[]]$BiasQ, [int]$Channels) {
    for ($o = 0; $o -lt $Channels; $o++) {
        $ob = [int][math]::Floor($o / 32); $cc = $o % 32; $L = $Shift[$o]
        $lg = @(($L - 8), $L, ($L + 8))
        $half = foreach ($x in $lg) { if ($x -ge 1) { [long][math]::Pow(2, $x - 1) } else { 0L } }
        $biasG = @((-128L * $SumH[$o] + [long][math]::Pow(2, $lg[0] + 15) + $half[0]), (-128L * $SumL[$o] + $BiasQ[$o] + [long][math]::Pow(2, $lg[1] + 15) + $half[1]), $half[2])
        for ($pl = 0; $pl -lt 6; $pl++) {
            $g = [int][math]::Floor($pl / 2); $e = $(if ($pl % 2) { 9 } else { 1 }) - $(if ($pl -eq 4) { $L } else { $lg[$g] }) + 15
            if ($e -lt 1 -or $e -gt 30) { throw "Table exponent out of range c$o" }
            if ($biasG[$g] -lt [int]::MinValue -or $biasG[$g] -gt [int]::MaxValue) { throw 'Table bias overflow.' }
            $a = $At + (6 * $ob + $pl) * 256
            [BitConverter]::GetBytes([uint32]($e -shl 10)).CopyTo($Dest, $a + 4 * $cc)
            [BitConverter]::GetBytes([int]$biasG[$g]).CopyTo($Dest, $a + 128 + 4 * $cc)
        }
    }
}
$tables = [byte[]]::new(16384)

# conv_post: 128 -> 64 placed channels, sR folded into the weights (input units: one integer LSB). Magnitude bin k
# goes to channel k (fine window, clipped) and channel 11 + k (coarse window, full range); phase bin k to 32 + k.
$wPost = [float[]]::new(64 * 128 * 7); $wAbs = [double[]]::new(64); $biasPost = [double[]]::new(64); $maxPost = [double[]]::new(64)
$slots = foreach ($o in 0..21) { if ($o -lt 11) { , @($o, $o, [math]::Max($MagnitudeRange / $Margin, $posMax[$o])); , @($o, (11 + $o), $outMax[$o]) } else { , @($o, (32 + $o - 11), $outMax[$o]) } }
foreach ($slot in $slots) {
    $o = $slot[0]; $p = $slot[1]; $biasPost[$p] = $bias[$o]; $maxPost[$p] = $slot[2]
    for ($i = 0; $i -lt 128; $i++) { for ($k = 0; $k -lt 7; $k++) { $v = [double]$weight[($o * 128 + $i) * 7 + $k] * $sR[$i]; $wPost[($p * 128 + $i) * 7 + $k] = [float]$v; $wAbs[$p] = [math]::Max($wAbs[$p], [math]::Abs($v)) } }
}
$Lpost = [int[]]::new(64); $sWpost = [double[]]::new(64); $unitPost = [double[]]::new(64)
for ($p = 0; $p -lt 64; $p++) {
    if ($wAbs[$p] -eq 0) { $Lpost[$p] = 8; $sWpost[$p] = 1.0; continue }
    $fine = $wAbs[$p] / 32512; $need = [math]::Max($maxPost[$p] * $Margin, 1e-30) / 32767
    $Lo = [math]::Clamp([int][math]::Ceiling([math]::Log($need / (256 * $fine), 2)), 2, 15)
    $Lpost[$p] = $Lo; $sWpost[$p] = [math]::Max($fine, $need / [math]::Pow(2, $Lo + 8)); $unitPost[$p] = [math]::Pow(2, $Lo + 8) * $sWpost[$p]
}
$whPost = [byte[]]::new(57344); $wlPost = [byte[]]::new(57344); $sumHPost = [long[]]::new(64); $sumLPost = [long[]]::new(64)
if ((Get-PackWeightPlanesShapedKernel).Invoke($wPost, 64, 128, 7, $sWpost, $whPost, $wlPost, $sumHPost, $sumLPost) -ne 0) { throw 'conv_post weight plane overflow' }
$bqPost = [long[]]::new(64); for ($p = 0; $p -lt 64; $p++) { $bqPost[$p] = [long](Get-Even ($biasPost[$p] / (256 * $sWpost[$p]))) }
Write-ColumnTables $tables 0 $Lpost $sumHPost $sumLPost $bqPost 64
# Spectrum constants (Kokoro.TailSpectrum16.ps1): per lane Ke, Be (fine), Kp, Mp (phase), and Kc, Bc (coarse, with
# delta = 8 coarse LSB folded into Bc so that the fine value wins wherever both are valid).
$spec = Get-KokoroTailSpectrumConstants
for ($k = 0; $k -lt 11; $k++) {
    $ke = Get-Even ($unitPost[$k] * [math]::Log(2.718281828459045, 2) * [math]::Pow(2, 31))
    $be = Get-Even (-[math]::Log($sS, 2) * 65536)
    $kp = Get-Even ($unitPost[32 + $k] * [math]::Pow(2, 39) / (2 * [math]::PI))
    $kc = Get-Even ($unitPost[11 + $k] * [math]::Log(2.718281828459045, 2) * [math]::Pow(2, 31))
    $bc = Get-Even ((8 * $unitPost[11 + $k] * [math]::Log(2.718281828459045, 2) - [math]::Log($sS, 2)) * 65536)
    foreach ($q in @(@(0, $ke), @(1, $be), @(2, $kp), @(3, 4194304), @(35, $kc), @(36, $bc))) {
        if ([math]::Abs($q[1]) -gt [int]::MaxValue) { throw "Spectrum constant out of range ($($q[0]), bin $k)" }
        [BitConverter]::GetBytes([int]$q[1]).CopyTo($spec, 128 * $q[0] + 4 * $k)
    }
}
[Array]::Copy($spec, 0, $tables, 8192, $spec.Length)

# iSTFT conv: 64 -> 64 (outputs 0..4), K 7, taps kk = 2..5 (frame shift kk - 3), j = 5 - kk, n = r + 5 j.
$win = [double[]]::new(20); for ($n = 0; $n -lt 20; $n++) { $win[$n] = 0.5 - 0.5 * [math]::Cos(2 * [math]::PI * $n / 20) }
$coefA = [double[,]]::new(20, 11); $coefB = [double[,]]::new(20, 11)
for ($n = 0; $n -lt 20; $n++) { for ($k = 0; $k -lt 11; $k++) {
    $ck = if ($k -eq 0 -or $k -eq 10) { 1.0 } else { 2.0 }; $ang = 2 * [math]::PI * $k * $n / 20
    $coefA[$n, $k] = $win[$n] * $ck * [math]::Cos($ang) / 30; $coefB[$n, $k] = -$win[$n] * $ck * [math]::Sin($ang) / 30 } }
$wIstft = [float[]]::new(64 * 64 * 7); $wRef = [double[]]::new(5 * 64 * 4); $iAbs = [double[]]::new(64)
for ($r = 0; $r -lt 5; $r++) { for ($j = 0; $j -lt 4; $j++) { $kk = 5 - $j; $n = $r + 5 * $j
    for ($k = 0; $k -lt 11; $k++) {
        $wIstft[($r * 64 + $k) * 7 + $kk] = [float]($coefA[$n, $k] * $sS); $wIstft[($r * 64 + 32 + $k) * 7 + $kk] = [float]($coefB[$n, $k] * $sS)
        $wRef[($r * 64 + $k) * 4 + ($kk - 2)] = $coefA[$n, $k]; $wRef[($r * 64 + 32 + $k) * 4 + ($kk - 2)] = $coefB[$n, $k]
        $iAbs[$r] = [math]::Max($iAbs[$r], [math]::Max([math]::Abs($coefA[$n, $k]), [math]::Abs($coefB[$n, $k])) * $sS)
    } } }
$Listft = [int[]]::new(64); $sWistft = [double[]]::new(64)
for ($r = 0; $r -lt 64; $r++) {
    if ($r -ge 5) { $Listft[$r] = 8; $sWistft[$r] = 1.0; continue }
    $Lr = [int][math]::Floor([math]::Log(32512 * [math]::Pow(2, -15) / $iAbs[$r], 2)) - 8
    if ($Lr -lt 2 -or $Lr -gt 15) { throw "iSTFT conv shift $Lr out of range (output $r)" }
    $Listft[$r] = $Lr; $sWistft[$r] = [math]::Pow(2, -15) / [math]::Pow(2, $Lr + 8)
}
$whI = [byte[]]::new(28672); $wlI = [byte[]]::new(28672); $sumHI = [long[]]::new(64); $sumLI = [long[]]::new(64)
if ((Get-PackWeightPlanesShapedKernel).Invoke($wIstft, 64, 64, 7, $sWistft, $whI, $wlI, $sumHI, $sumLI) -ne 0) { throw 'iSTFT weight plane overflow' }
Write-ColumnTables $tables 4096 $Listft $sumHI $sumLI ([long[]]::new(64)) 64

# Edge gains: the first and last five samples, G = 1.5 / envelope (Q14).
$envelope = { param([long]$pos) $e = 0.0; for ($m = 0; $m -lt $frames; $m++) { $n = $pos - 5 * $m; if ($n -ge 0 -and $n -lt 20) { $e += $win[$n] * $win[$n] } }; $e }
$gains = [double[]]::new(10)
for ($r = 0; $r -lt 5; $r++) { $gains[$r] = 1.5 / (& $envelope (10 + $r)); $gains[5 + $r] = 1.5 / (& $envelope (5L * $frames + $r)) }
for ($i = 0; $i -lt 10; $i++) { [BitConverter]::GetBytes([int](Get-Even ($gains[$i] * 16384))).CopyTo($tables, 14336 + 4 * $i) }

# Check of the folded synthesis: stock float logits -> Re/Im -> the iSTFT conv (unquantized) -> PCM vs stock PCM.
$reim = [double[]]::new(64 * $frames)
for ($k = 0; $k -lt 11; $k++) { for ($m = 0; $m -lt $frames; $m++) {
    $mag = [math]::Exp($logitRef[$k * $frames + $m]); $ph = [math]::Sin($logitRef[(11 + $k) * $frames + $m])
    $reim[$k * $frames + $m] = $mag * [math]::Cos($ph); $reim[(32 + $k) * $frames + $m] = $mag * [math]::Sin($ph) } }
$y = [double[]]::new(5 * $frames); (Get-Conv1dKernel).Invoke($reim, 64, $frames, $wRef, 5, 4, -1, $y)
$sig = 0.0; $noi = 0.0
for ($t = 0; $t -lt $samples; $t++) {
    $m = [math]::Floor($t / 5); $r = $t % 5; $v = $y[$r * $frames + $m]
    if ($t -lt 5) { $v *= $gains[$t] } elseif ($t -ge $samples - 5) { $v *= $gains[5 + $t - ($samples - 5)] }
    $d = $v - $pcmRef[$t]; $sig += [double]$pcmRef[$t] * $pcmRef[$t]; $noi += $d * $d
}
$foldedSnr = 10 * [math]::Log10($sig / [math]::Max($noi, 1e-300))
if ($foldedSnr -lt 80) { throw "Folded iSTFT disagrees with stock PCM ($([math]::Round($foldedSnr, 2)) dB)" }

[void][IO.Directory]::CreateDirectory($out)
$weights = [byte[]]::new(57344 * 2 + 28672 * 2)
[Array]::Copy($whPost, 0, $weights, 0, 57344); [Array]::Copy($wlPost, 0, $weights, 57344, 57344)
[Array]::Copy($whI, 0, $weights, 114688, 28672); [Array]::Copy($wlI, 0, $weights, 143360, 28672)
$pcmBytes = [byte[]]::new(4 * $samples); [Buffer]::BlockCopy($pcmRef, 0, $pcmBytes, 0, $pcmBytes.Length)
foreach ($f in @(@('activations.bin', $act), @('weights.bin', $weights), @('tables.bin', $tables), @('expected-pcm-f32.bin', $pcmBytes))) { [IO.File]::WriteAllBytes((Join-Path $out $f[0]), $f[1]) }
$files = @(Get-ChildItem -LiteralPath $out -File | ForEach-Object { [ordered]@{ Name = $_.Name; Bytes = $_.Length; SHA256 = (Get-FileHash $_.FullName).Hash } })
$summary = [ordered]@{
    Graph = 'GeneratorTail16'; Frames = $frames; Tiles = $tiles; Samples = $samples; SpectrumScale = $sS; Margin = $Margin
    FoldedSynthesisSnrDb = [math]::Round($foldedSnr, 2); ConvPostUnits = $unitPost; MagnitudeRange = $MagnitudeRange; ConvPostShifts = @($Lpost[0..21] + $Lpost[32..42]); IstftShifts = @($Listft[0..4])
    StageFixture = $stageDir; Capture = $cap.Root; CalibrationCaptures = @($cals | ForEach-Object { $_.Root }); Files = $files
}
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'fixture.json') -Encoding utf8NoBOM
[pscustomobject]@{ Directory = $out; FoldedSynthesisSnrDb = $summary.FoldedSynthesisSnrDb; SpectrumScale = $sS; ConvPostShifts = ($summary.ConvPostShifts -join ','); IstftShifts = ($summary.IstftShifts -join ',') }
