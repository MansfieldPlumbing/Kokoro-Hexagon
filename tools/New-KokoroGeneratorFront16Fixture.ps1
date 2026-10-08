#requires -Version 7.4
<# .SYNOPSIS
Packs the 128-channel generator front (noise_convs[1], ups[1], reflection pad, add) for Kokoro.Generator60x16Run.ps1 -Front.
.DESCRIPTION
Stock Kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec istftnet.py Generator.forward, i = 1:
  x_source = noise_res[1](noise_convs[1](har), s);  x = reflection_pad(ups[1](leaky(x)));  x = x + x_source
The DSP job runs noise_convs[1] (HMX, 64 -> 128, K 3 with the centre tap only, its result added onto a zero residual
in noise_res[1]'s units sN), noise_res[1] (tools/New-KokoroGenerator60x16Fixture.ps1 -Module noise_res), ups[1] as a
polyphase conv: output frame T = 6 q + r of the padded tensor is conv output channel 128 r + o at input frame q, taps at
frame shifts -1..1, k = 6 (1 - j) + r + 2 for tap j (T = 0 is T = 2, the reflection), three HMX calls of 256 outputs
(phase pairs 0-1, 2-3, 4-5), then R0 = sat(rU * X + rN * Xn) in the stage's residual units sR (Q14 ratios).
Inputs are quantized per channel (scales folded into the weights). Calibration: -CalibrationDirectory captures.
Outputs (new build/ directory):
  inputs.bin   har high plane, har low plane (64-channel croutons, stage tiles), ups input high, low (256-channel, 41 tiles
               of 1,301 frames)
  weights.bin  noise conv Wh, Wl (128 x 64 x 3), then per ups call Wh, Wl (256 x 256 x 3)
  tables.bin   65536 B: noise conv column tables at 0, noise residual ratios (Q15 int32) at 8192, its group 3 shifts at
               9216; ups column tables at 16384 + 12288 c; ups group 3 shifts at 53248 + 2048 c; rU, rN (Q14 int32) at
               59392, 59904
  expected-f32.bin  stock resblocks.3 input ([channel][frame]); fixture.json.
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
if ($noise.Frames -ne $frames -or $noise.Module -ne 'noise_res') { throw 'The noise_res fixture does not match the stage.' }
$sR = [double[]]@($stage.OutputScales); $sN = [double[]]@($noise.OutputScales)
$cap = Read-KokoroCapture -Directory $CaptureDirectory
$cals = @(if ($CalibrationDirectory) { foreach ($d in $CalibrationDirectory) { Read-KokoroCapture -Directory $d } } else { $cap })
$T = { param($c, [string]$n) , (Read-KokoroCaptureTensor -Capture $c -Name $n) }
$har = & $T $cap 'generator.noise_convs.1.input.0'; $xUp = & $T $cap 'generator.ups.1.input.0'
if ($har.Length -ne 22 * $frames) { throw 'har frames differ from the stage.' }
$mIn = $xUp.Length / 256; $qFrames = $mIn + 1; $qTiles = [int][math]::Ceiling($qFrames / 32)
if (6 * $mIn + 1 -ne $frames) { throw 'ups[1] input frames do not give the stage frames.' }

# Per-channel input scales from calibration (stock har and ups[1] inputs).
$chanMax = { param([string]$name, [int]$ch) $m = [double[]]::new($ch); foreach ($c in $cals) { $st = Get-KokoroChannelStats -Values (& $T $c $name) -Channels $ch; for ($i = 0; $i -lt $ch; $i++) { $m[$i] = [math]::Max($m[$i], $st.AbsMax[$i]) } }; , $m }
$sH = & $chanMax 'generator.noise_convs.1.input.0' 22; $sU = & $chanMax 'generator.ups.1.input.0' 256
for ($i = 0; $i -lt 22; $i++) { $sH[$i] = [math]::Max($sH[$i], 1e-12) * $Margin / 32767 }
for ($i = 0; $i -lt 256; $i++) { $sU[$i] = [math]::Max($sU[$i], 1e-12) * $Margin / 32767 }
$oNoise = & $chanMax 'generator.noise_convs.1.output' 128; $oUp = & $chanMax 'generator.reflection_pad.output' 128

# Two 16-bit byte planes (odd bytes) of x / s per channel, in croutons of C channels.
function New-Planes([float[]]$x, [int]$ch, [int]$fr, [double[]]$scale, [int]$cpad, [int]$tl) {
    $xp = [float[]]::new($cpad * $fr); [Array]::Copy($x, $xp, $x.Length)
    $sc = [double[]]::new($cpad); for ($i = 0; $i -lt $cpad; $i++) { $sc[$i] = if ($i -lt $ch) { $scale[$i] } else { 1.0 } }
    $u = [byte[]]::new($tl * $cpad * 64); $z = [uint16[]]::new($u.Length / 2); [Array]::Fill($z, [uint16]0x8000); [Buffer]::BlockCopy($z, 0, $u, 0, $u.Length)
    (Get-QuantizeCroutons16Kernel).Invoke($xp, $fr, $sc, $u)
    $hi = [byte[]]::new($u.Length); $lo = [byte[]]::new($u.Length)
    (Get-SplitPlanesKernel).Invoke($u, $hi, $lo)
    , @($hi, $lo)
}
$harPlanes = New-Planes $har 22 $frames $sH 64 $tiles
$xq = [float[]]::new(256 * $qFrames); for ($c = 0; $c -lt 256; $c++) { [Array]::Copy($xUp, $c * $mIn, $xq, $c * $qFrames, $mIn) }
$upPlanes = New-Planes $xq 256 $qFrames $sU 256 $qTiles

# Output units of a plane conv (as the stage fixture): finest 2^(L+8) sW holding need, weights 16-bit per channel.
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
# Column tables of a three-group plane conv with per-channel group 3 range 2^g (Kokoro.PlaneCombine.ps1 -Group3Shifts).
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
# Group 3 range per channel from the low x low windows on every sentence (inputs already divided by their scales).
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
$tables = [byte[]]::new(65536)

# noise_convs[1]: 22 -> 128, kernel 1, as K 3 with the centre tap; inputs in units of sH (folded).
$wN = & $T $cap 'generator.noise_convs.1.weight'; $bN = & $T $cap 'generator.noise_convs.1.bias'
$wNf = [float[]]::new(128 * 64 * 3); $wNmax = [double[]]::new(128)
for ($o = 0; $o -lt 128; $o++) { for ($c = 0; $c -lt 22; $c++) { $v = [double]$wN[$o * 22 + $c] * $sH[$c]; $wNf[($o * 64 + $c) * 3 + 1] = [float]$v; $wNmax[$o] = [math]::Max($wNmax[$o], [math]::Abs($v)) } }
$needN = [double[]]::new(128); for ($o = 0; $o -lt 128; $o++) { $needN[$o] = $oNoise[$o] * $Margin / 32767 }
$uN = Get-Units $wNmax $needN
$ratioN = [int[]]::new(128)
for ($o = 0; $o -lt 128; $o++) {
    if ($uN.Unit[$o] -ge $sN[$o]) {
        # noise_res's residual scale can sit below the conv's range (lowered for its turns-gain contract): take the conv
        # output in units just under sN, if its calibrated peak still fits.
        $fine = $wNmax[$o] / 32512; $target = 0.999 * $sN[$o]
        $Lo = [math]::Clamp([int][math]::Floor([math]::Log($target / (256 * $fine), 2)), 2, 15); $sw = $target / [math]::Pow(2, $Lo + 8)
        if ($sw -lt $fine -or $oNoise[$o] -gt 32767 * $target) { throw "noise conv output does not fit noise_res's residual units at c$o" }
        $uN.L[$o] = $Lo; $uN.SW[$o] = $sw; $uN.Unit[$o] = $target
    }
    $ratioN[$o] = [int](Get-Even ($uN.Unit[$o] / $sN[$o] * 32768))
}
$whN = [byte[]]::new(24576); $wlN = [byte[]]::new(24576); $shN = [long[]]::new(128); $slN = [long[]]::new(128)
if ((Get-PackWeightPlanesShapedKernel).Invoke($wNf, 128, 64, 3, $uN.SW, $whN, $wlN, $shN, $slN) -ne 0) { throw 'noise conv weight overflow' }
$bqN = [long[]]::new(128); for ($o = 0; $o -lt 128; $o++) { $bqN[$o] = [long](Get-Even ($bN[$o] / (256 * $uN.SW[$o]))) }
$harIn = { param($c) $h = & $T $c 'generator.noise_convs.1.input.0'; $f = $h.Length / 22; $x = [float[]]::new(64 * $f); for ($i = 0; $i -lt 22; $i++) { for ($t = 0; $t -lt $f; $t++) { $x[$i * $f + $t] = [float]($h[$i * $f + $t] / $sH[$i]) } }; , $x }
$g3N = Get-Group3 $harIn $wNf 64 128 $uN.SW $uN.L
Write-Tables $tables 0 $uN.L $shN $slN $bqN $g3N.G 9216
for ($o = 0; $o -lt 128; $o++) { [BitConverter]::GetBytes($ratioN[$o]).CopyTo($tables, 8192 + 4 * $o) }

# ups[1]: polyphase, units per output channel shared by the six phases.
$wU = & $T $cap 'generator.ups.1.weight'; $bU = & $T $cap 'generator.ups.1.bias'          # [256][128][12]
$wUmax = [double[]]::new(128)
for ($c = 0; $c -lt 256; $c++) { for ($o = 0; $o -lt 128; $o++) { for ($k = 0; $k -lt 12; $k++) { $wUmax[$o] = [math]::Max($wUmax[$o], [math]::Abs([double]$wU[($c * 128 + $o) * 12 + $k] * $sU[$c])) } } }
$needU = [double[]]::new(128); for ($o = 0; $o -lt 128; $o++) { $needU[$o] = $oUp[$o] * $Margin / 32767 }
$uU = Get-Units $wUmax $needU
$weights = [System.Collections.Generic.List[byte]]::new(); $weights.AddRange($whN); $weights.AddRange($wlN)
$upIn = { param($c) $h = & $T $c 'generator.ups.1.input.0'; $m = $h.Length / 256; $f = $m + 1; $x = [float[]]::new(256 * $f); for ($i = 0; $i -lt 256; $i++) { for ($t = 0; $t -lt $m; $t++) { $x[$i * $f + $t] = [float]($h[$i * $m + $t] / $sU[$i]) } }; , $x }
$g3Worst = @($g3N.Worst)
for ($call = 0; $call -lt 3; $call++) {
    $wc = [float[]]::new(256 * 256 * 3); $L2 = [int[]]::new(256); $sw2 = [double[]]::new(256); $bq2 = [long[]]::new(256)
    for ($h = 0; $h -lt 2; $h++) {
        $r = 2 * $call + $h
        for ($o = 0; $o -lt 128; $o++) {
            $oc = 128 * $h + $o; $L2[$oc] = $uU.L[$o]; $sw2[$oc] = $uU.SW[$o]
            for ($j = 0; $j -lt 3; $j++) { $k = 6 * (1 - $j) + $r + 2; if ($k -lt 0 -or $k -ge 12) { continue }
                for ($c = 0; $c -lt 256; $c++) { $wc[($oc * 256 + $c) * 3 + $j] = [float]([double]$wU[($c * 128 + $o) * 12 + $k] * $sU[$c]) } }
        }
    }
    $wh2 = [byte[]]::new(196608); $wl2 = [byte[]]::new(196608); $sh2 = [long[]]::new(256); $sl2 = [long[]]::new(256)
    if ((Get-PackWeightPlanesShapedKernel).Invoke($wc, 256, 256, 3, $sw2, $wh2, $wl2, $sh2, $sl2) -ne 0) { throw "ups weight overflow (call $call)" }
    for ($oc = 0; $oc -lt 256; $oc++) { $bq2[$oc] = [long](Get-Even ($bU[$oc % 128] / (256 * $sw2[$oc]))) }
    $g3U = Get-Group3 $upIn $wc 256 256 $sw2 $L2; $g3Worst += $g3U.Worst
    Write-Tables $tables (16384 + 12288 * $call) $L2 $sh2 $sl2 $bq2 $g3U.G (53248 + 2048 * $call)
    $weights.AddRange($wh2); $weights.AddRange($wl2)
}
# Final add in the stage's units: R0 = sat(rU X + rN Xn), Q14 (ratios below 2).
for ($o = 0; $o -lt 128; $o++) {
    $rU = Get-Even ($uU.Unit[$o] / $sR[$o] * 16384); $rN = Get-Even ($sN[$o] / $sR[$o] * 16384)
    if ($rU -gt 32767 -or $rN -gt 32767 -or $rU -lt 1 -or $rN -lt 1) { throw "Front add ratio out of Q14 range at c$o ($rU, $rN)" }
    [BitConverter]::GetBytes([int]$rU).CopyTo($tables, 59392 + 4 * $o); [BitConverter]::GetBytes([int]$rN).CopyTo($tables, 59904 + 4 * $o)
}

[void][IO.Directory]::CreateDirectory($out)
$inputs = [byte[]]::new(2 * $harPlanes[0].Length + 2 * $upPlanes[0].Length); $at = 0
foreach ($b in @($harPlanes[0], $harPlanes[1], $upPlanes[0], $upPlanes[1])) { [Array]::Copy($b, 0, $inputs, $at, $b.Length); $at += $b.Length }
$expected = & $T $cap 'generator.resblocks.3.input.0'; $eb = [byte[]]::new(4 * $expected.Length); [Buffer]::BlockCopy($expected, 0, $eb, 0, $eb.Length)
foreach ($f in @(@('inputs.bin', $inputs), @('weights.bin', $weights.ToArray()), @('tables.bin', $tables), @('expected-f32.bin', $eb))) { [IO.File]::WriteAllBytes((Join-Path $out $f[0]), $f[1]) }
$files = @(Get-ChildItem -LiteralPath $out -File | ForEach-Object { [ordered]@{ Name = $_.Name; Bytes = $_.Length; SHA256 = (Get-FileHash $_.FullName).Hash } })
[ordered]@{ Graph = 'GeneratorFront16'; Frames = $frames; Tiles = $tiles; UpFrames = $qFrames; UpTiles = $qTiles; OutputScales = $sR; Margin = $Margin
    NoiseConvShifts = @($uN.L); UpShifts = @($uU.L); LowLowWindowMax = $g3Worst; StageFixture = $stageDir; NoiseResFixture = $noiseDir
    Capture = $cap.Root; CalibrationCaptures = @($cals | ForEach-Object { $_.Root }); Files = $files } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'fixture.json') -Encoding utf8NoBOM
[pscustomobject]@{ Directory = $out; InputBytes = $inputs.Length; WeightBytes = $weights.Count; LowLowWindowMax = ($g3Worst -join ','); NoiseShifts = (($uN.L | Measure-Object -Minimum -Maximum) | % { "$($_.Minimum)-$($_.Maximum)" }); UpShifts = (($uU.L | Measure-Object -Minimum -Maximum) | % { "$($_.Minimum)-$($_.Maximum)" }) }
