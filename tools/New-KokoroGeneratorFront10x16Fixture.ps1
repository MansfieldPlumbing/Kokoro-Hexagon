#requires -Version 7.4
<# .SYNOPSIS
Packs the 256-channel generator front (leaky, ups[0], noise_convs[0], add) for Kokoro.Generator60x16Run.ps1 -Channels 256 -Front.
.DESCRIPTION
Stock Kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec istftnet.py Generator.forward, i = 0:
  x = leaky_relu(x, 0.1);  x_source = noise_res[0](noise_convs[0](har), s);  x = ups[0](x) + x_source
The DSP job: LeakyReLU(0.1) of the decoder output on the integers (Kokoro.LeakyRelu16.ps1 -Slope 0.1; its per-channel
scale folds into ups[0]'s weights); ups[0] as ten polyphase HMX convs (512 -> 256, taps at frame shifts -1..1,
k = 10 (1 - j) + r + 5; output frame 10 q + r), interleaved in phase pairs; noise_convs[0] as one HMX conv over har
rearranged phase-major (X'[22 rho + c][m'] = har[c][6 m' + rho], 132 of 256 input channels; k = 6 (j - 1) + rho + 3),
its result added onto a zero residual in noise_res[0]'s units; R0 = sat(rU * X + rN * Xn) in resblocks.0-2's units.
Both rearrangements reproduce stock at 131.7 and 133.5 dB from stock floats (build-time check of the same index maps).
Outputs (new build/ directory):
  inputs.bin   decoder output (512-channel biased u16 croutons), then har high and low planes (phase-major, 256 channels)
  weights.bin  noise conv Wh, Wl (256 x 256 x 3), then per ups[0] phase Wh, Wl (256 x 512 x 3)
  tables.bin   163840 B: noise conv column tables at 0, residual ratios (Q15 int32) at 12288, group 3 shifts at 13312;
               ups phase r column tables at 16384 + 12288 r, its group 3 shifts at 139264 + 1024 r; rU, rN (Q14, both
               halfwords of each lane, one vector per 32-channel block) at 149504, 150528
  expected-f32.bin  stock resblocks.0 input; fixture.json.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $StageFixture,
    [Parameter(Mandatory)][string] $NoiseResFixture,
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
function Get-Even([double]$x) { [math]::Round($x, [MidpointRounding]::ToEven) }

$stageDir = [IO.Path]::GetFullPath($StageFixture); $noiseDir = [IO.Path]::GetFullPath($NoiseResFixture)
$stage = Get-Content -LiteralPath (Join-Path $stageDir 'fixture.json') -Raw | ConvertFrom-Json
$noise = Get-Content -LiteralPath (Join-Path $noiseDir 'fixture.json') -Raw | ConvertFrom-Json
$frames = [int]$stage.Frames; $tiles = [int]$stage.Tiles
if (@($stage.OutputScales).Count -ne 256 -or $noise.Frames -ne $frames -or $noise.Module -ne 'noise_res' -or @($noise.Blocks)[0] -ne 0) { throw 'Expected the 256-channel stage and the noise_res[0] fixtures.' }
$sR = [double[]]@($stage.OutputScales); $sN = [double[]]@($noise.OutputScales)
$cap = Read-KokoroCapture -Directory $CaptureDirectory
$cals = @(if ($CalibrationDirectory) { foreach ($d in $CalibrationDirectory) { Read-KokoroCapture -Directory $d } } else { $cap })
$readT = { param($c, [string]$n) , (Read-KokoroCaptureTensor -Capture $c -Name $n) }
$dec = & $readT $cap 'input'; $har = & $readT $cap 'generator.noise_convs.0.input.0'
$mIn = $dec.Length / 512; $qFrames = $mIn + 1; $qTiles = [int][math]::Ceiling($qFrames / 32); $decTiles = [int][math]::Ceiling($mIn / 32)
if (10 * $mIn -ne $frames) { throw 'ups[0] frames do not give the 10x frames.' }
$harFrames = $har.Length / 22; $pFrames = $frames + 1

$chanMax = { param([string]$name, [int]$ch) $m = [double[]]::new($ch); foreach ($c in $cals) { $st = Get-KokoroChannelStats -Values (& $readT $c $name) -Channels $ch; for ($i = 0; $i -lt $ch; $i++) { $m[$i] = [math]::Max($m[$i], $st.AbsMax[$i]) } }; , $m }
$sD = & $chanMax 'input' 512; for ($i = 0; $i -lt 512; $i++) { $sD[$i] = [math]::Max($sD[$i], 1e-12) * $Margin / 32767 }
$sH = & $chanMax 'generator.noise_convs.0.input.0' 22; for ($i = 0; $i -lt 22; $i++) { $sH[$i] = [math]::Max($sH[$i], 1e-12) * $Margin / 32767 }
$oNoise = & $chanMax 'generator.noise_convs.0.output' 256; $oUp = & $chanMax 'generator.ups.0.output' 256

# Decoder output as biased u16 croutons (512 channels); har phase-major planes.
$act = [byte[]]::new($decTiles * 32768); $z = [uint16[]]::new($act.Length / 2); [Array]::Fill($z, [uint16]0x8000); [Buffer]::BlockCopy($z, 0, $act, 0, $act.Length)
(Get-QuantizeCroutons16Kernel).Invoke($dec, $mIn, $sD, $act)
$phaseMajor = { param([float[]]$h) $f = $h.Length / 22; $x = [float[]]::new(256 * $pFrames)
    for ($rho = 0; $rho -lt 6; $rho++) { for ($c = 0; $c -lt 22; $c++) { for ($m = 0; $m -lt $pFrames; $m++) { $t = 6 * $m + $rho; if ($t -lt $f) { $x[(22 * $rho + $c) * $pFrames + $m] = $h[$c * $f + $t] } } } }; , $x }
$hp = & $phaseMajor $har
$scH = [double[]]::new(256); for ($i = 0; $i -lt 256; $i++) { $scH[$i] = if ($i -lt 132) { $sH[$i % 22] } else { 1.0 } }
$u = [byte[]]::new($tiles * 16384); $z = [uint16[]]::new($u.Length / 2); [Array]::Fill($z, [uint16]0x8000); [Buffer]::BlockCopy($z, 0, $u, 0, $u.Length)
if ([math]::Ceiling($pFrames / 32) -gt $tiles) { throw 'Phase-major har needs more tiles than the stage.' }
(Get-QuantizeCroutons16Kernel).Invoke($hp, $pFrames, $scH, $u)
$harHi = [byte[]]::new($u.Length); $harLo = [byte[]]::new($u.Length); (Get-SplitPlanesKernel).Invoke($u, $harHi, $harLo)

function Get-Units([double[]]$wMax, [double[]]$need) {
    $n = $wMax.Length; $Ls = [int[]]::new($n); $sw = [double[]]::new($n); $unit = [double[]]::new($n)
    for ($o = 0; $o -lt $n; $o++) {
        if ($wMax[$o] -eq 0) { $Ls[$o] = 8; $sw[$o] = 1.0; continue }
        $fine = $wMax[$o] / 32512; $nd = [math]::Max($need[$o], 1e-30)
        $Lo = [math]::Clamp([int][math]::Ceiling([math]::Log($nd / (256 * $fine), 2)), 2, 15)
        $Ls[$o] = $Lo; $sw[$o] = [math]::Max($fine, $nd / [math]::Pow(2, $Lo + 8)); $unit[$o] = [math]::Pow(2, $Lo + 8) * $sw[$o]
    }
    [pscustomobject]@{ L = $Ls; SW = $sw; Unit = $unit }
}
function Write-Tables([byte[]]$dest, [int]$at, [int[]]$Ls, [long[]]$sumH, [long[]]$sumL, [long[]]$bq, [int[]]$g3, [int]$shiftAt) {
    for ($o = 0; $o -lt $Ls.Length; $o++) {
        $ob = [int][math]::Floor($o / 32); $cc = $o % 32; $L = $Ls[$o]
        $lg = @(($L - 8), $L, ($L + 8 + $g3[$o]))
        $half = foreach ($x in $lg) { if ($x -ge 1) { [long][math]::Pow(2, $x - 1) } else { 0L } }
        $biasG = @((-128L * $sumH[$o] + [long][math]::Pow(2, $lg[0] + 15) + $half[0]), (-128L * $sumL[$o] + $bq[$o] + [long][math]::Pow(2, $lg[1] + 15) + $half[1]), $half[2])
        for ($pl = 0; $pl -lt 6; $pl++) {
            $g = [int][math]::Floor($pl / 2); $e = $(if ($pl % 2) { 9 } else { 1 }) - $(if ($pl -eq 4) { $L } else { $lg[$g] }) + 15
            if ($e -lt 1 -or $e -gt 30) { throw "Table exponent out of range c$o" }
            if ($biasG[$g] -lt [int]::MinValue -or $biasG[$g] -gt [int]::MaxValue) { throw 'Table bias overflow.' }
            $a = $at + (6 * $ob + $pl) * 256
            [BitConverter]::GetBytes([uint32]($e -shl 10)).CopyTo($dest, $a + 4 * $cc)
            [BitConverter]::GetBytes([int]$biasG[$g]).CopyTo($dest, $a + 128 + 4 * $cc)
        }
        $sh = [uint32](8 - $g3[$o]); [BitConverter]::GetBytes($sh -bor ($sh -shl 16)).CopyTo($dest, $shiftAt + 128 * $ob + 4 * $cc)
    }
}
function Get-Group3([scriptblock]$inputs, [float[]]$w, [int]$cin, [int]$cout, [double[]]$sw, [int[]]$Ls) {
    $worst = [int[]]::new($cout)
    foreach ($c in @($cals) + , $cap) { $xs = & $inputs $c; $per = [int[]]::new($cout); [void](Get-LowLowWindowShapedKernel).Invoke($xs, $xs.Length / $cin, 1.0, $w, $cin, $cout, 3, 1, $sw, $Ls, $per); for ($o = 0; $o -lt $cout; $o++) { $worst[$o] = [math]::Max($worst[$o], $per[$o]) } }
    $g = [int[]]::new($cout)
    for ($o = 0; $o -lt $cout; $o++) {
        while ($worst[$o] -gt 100 * [math]::Pow(2, $g[$o]) -and $g[$o] -lt 6) { $g[$o]++ }
        if ($worst[$o] -gt 127 * [math]::Pow(2, $g[$o]) -or $Ls[$o] + $g[$o] -gt 15) { throw "Low x low window ($($worst[$o])) out of range at output $o" }
    }
    [pscustomobject]@{ G = $g; Worst = ($worst | Measure-Object -Maximum).Maximum }
}
$tables = [byte[]]::new(163840)

# noise_convs[0] over phase-major har (inputs in units of sH, folded).
$wN = & $readT $cap 'generator.noise_convs.0.weight'; $bN = & $readT $cap 'generator.noise_convs.0.bias'      # [256][22][12]
$wNf = [float[]]::new(256 * 256 * 3); $wNmax = [double[]]::new(256)
for ($o = 0; $o -lt 256; $o++) { for ($rho = 0; $rho -lt 6; $rho++) { for ($c = 0; $c -lt 22; $c++) { for ($j = 0; $j -lt 3; $j++) {
    $k = 6 * ($j - 1) + $rho + 3; if ($k -lt 0 -or $k -ge 12) { continue }
    $v = [double]$wN[($o * 22 + $c) * 12 + $k] * $sH[$c]; $wNf[($o * 256 + 22 * $rho + $c) * 3 + $j] = [float]$v; $wNmax[$o] = [math]::Max($wNmax[$o], [math]::Abs($v)) } } } }
$needN = [double[]]::new(256); for ($o = 0; $o -lt 256; $o++) { $needN[$o] = $oNoise[$o] * $Margin / 32767 }
$uN = Get-Units $wNmax $needN
for ($o = 0; $o -lt 256; $o++) {
    if ($uN.Unit[$o] -ge $sN[$o]) {
        $fine = $wNmax[$o] / 32512; $target = 0.999 * $sN[$o]
        $Lo = [math]::Clamp([int][math]::Floor([math]::Log($target / (256 * $fine), 2)), 2, 15); $sw = $target / [math]::Pow(2, $Lo + 8)
        if ($sw -lt $fine -or $oNoise[$o] -gt 32767 * $target) { throw "noise conv output does not fit noise_res's residual units at c$o" }
        $uN.L[$o] = $Lo; $uN.SW[$o] = $sw; $uN.Unit[$o] = $target
    }
    [BitConverter]::GetBytes([int](Get-Even ($uN.Unit[$o] / $sN[$o] * 32768))).CopyTo($tables, 12288 + 4 * $o)
}
$whN = [byte[]]::new(196608); $wlN = [byte[]]::new(196608); $shN = [long[]]::new(256); $slN = [long[]]::new(256)
if ((Get-PackWeightPlanesShapedKernel).Invoke($wNf, 256, 256, 3, $uN.SW, $whN, $wlN, $shN, $slN) -ne 0) { throw 'noise conv weight overflow' }
$bqN = [long[]]::new(256); for ($o = 0; $o -lt 256; $o++) { $bqN[$o] = [long](Get-Even ($bN[$o] / (256 * $uN.SW[$o]))) }
$harIn = { param($c) $h = & $readT $c 'generator.noise_convs.0.input.0'; $x = & $phaseMajor $h; $f = $x.Length / 256; for ($i = 0; $i -lt 132; $i++) { for ($t = 0; $t -lt $f; $t++) { $x[$i * $f + $t] = [float]($x[$i * $f + $t] / $sH[$i % 22]) } }; , $x }
$g3N = Get-Group3 $harIn $wNf 256 256 $uN.SW $uN.L
Write-Tables $tables 0 $uN.L $shN $slN $bqN $g3N.G 13312

# ups[0]: ten phases, units per output channel shared by the phases; inputs leaky(x) in units of sD (folded).
$wU = & $readT $cap 'generator.ups.0.weight'; $bU = & $readT $cap 'generator.ups.0.bias'          # [512][256][20]
$wUmax = [double[]]::new(256)
for ($c = 0; $c -lt 512; $c++) { for ($o = 0; $o -lt 256; $o++) { for ($k = 0; $k -lt 20; $k++) { $wUmax[$o] = [math]::Max($wUmax[$o], [math]::Abs([double]$wU[($c * 256 + $o) * 20 + $k] * $sD[$c])) } } }
$needU = [double[]]::new(256); for ($o = 0; $o -lt 256; $o++) { $needU[$o] = $oUp[$o] * $Margin / 32767 }
$uU = Get-Units $wUmax $needU
$weights = [System.Collections.Generic.List[byte]]::new(); $weights.AddRange($whN); $weights.AddRange($wlN)
$upIn = { param($c) $h = & $readT $c 'input'; $m = $h.Length / 512; $f = $m + 1; $x = [float[]]::new(512 * $f)
    for ($i = 0; $i -lt 512; $i++) { for ($t = 0; $t -lt $m; $t++) { $v = $h[$i * $m + $t]; if ($v -lt 0) { $v *= 0.1 }; $x[$i * $f + $t] = [float]($v / $sD[$i]) } }; , $x }
$g3Worst = @($g3N.Worst)
for ($r = 0; $r -lt 10; $r++) {
    $wc = [float[]]::new(256 * 512 * 3); $bq2 = [long[]]::new(256)
    for ($o = 0; $o -lt 256; $o++) { for ($j = 0; $j -lt 3; $j++) { $k = 10 * (1 - $j) + $r + 5; if ($k -lt 0 -or $k -ge 20) { continue }
        for ($c = 0; $c -lt 512; $c++) { $wc[($o * 512 + $c) * 3 + $j] = [float]([double]$wU[($c * 256 + $o) * 20 + $k] * $sD[$c]) } } }
    $wh2 = [byte[]]::new(393216); $wl2 = [byte[]]::new(393216); $sh2 = [long[]]::new(256); $sl2 = [long[]]::new(256)
    if ((Get-PackWeightPlanesShapedKernel).Invoke($wc, 256, 512, 3, $uU.SW, $wh2, $wl2, $sh2, $sl2) -ne 0) { throw "ups weight overflow (phase $r)" }
    for ($o = 0; $o -lt 256; $o++) { $bq2[$o] = [long](Get-Even ($bU[$o] / (256 * $uU.SW[$o]))) }
    $g3U = Get-Group3 $upIn $wc 512 256 $uU.SW $uU.L; $g3Worst += $g3U.Worst
    Write-Tables $tables (16384 + 12288 * $r) $uU.L $sh2 $sl2 $bq2 $g3U.G (139264 + 1024 * $r)
    $weights.AddRange($wh2); $weights.AddRange($wl2)
}
# Final add, Q14 ratios in both halfwords of each lane.
for ($o = 0; $o -lt 256; $o++) {
    $rU = Get-Even ($uU.Unit[$o] / $sR[$o] * 16384); $rN = Get-Even ($sN[$o] / $sR[$o] * 16384)
    if ($rU -gt 32767 -or $rN -gt 32767 -or $rU -lt 1 -or $rN -lt 1) { throw "Front add ratio out of Q14 range at c$o ($rU, $rN)" }
    foreach ($q in @(@(149504, $rU), @(150528, $rN))) { [BitConverter]::GetBytes([uint32]$q[1] -bor ([uint32]$q[1] -shl 16)).CopyTo($tables, $q[0] + 4 * $o) }
}

[void][IO.Directory]::CreateDirectory($out)
$inputs = [byte[]]::new($act.Length + 2 * $harHi.Length); [Array]::Copy($act, $inputs, $act.Length); [Array]::Copy($harHi, 0, $inputs, $act.Length, $harHi.Length); [Array]::Copy($harLo, 0, $inputs, $act.Length + $harHi.Length, $harLo.Length)
$expected = & $readT $cap 'generator.resblocks.0.input.0'; $eb = [byte[]]::new(4 * $expected.Length); [Buffer]::BlockCopy($expected, 0, $eb, 0, $eb.Length)
foreach ($f in @(@('inputs.bin', $inputs), @('weights.bin', $weights.ToArray()), @('tables.bin', $tables), @('expected-f32.bin', $eb))) { [IO.File]::WriteAllBytes((Join-Path $out $f[0]), $f[1]) }
$files = @(Get-ChildItem -LiteralPath $out -File | ForEach-Object { [ordered]@{ Name = $_.Name; Bytes = $_.Length; SHA256 = (Get-FileHash $_.FullName).Hash } })
[ordered]@{ Graph = 'GeneratorFront10x16'; Frames = $frames; Tiles = $tiles; DecoderFrames = $mIn; DecoderTiles = $decTiles; UpFrames = $qFrames; OutputScales = $sR; DecoderScales = $sD; Margin = $Margin
    NoiseConvShifts = @($uN.L); UpShifts = @($uU.L); LowLowWindowMax = $g3Worst; StageFixture = $stageDir; NoiseResFixture = $noiseDir
    Capture = $cap.Root; CalibrationCaptures = @($cals | ForEach-Object { $_.Root }); Files = $files } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'fixture.json') -Encoding utf8NoBOM
[pscustomobject]@{ Directory = $out; InputBytes = $inputs.Length; WeightBytes = $weights.Count; LowLowWindowMax = ($g3Worst | Measure-Object -Maximum).Maximum }
