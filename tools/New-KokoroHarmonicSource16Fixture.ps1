#requires -Version 7.4
<# .SYNOPSIS
Packs the 16-bit harmonic source and STFT (frame-rate f0 -> har) for Kokoro.HarmonicSource16Run.ps1.
.DESCRIPTION
Stock Kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec istftnet.py SineGen / SourceModuleHnNSF (closed form in
src/emit/Kokoro.HarmonicSource16.ps1) and TorchSTFT.transform. The capture must record SineGen's random draws
(tools/reference/capture_stock_generator.py, generator.m_source.l_sin_gen.randn.0).
  f0     the captured frame-rate f0 as int32 Q16 Hz
  z      sum_h w_h g_h from the captured standard normal draws g (l_linear weights w), Q12 halfwords; the job scales it by
         0.003 (voiced) or 0.1 / 3, so z carries stock's noise exactly up to rounding
  c_h    0.1 w_h (Q15), b the l_linear bias (Q15)
The STFT part is tools/New-KokoroHarmonicStft16Fixture.ps1 with the merge unit 2^-15 (the source writes Q15), built into
<output>/stft. Outputs: activations.bin (f0, then z), weights.bin, tables.bin (STFT tables, then the source constants),
expected-merge-f32.bin, expected-har-f32.bin, fixture.json.
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
foreach ($f in 'Kokoro.StftPolar16.ps1', 'Kokoro.HarmonicStft16Run.ps1', 'Kokoro.HarmonicSource16.ps1', 'Kokoro.HarmonicSource16Run.ps1') { . (Join-Path $PSScriptRoot "../src/emit/$f") }
function Get-Even([double]$x) { [math]::Round($x, [MidpointRounding]::ToEven) }

[void][IO.Directory]::CreateDirectory($out)
$stftDir = Join-Path $out 'stft'
$stftArgs = @{ CaptureDirectory = $CaptureDirectory; OutputDirectory = $stftDir; Margin = $Margin; MergeUnit = [math]::Pow(2, -15) }
if ($CalibrationDirectory) { $stftArgs.CalibrationDirectory = $CalibrationDirectory }
$stftResult = & (Join-Path $PSScriptRoot 'New-KokoroHarmonicStft16Fixture.ps1') @stftArgs
$stft = Get-Content -LiteralPath (Join-Path $stftDir 'fixture.json') -Raw | ConvertFrom-Json

$cap = Read-KokoroCapture -Directory $CaptureDirectory
$Read = { param([string]$tensor) , (Read-KokoroCaptureTensor -Capture $cap -Name $tensor) }
$f0 = & $Read 'f0'; $g = & $Read 'generator.m_source.l_sin_gen.randn.0'; $w = & $Read 'generator.m_source.l_linear.weight'
$bias = (& $Read 'generator.m_source.l_linear.bias')[0]; $mergeStock = & $Read 'generator.m_source.output.0'
$layout = Get-KokoroHarmonicSource16Layout -Frames ([int]$stft.Frames)
$L = $f0.Length; $N = $layout.Samples
if ($L -ne $layout.F0Frames -or $g.Length -ne 9 * $N -or $mergeStock.Length -ne $N) { throw 'Capture shapes do not match the layout.' }

# Inputs: f0 Q16, z Q12.
$f0q = [int[]]::new($L); for ($m = 0; $m -lt $L; $m++) { $f0q[$m] = [int](Get-Even ([double]$f0[$m] * 65536)) }
$zq = [int16[]]::new(64 * $layout.Blocks)
for ($j = 0; $j -lt $N; $j++) { $acc = 0.0; for ($h = 0; $h -lt 9; $h++) { $acc += [double]$w[$h] * $g[9 * $j + $h] }; $zq[$j] = [int16][math]::Clamp((Get-Even ($acc * 4096)), -32768, 32767) }
$act = [byte[]]::new($layout.InputBytes)
[Buffer]::BlockCopy($f0q, 0, $act, 0, 4 * $L); [Buffer]::BlockCopy($zq, 0, $act, [int]$layout.F0Bytes, 2 * $zq.Length)

# Constants.
$sc = Get-KokoroHarmonicSourceConstants
$put = { param([int]$index,[int]$value) $word = (([long]$value -band 0xffff) -shl 16) -bor ([long]$value -band 0xffff); for ($lane = 0; $lane -lt 32; $lane++) { [BitConverter]::GetBytes([uint32]$word).CopyTo($sc, 128 + 128 * $index + 4 * $lane) } }
$ch = [int[]]::new(9); for ($h = 0; $h -lt 9; $h++) { $ch[$h] = [int](Get-Even (0.1 * $w[$h] * 32768)); & $put (9 + $h) $ch[$h] }
$bq = [int](Get-Even ($bias * 32768)); & $put 18 $bq
$mult = [BitConverter]::ToUInt32($sc, 0); $ampV = [BitConverter]::ToInt32($sc, 8); $ampU = [BitConverter]::ToInt32($sc, 12)

# Build-time check: the closed form with the job's integer inputs and constants, in double, against stock's merged source.
$inc = [double[]]::new($L); $P = [double[]]::new($L); $neg = [bool[]]::new($L); $acc = 0.0
for ($m = 0; $m -lt $L; $m++) { $inc[$m] = [math]::Floor($f0q[$m] * [double]$mult / 16777216) / 4294967296; $neg[$m] = $f0q[$m] -lt 0; $acc += 300 * $inc[$m]; $P[$m] = $acc }
$se = 0.0; $ss = 0.0; $flipVoiced = 0
for ($j = 0; $j -lt $N; $j++) {
    $frame = [math]::Floor($j / 300); $uv = $f0q[$frame] -gt 655360
    if ($j -lt 150) { $psi = $P[0]; $sign = 1 } elseif ($j -ge 300 * ($L - 1) + 150) { $psi = $P[$L - 1]; $sign = 1 }
    else { $k = [math]::Floor(($j - 150) / 300); $within = $j - 300 * $k - 150; $psi = $P[$k] + ($within + 0.5) * $inc[$k + 1]; $sign = if ($neg[$k + 1]) { -1 } else { 1 } }
    if ($uv -and $sign -lt 0) { $flipVoiced++ }
    $sum = 0.0; if ($uv) { for ($h = 1; $h -le 9; $h++) { $x = $h * $psi; $x -= [math]::Floor($x); $sum += $ch[$h - 1] / 32768.0 * [math]::Sin(2 * [math]::PI * $x) } }
    $a = $sign * $sum + $bq / 32768.0 + $zq[$j] / 4096.0 * $(if ($uv) { $ampV } else { $ampU }) / 8 / 32768
    $d = [math]::Tanh($a) - $mergeStock[$j]; $se += $d * $d; $ss += [double]$mergeStock[$j] * $mergeStock[$j]
}
$closedSnr = 10 * [math]::Log10($ss / $se)
if ($closedSnr -lt 50) { throw "Closed-form source disagrees with stock ($([math]::Round($closedSnr, 2)) dB)" }

$tablesStft = [IO.File]::ReadAllBytes((Join-Path $stftDir 'tables.bin'))
$tables = [byte[]]::new($tablesStft.Length + 4096); [Array]::Copy($tablesStft, $tables, $tablesStft.Length); [Array]::Copy($sc, 0, $tables, $tablesStft.Length, 4096)
$mb = [byte[]]::new(4 * $N); [Buffer]::BlockCopy($mergeStock, 0, $mb, 0, $mb.Length)
foreach ($f in @(@('activations.bin', $act), @('weights.bin', [IO.File]::ReadAllBytes((Join-Path $stftDir 'weights.bin'))), @('tables.bin', $tables), @('expected-merge-f32.bin', $mb), @('expected-har-f32.bin', [IO.File]::ReadAllBytes((Join-Path $stftDir 'expected-har-f32.bin'))))) { [IO.File]::WriteAllBytes((Join-Path $out $f[0]), $f[1]) }
$files = @(Get-ChildItem -LiteralPath $out -File | ForEach-Object { [ordered]@{ Name = $_.Name; Bytes = $_.Length; SHA256 = (Get-FileHash $_.FullName).Hash } })
[ordered]@{ Graph = 'HarmonicSource16'; Frames = $stft.Frames; Tiles = $stft.Tiles; Samples = $N; F0Frames = $L; HarScales = $stft.HarScales; MergeUnit = [math]::Pow(2, -15)
    HarmonicCoefficients = $ch; Bias = $bq; ClosedFormSnrDb = [math]::Round($closedSnr, 2); VoicedSignFlipSamples = $flipVoiced; StftFixture = $stftDir; Capture = $cap.Root; Files = $files } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'fixture.json') -Encoding utf8NoBOM
[pscustomobject]@{ Directory = $out; ClosedFormSnrDb = [math]::Round($closedSnr, 2); VoicedSignFlipSamples = $flipVoiced; StftFolded = $stftResult.FoldedMagnitudeSnrDb }
