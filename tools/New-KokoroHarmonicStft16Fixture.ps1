#requires -Version 7.4
<# .SYNOPSIS
Packs the 16-bit harmonic-source STFT (merged source -> har) for Kokoro.HarmonicStft16Run.ps1.
.DESCRIPTION
Stock Kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec istftnet.py Generator.forward: har_spec, har_phase =
TorchSTFT.transform(har_source) (torch.stft n_fft 20, hop 5, win 20, periodic Hann, centre with reflect padding of 10;
torch.abs, torch.angle), har = cat(spec, phase): 22 channels, frames = samples / 5 + 1.
  signal      the stock merged source (m_source output 0) in the merge unit uM, reflect-padded by 10 on each side, int16
  STFT conv   64 -> 64, K 3 with the centre tap: input channel c of frame t is padded sample 5 t + c (c < 20); output k
              (Re_k = sum w_c x cos(2 pi k c / 20)) and 32 + k (Im_k = -sum w_c x sin(...)); Re_k and Im_k share one unit
  polar       CORDIC (Kokoro.StftPolar16.ps1): har channel k = |X_k| / sH_k, channel 11 + k = angle(X_k) / sH_(11+k)
sH is computed as the 60x front fixture computes it (tools/New-KokoroGeneratorFront16Fixture.ps1: per-channel absmax over
the calibration captures, times Margin / 32767), so the planes are directly the front's har input.
Outputs (new build/ directory): activations.bin (padded signal), weights.bin (STFT Wh, Wl), tables.bin (16384 B: column tables
at 0, group 3 shifts at 5120, polar constants at 8192), expected-har-f32.bin (stock har [22][frames]), fixture.json.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $CaptureDirectory,
    [string[]] $CalibrationDirectory,
    [Parameter(Mandatory)][string] $OutputDirectory,
    [ValidateRange(1.0, 4.0)][double] $Margin = 1.25
)
$ErrorActionPreference = 'Stop'
$build = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build')) + [IO.Path]::DirectorySeparatorChar
$out = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $out.StartsWith($build, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)) { throw 'Use a new directory in build/.' }
Import-Module (Join-Path $PSScriptRoot 'Kokoro.CaptureMath.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Kokoro.CaptureKernels.psm1') -Force
. (Join-Path $PSScriptRoot '../src/emit/Kokoro.StftPolar16.ps1')
. (Join-Path $PSScriptRoot '../src/emit/Kokoro.HarmonicStft16Run.ps1')
function Get-Even([double]$x) { [math]::Round($x, [MidpointRounding]::ToEven) }

$cap = Read-KokoroCapture -Directory $CaptureDirectory
$cals = @(if ($CalibrationDirectory) { foreach ($d in $CalibrationDirectory) { Read-KokoroCapture -Directory $d } } else { $cap })
$Read = { param($c, [string]$tensor) , (Read-KokoroCaptureTensor -Capture $c -Name $tensor) }
$merge = & $Read $cap 'generator.m_source.output.0'; $har = & $Read $cap 'generator.noise_convs.1.input.0'
$N = $merge.Length; $frames = $har.Length / 22
if ($frames -ne $N / 5 + 1) { throw 'har frames are not samples / 5 + 1.' }
$layout = Get-KokoroHarmonicStft16Layout -Frames $frames
$tiles = $layout.Tiles

# Scales: har (as the 60x front fixture), the merge unit, and the largest bin magnitude per bin.
$chanMax = { param([string]$name, [int]$ch) $m = [double[]]::new($ch); foreach ($c in $cals) { $st = Get-KokoroChannelStats -Values (& $Read $c $name) -Channels $ch; for ($i = 0; $i -lt $ch; $i++) { $m[$i] = [math]::Max($m[$i], $st.AbsMax[$i]) } }; , $m }
$sH = & $chanMax 'generator.noise_convs.1.input.0' 22
for ($i = 0; $i -lt 22; $i++) { $sH[$i] = [math]::Max($sH[$i], 1e-12) * $Margin / 32767 }
$mMax = 0.0; foreach ($c in $cals) { $mMax = [math]::Max($mMax, (Get-KokoroAbsMax -Values (& $Read $c 'generator.m_source.output.0'))) }
$uM = $mMax * $Margin / 32767
$binMax = [double[]]::new(11); for ($k = 0; $k -lt 11; $k++) { $binMax[$k] = $sH[$k] * 32767 / $Margin }

# Reflect-padded int16 signal (torch.stft centre, pad_mode reflect) and its frame windows as conv inputs [c][t].
$padded = { param([float[]]$x)
    $len = $x.Length; $p = [int16[]]::new($len + 20)
    for ($i = 0; $i -lt $len + 20; $i++) { $m = $i - 10; if ($m -lt 0) { $m = -$m }; if ($m -ge $len) { $m = 2 * ($len - 1) - $m }; $p[$i] = [int16][math]::Clamp((Get-Even ($x[$m] / $uM)), -32767, 32767) }
    , $p }
$windows = { param([int16[]]$p) $f = ($p.Length - 20) / 5 + 1; $w = [float[]]::new(64 * $f); for ($c = 0; $c -lt 20; $c++) { for ($t = 0; $t -lt $f; $t++) { $w[$c * $f + $t] = $p[5 * $t + $c] } }; , $w }
$sig = & $padded $merge
$inputs = [byte[]]::new($layout.SignalBytes); [Buffer]::BlockCopy($sig, 0, $inputs, 0, 2 * $sig.Length)

# STFT conv weights (input unit uM folded), one unit per bin for Re and Im.
$hann = [double[]]::new(20); for ($j = 0; $j -lt 20; $j++) { $hann[$j] = 0.5 - 0.5 * [math]::Cos(2 * [math]::PI * $j / 20) }
$w = [float[]]::new(64 * 64 * 3); $wMax = [double[]]::new(11)
for ($k = 0; $k -lt 11; $k++) {
    for ($c = 0; $c -lt 20; $c++) {
        $a = 2 * [math]::PI * $k * $c / 20
        $re = $hann[$c] * [math]::Cos($a) * $uM; $im = -$hann[$c] * [math]::Sin($a) * $uM
        if ($k -eq 0 -or $k -eq 10) { $im = 0.0 }   # sin(pi k c / 10) is zero for k = 0, 10: Im is exactly zero, as torch's +0
        $w[($k * 64 + $c) * 3 + 1] = [float]$re; $w[((32 + $k) * 64 + $c) * 3 + 1] = [float]$im
        $wMax[$k] = [math]::Max($wMax[$k], [math]::Max([math]::Abs($re), [math]::Abs($im)))
    }
}
$L = [int[]]::new(64); $sW = [double[]]::new(64); $unit = [double[]]::new(11)
for ($o = 0; $o -lt 64; $o++) { $L[$o] = 8; $sW[$o] = 1.0 }
for ($k = 0; $k -lt 11; $k++) {
    $fine = $wMax[$k] / 32512; $need = $binMax[$k] * $Margin / 32767
    $Lo = [math]::Clamp([int][math]::Ceiling([math]::Log($need / (256 * $fine), 2)), 2, 15)
    $swk = [math]::Max($fine, $need / [math]::Pow(2, $Lo + 8))
    foreach ($o in $k, (32 + $k)) { $L[$o] = $Lo; $sW[$o] = $swk }
    $unit[$k] = [math]::Pow(2, $Lo + 8) * $swk
}
$wh = [byte[]]::new(12288); $wl = [byte[]]::new(12288); $sumH = [long[]]::new(64); $sumL = [long[]]::new(64)
if ((Get-PackWeightPlanesShapedKernel).Invoke($w, 64, 64, 3, $sW, $wh, $wl, $sumH, $sumL) -ne 0) { throw 'STFT weight plane overflow' }

# Group 3 (low x low) range per channel from the real windows of every sentence (as the front fixtures).
$worst = [int[]]::new(64)
foreach ($c in @($cals) + , $cap) { $x = & $windows (& $padded (& $Read $c 'generator.m_source.output.0')); $per = [int[]]::new(64); [void](Get-LowLowWindowShapedKernel).Invoke($x, $x.Length / 64, 1.0, $w, 64, 64, 3, 1, $sW, $L, $per); for ($o = 0; $o -lt 64; $o++) { $worst[$o] = [math]::Max($worst[$o], $per[$o]) } }
$g3 = [int[]]::new(64)
for ($o = 0; $o -lt 64; $o++) {
    while ($worst[$o] -gt 100 * [math]::Pow(2, $g3[$o]) -and $g3[$o] -lt 6) { $g3[$o]++ }
    if ($worst[$o] -gt 127 * [math]::Pow(2, $g3[$o]) -or $L[$o] + $g3[$o] -gt 15) { throw "Low x low window ($($worst[$o])) out of range at output $o" }
}

# Column tables (three groups, per-channel group 3 range; bias zero) and group 3 shifts.
$tables = [byte[]]::new(16384)
for ($o = 0; $o -lt 64; $o++) {
    $ob = [int][math]::Floor($o / 32); $cc = $o % 32; $Lc = $L[$o]
    $lg = @(($Lc - 8), $Lc, ($Lc + 8 + $g3[$o]))
    $half = foreach ($x in $lg) { if ($x -ge 1) { [long][math]::Pow(2, $x - 1) } else { 0L } }
    $biasG = @((-128L * $sumH[$o] + [long][math]::Pow(2, $lg[0] + 15) + $half[0]), (-128L * $sumL[$o] + [long][math]::Pow(2, $lg[1] + 15) + $half[1]), $half[2])
    for ($pl = 0; $pl -lt 6; $pl++) {
        $g = [int][math]::Floor($pl / 2); $e = $(if ($pl % 2) { 9 } else { 1 }) - $(if ($pl -eq 4) { $Lc } else { $lg[$g] }) + 15
        if ($e -lt 1 -or $e -gt 30) { throw "Table exponent out of range c$o" }
        $at = (6 * $ob + $pl) * 256
        [BitConverter]::GetBytes([uint32]($e -shl 10)).CopyTo($tables, $at + 4 * $cc)
        [BitConverter]::GetBytes([int]$biasG[$g]).CopyTo($tables, $at + 128 + 4 * $cc)
    }
    $g3Shift = [uint32](8 - $g3[$o]); [BitConverter]::GetBytes($g3Shift -bor ($g3Shift -shl 16)).CopyTo($tables, 5120 + 128 * $ob + 4 * $cc)
}

# Polar constants: Km_k = unit_k 2^31 / (K 2^G sH_k), Kp_k = (pi / 2^30) 2^31 / sH_(11+k).
$polar = Get-KokoroStftPolarConstants; $pc = $polar.Bytes
$Km = [long[]]::new(11); $Kp = [long[]]::new(11)
for ($k = 0; $k -lt 11; $k++) {
    $Km[$k] = [long](Get-Even ($unit[$k] * [math]::Pow(2, 31) / ($polar.Gain * [math]::Pow(2, $polar.Guard) * $sH[$k])))
    $Kp[$k] = [long](Get-Even ([math]::PI * 2 / $sH[11 + $k]))
    if ($Km[$k] -lt 1 -or $Km[$k] -gt [int]::MaxValue -or $Kp[$k] -lt 1 -or $Kp[$k] -gt [int]::MaxValue) { throw "Polar multiplier out of range at bin $k" }
    [BitConverter]::GetBytes([int]$Km[$k]).CopyTo($pc, 128 * 5 + 4 * $k); [BitConverter]::GetBytes([int]$Kp[$k]).CopyTo($pc, 128 * 6 + 4 * $k)
}
[Array]::Copy($pc, 0, $tables, 8192, 4096)

# Folded check: the quantized padded signal through the folded float weights -> |X|, angle vs stock har.
$xw = & $windows $sig; $xd = [double[]]::new($xw.Length); for ($i = 0; $i -lt $xw.Length; $i++) { $xd[$i] = $xw[$i] }
$wd = [double[]]::new($w.Length); for ($i = 0; $i -lt $w.Length; $i++) { $wd[$i] = $w[$i] }
$y = [double[]]::new(64 * $frames); (Get-Conv1dKernel).Invoke($xd, 64, $frames, $wd, 64, 3, -1, $y)
$ms = 0.0; $me = 0.0; $pe = 0.0; $pw = 0.0
for ($k = 0; $k -lt 11; $k++) { for ($t = 0; $t -lt $frames; $t++) {
    $re = $y[$k * $frames + $t]; $im = $y[(32 + $k) * $frames + $t]
    $mag = [math]::Sqrt($re * $re + $im * $im); $ph = [math]::Atan2($im, $re); if ($im -eq 0 -and $re -lt 0) { $ph = [math]::PI }
    $sm = [double]$har[$k * $frames + $t]; $sp = [double]$har[(11 + $k) * $frames + $t]
    $ms += $sm * $sm; $me += ($mag - $sm) * ($mag - $sm)
    $dp = $ph - $sp; $dp -= 2 * [math]::PI * [math]::Round($dp / (2 * [math]::PI)); $pe += $sm * $sm * $dp * $dp; $pw += $sm * $sm
} }
$foldedMag = 10 * [math]::Log10($ms / $me); $foldedPhase = [math]::Sqrt($pe / $pw)
if ($foldedMag -lt 60) { throw "Folded STFT disagrees with stock har ($([math]::Round($foldedMag, 2)) dB)" }

[void][IO.Directory]::CreateDirectory($out)
$hb = [byte[]]::new(4 * $har.Length); [Buffer]::BlockCopy($har, 0, $hb, 0, $hb.Length)
foreach ($f in @(@('activations.bin', $inputs), @('weights.bin', [byte[]]($wh + $wl)), @('tables.bin', $tables), @('expected-har-f32.bin', $hb))) { [IO.File]::WriteAllBytes((Join-Path $out $f[0]), $f[1]) }
$files = @(Get-ChildItem -LiteralPath $out -File | ForEach-Object { [ordered]@{ Name = $_.Name; Bytes = $_.Length; SHA256 = (Get-FileHash $_.FullName).Hash } })
[ordered]@{ Graph = 'HarmonicStft16'; Frames = $frames; Tiles = $tiles; Samples = $N; MergeUnit = $uM; HarScales = $sH; BinUnits = $unit; Shifts = @($L[0..10]); Group3 = @($g3[0..10] + $g3[32..42])
    PolarGain = $polar.Gain; PolarGuard = $polar.Guard; PolarIterations = $polar.Iterations; FoldedMagnitudeSnrDb = [math]::Round($foldedMag, 2); FoldedPhaseRmsRad = $foldedPhase; Margin = $Margin
    Capture = $cap.Root; CalibrationCaptures = @($cals | ForEach-Object { $_.Root }); Files = $files } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'fixture.json') -Encoding utf8NoBOM
[pscustomobject]@{ Directory = $out; FoldedMagnitudeSnrDb = [math]::Round($foldedMag, 2); FoldedPhaseRmsRad = $foldedPhase; Shifts = (($L[0..10]) -join ','); Group3 = (($g3[0..10] + $g3[32..42]) -join ',') }
