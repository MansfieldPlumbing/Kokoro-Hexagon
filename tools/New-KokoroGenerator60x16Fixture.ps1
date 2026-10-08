#requires -Version 7.4
<# .SYNOPSIS
Packs the 16-bit generator 60x stage (resblocks.3-5 and their mean) from verified stock captures.
.DESCRIPTION
Design: docs/generator60x-16bit-design.md. Build-time arithmetic only; all model math at run time is
emitted DSP code. Scales (residual, conv input, conv output) come from -CalibrationDirectory captures, the
evaluated sentence's captures when none are given; the stage input, voice style, frame count and expected
output come from -CaptureDirectory. Either is three per-block captures (resblocks.3, .4, .5) or one
whole-generator capture. Outputs, in a new build/ directory:
  activations.bin  stage input R0, biased u16 (x + 32768) in native croutons, padded rows 0x8000
  weights.bin      per branch b, stage s: Wh then Wl, HMX order (Kokoro.HmxConv.ps1), 32768*K bytes
  tables.bin       per (b, s) a 16384-byte record: phase-turns parameters (32 B per channel: Ka int64,
                   Mb int32, S int32, epsD u64) at 0; HMX column tables (4 output blocks x 3 groups x
                   512 B, Kokoro.HmxConvPlanes.ps1) at 4096; residual ratios (int32 Q15 per channel,
                   odd s) at 10240
  expected-f32.bin stock mean of the three blocks' outputs, [channel][frame] float32
  fixture.json     scales, shifts and provenance
Conv arithmetic: x (16-bit, units sX) = 256 (h - 128) + l; Wq = 256 Wh + Wl (units sW_c, |Wq| <= 32512);
sum x Wq = 65536 A1 + 256 A2 + A3, so conv = 256 sX sW_c (256 A1 + A2 + A3 / 256). Group g leaves HMX as a
16-bit window at shift L_g (L1 = L - 8, L2 = L, L3 = L + 8); their sum v is the conv in units 2^(L + 8) sX sW_c. Group 3's
window (low x low, below 2^7 in these units) leaves through its low plane only, which the consumer sign-extends: its high
plane would need table exponent 8 - L (< 1 for L > 7). Each group's table bias rounds to nearest (half its window LSB).
Stock conv bias is carried in group 2's table bias.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]] $CaptureDirectory,
    [string[]] $CalibrationDirectory,
    [Parameter(Mandatory)][string] $OutputDirectory,
    [ValidateRange(1.0, 4.0)][double] $Margin = 1.25,
    # Phase-turns fraction bits QT of Kokoro.AdaInSnakeTurns.ps1 -TurnsBits (Kokoro.Generator60x16Run.ps1 emits 22).
    [ValidateSet(22, 24)][int] $TurnsBits = 22,
    # The blocks: resblocks 3, 4, 5 (then their mean, the stage), or one block alone, e.g. -Module noise_res -Blocks 1
    # (its output is the result). Kokoro.Generator60x16Run.ps1 -Kernels must list the same kernel sizes.
    [ValidateSet('resblocks', 'noise_res')][string] $Module = 'resblocks',
    [ValidateCount(1, 3)][int[]] $Blocks = @(3, 4, 5)
)
$ErrorActionPreference = 'Stop'
$clock = [Diagnostics.Stopwatch]::StartNew(); $timings = [ordered]@{}; $lap = { param([string]$n) $timings[$n] = [math]::Round($clock.Elapsed.TotalSeconds, 2); $clock.Restart() }
$build = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build')) + [IO.Path]::DirectorySeparatorChar
$out = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $out.StartsWith($build, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)) { throw 'Use a new directory in build/.' }

Import-Module (Join-Path $PSScriptRoot 'Kokoro.CaptureMath.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Kokoro.CaptureKernels.psm1') -Force
# One sentence: one per-block capture per block, or one whole-generator capture viewed as those blocks.
$blockCount = $Blocks.Count
function Read-StageCaptures([string[]]$Directories) {
    if ($Directories.Count -ne 1 -and $Directories.Count -ne $blockCount) { throw 'Give one capture per block in order, or one whole-generator capture.' }
    $set = @(for ($b = 0; $b -lt $blockCount; $b++) {
        $cap = Read-KokoroResBlockCapture -Directory $Directories[[math]::Min($b, $Directories.Count - 1)] -Block $Blocks[$b] -Module $Module
        if (-not $cap.Root.StartsWith($build, [StringComparison]::OrdinalIgnoreCase)) { throw 'Captures must be in build/.' }
        $cap
    })
    foreach ($c in $set) { if ($c.Json.tensors.input.sha256 -cne $set[0].Json.tensors.input.sha256) { throw 'The blocks must share one stage input.' } }
    , $set
}
$caps = Read-StageCaptures $CaptureDirectory
# Calibration sentences (with none given, the evaluated sentence).
$cals = @(if ($CalibrationDirectory) { foreach ($d in $CalibrationDirectory) { , (Read-StageCaptures @($d)) } } else { , $caps })
$holdout = [bool]$CalibrationDirectory
if ($holdout) { foreach ($set in $cals) { if ($set[0].Json.tensors.input.sha256 -ceq $caps[0].Json.tensors.input.sha256) { throw 'A calibration capture is the evaluated sentence.' } } }

function Read-Tensor([hashtable]$Cap, [string]$Name) { , (Read-KokoroCaptureTensor -Capture $Cap -Name $Name) }
function Get-AbsMax([float[]]$v) { Get-KokoroAbsMax $v }
function Get-ChannelAbsMax([float[]]$v, [int]$frames) { , (Get-KokoroChannelStats -Values $v -Channels 128).AbsMax }function Get-Even([double]$x) { [math]::Round($x, [MidpointRounding]::ToEven) }

$shape = $caps[0].Json.tensors.input.shape
if ($shape.Count -ne 3 -or $shape[0] -ne 1 -or $shape[1] -ne 128) { throw 'Expected [1,128,T] stage input.' }
$frames = [int]$shape[2]; $tiles = [int][math]::Ceiling($frames / 32); $tensorBytes = $tiles * 8192
$N = $frames

# Residual stream scales: one per channel (shared by the three branches and the mean), from every
# captured R (block input, the inputs of stages 2 and 4, block output) of all three blocks. A single
# per-tensor scale leaves quiet channels a few hundred LSB, and the per-LSB phase gain K then exceeds
# the int32 contract of Kokoro.AdaInTurnsCoefficients.ps1.
$sR = [double[]]::new(128)
foreach ($set in $cals) { foreach ($cap in $set) { foreach ($name in 'input', 'stage2.input', 'stage4.input', 'output') { $m = Get-ChannelAbsMax (Read-Tensor $cap $name) 0; for ($c = 0; $c -lt 128; $c++) { $sR[$c] = [math]::Max($sR[$c], $m[$c]) } } } }
# The phase-turns gain K = Ka * sR_c / sigma_c (sigma_c: standard deviation of the AdaIN input) must stay
# below 2^31. Where the margin would exceed that, sR_c is lowered to keep K <= 0.9 * 2^31 across every
# branch and R-input stage, but never below the captured peak (no clipping on the calibration capture).
$rBound = [double[]]::new(128); for ($c = 0; $c -lt 128; $c++) { $rBound[$c] = [double]::PositiveInfinity }
foreach ($set in $cals) { for ($bb = 0; $bb -lt $blockCount; $bb++) {
    $cap = $set[$bb]; $styleB = Read-Tensor $cap 'style'
    foreach ($ss in 0, 2, 4) {
        $pp = "stage$ss."
        $fcw = Read-Tensor $cap ($pp + 'adain.fc.weight'); $fcb = Read-Tensor $cap ($pp + 'adain.fc.bias'); $nw = Read-Tensor $cap ($pp + 'adain.norm.weight'); $alpha = Read-Tensor $cap ($pp + 'alpha')
        $xinStats = Get-KokoroChannelStats -Values (Read-Tensor $cap ($pp + 'input')) -Channels 128
        for ($c = 0; $c -lt 128; $c++) {
            $g = [double]$fcb[$c]; for ($j = 0; $j -lt 128; $j++) { $g += [double]$fcw[$c * 128 + $j] * $styleB[$j] }
            $kaAbs = [math]::Abs((1 + $g) * $nw[$c] * $alpha[$c] * [math]::Pow(2, $TurnsBits + 15) / [math]::PI)
            $sigma = [math]::Sqrt([math]::Max($xinStats.Variance[$c], 1e-30))
            if ($kaAbs -gt 0) { $rBound[$c] = [math]::Min($rBound[$c], 0.9 * [math]::Pow(2, 31) * $sigma / $kaAbs) }
        }
    }
} }
& $lap 'ResidualScales'
$rLowered = 0
for ($c = 0; $c -lt 128; $c++) {
    if ($sR[$c] -le 0) { throw 'Zero residual channel.' }
    $peak = $sR[$c] / 32767; $scale = [math]::Min($peak * $Margin, $rBound[$c])
    if ($scale -lt $peak) { throw "Residual channel $c cannot hold its peak within the K contract." }
    if ($scale -lt $peak * $Margin) { $rLowered++ }
    $sR[$c] = $scale
}

# Native crouton halfword index of (frame t, channel c): tile t/32, block c/32 (1024 halfwords each),
# 64 * floor((t%32)/2) + 2 * (c%32) + t%2 (Kokoro.AdaInSnakeTurns.ps1 layout notes).

$input = Read-Tensor $caps[0] 'input'
$act = [byte[]]::new($tensorBytes)
$zero16 = [uint16[]]::new($tensorBytes / 2); [Array]::Fill($zero16, [uint16]0x8000); [Buffer]::BlockCopy($zero16, 0, $act, 0, $tensorBytes)   # x = 0 everywhere
(Get-QuantizeCroutons16Kernel).Invoke($input, $frames, $sR, $act)

& $lap 'StageInput'
$kernels = @(foreach ($c in $caps) { [int]$c.Json.tensors['stage0.weight'].shape[2] })
$weightTotal = 0L; foreach ($kk in $kernels) { $weightTotal += 6L * 32768 * $kk }
$wideResidual = 0
$stageOut = [double[]]::new(6 * $blockCount * 128)   # per (b, s): units of the stage's output (C or R) per channel
$weights = [byte[]]::new($weightTotal); $tables = [byte[]]::new(6 * $blockCount * 16384)
$records = [Collections.Generic.List[object]]::new(); $weightAt = 0L
for ($b = 0; $b -lt $blockCount; $b++) {
    $cap = $caps[$b]; $K = $kernels[$b]; $style = Read-Tensor $cap 'style'
    $inScale = [double[]]::new(128); for ($c = 0; $c -lt 128; $c++) { $inScale[$c] = $sR[$c] }
    for ($s = 0; $s -lt 6; $s++) {
        $rec = ($b * 6 + $s) * 16384
        $p = "stage$s."
        # AdaIN style affine (stock AdaIN1d: (1 + gamma) * norm(x) + beta, norm with affine weight and bias).
        $fcw = Read-Tensor $cap ($p + 'adain.fc.weight'); $fcb = Read-Tensor $cap ($p + 'adain.fc.bias')
        $nw = Read-Tensor $cap ($p + 'adain.norm.weight'); $nb = Read-Tensor $cap ($p + 'adain.norm.bias'); $alpha = Read-Tensor $cap ($p + 'alpha')
        $h = [double[]]::new(256)
        for ($i = 0; $i -lt 256; $i++) { $h[$i] = $fcb[$i]; for ($j = 0; $j -lt 128; $j++) { $h[$i] += [double]$fcw[$i * 128 + $j] * $style[$j] } }
        $sX = 0.0; foreach ($set in $cals) { $sX = [math]::Max($sX, (Get-AbsMax (Read-Tensor $set[$b] ($p + 'snake')))) }; $sX *= $Margin / 32767
        # Snake output multiplier S = (pi / alpha) 2^(31 - QT) / sX must fit int32. A channel with tiny alpha (Snake near
        # the identity) takes a coarser conv-input scale sXc, folded into the conv weights for that input channel.
        $sXc = [double[]]::new(128); $raisedInputs = 0
        for ($c = 0; $c -lt 128; $c++) {
            if ($alpha[$c] -eq 0) { throw 'Snake alpha is zero.' }
            $sXc[$c] = $sX; $lim = [math]::Abs(([math]::PI / $alpha[$c]) * [math]::Pow(2, 31 - $TurnsBits)) / (0.9 * [math]::Pow(2, 31))
            if ($lim -gt $sX) { $sXc[$c] = $lim; $raisedInputs++ }
        }
        # AdaIN input statistics for the K-range check (Kokoro.AdaInTurnsCoefficients.ps1 contract).
        $adainStats = Get-KokoroChannelStats -Values (Read-Tensor $cap ($p + 'input')) -Channels 128; $kMax = 0.0
        for ($c = 0; $c -lt 128; $c++) {
            $gainA = (1 + $h[$c]) * $nw[$c]; $offsetB = (1 + $h[$c]) * $nb[$c] + $h[128 + $c]; $al = [double]$alpha[$c]
            if ($al -eq 0) { throw 'Snake alpha is zero.' }
            $Ka = [long](Get-Even ($gainA * $al * [math]::Pow(2, $TurnsBits + 15) / [math]::PI))
            $Mb = Get-Even ($al * $offsetB * [math]::Pow(2, $TurnsBits) / [math]::PI)
            # Stock alpha may be negative (sin^2(a y) / a); S then is negative, a signed Q31 multiplier.
            $outS = Get-Even (([math]::PI / $al) * [math]::Pow(2, 31 - $TurnsBits) / $sXc[$c])
            $epsD = Get-Even (1e-5 * $N * $N / ($inScale[$c] * $inScale[$c]))
            $var = $adainStats.Variance[$c] / ($inScale[$c] * $inScale[$c]) + $epsD / ($N * $N)
            $kMax = [math]::Max($kMax, [math]::Abs($Ka) / [math]::Sqrt($var))
            if ([math]::Abs($Mb) -gt [int]::MaxValue -or $outS -eq 0 -or [math]::Abs($outS) -gt [int]::MaxValue -or $epsD -lt 1 -or $epsD -gt [uint64]::MaxValue) { throw "Turns parameter range b$b s$s c$c" }
            [BitConverter]::GetBytes($Ka).CopyTo($tables, $rec + 32 * $c)
            [BitConverter]::GetBytes([int]$Mb).CopyTo($tables, $rec + 32 * $c + 8)
            [BitConverter]::GetBytes([int]$outS).CopyTo($tables, $rec + 32 * $c + 12)
            [BitConverter]::GetBytes([uint64]$epsD).CopyTo($tables, $rec + 32 * $c + 16)
        }
        # Conv: per-channel weight scale and output shift.
        $W = Read-Tensor $cap ($p + 'weight'); $bias = Read-Tensor $cap ($p + 'bias')
        if ($raisedInputs) {
            $Wc = [float[]]::new($W.Length); $per = $W.Length / 128 / 128
            for ($o = 0; $o -lt 128; $o++) { for ($i = 0; $i -lt 128; $i++) { $f = $sXc[$i] / $sX; for ($kq = 0; $kq -lt $per; $kq++) { $at = ($o * 128 + $i) * $per + $kq; $Wc[$at] = [float]($W[$at] * $f) } } }
            $W = $Wc
        }
        $outMax = [double[]]::new(128)
        foreach ($set in $cals) { $m = Get-ChannelAbsMax (Read-Tensor $set[$b] ($p + 'conv')) 0; for ($o = 0; $o -lt 128; $o++) { $outMax[$o] = [math]::Max($outMax[$o], $m[$o]) } }
        $residual = ($s % 2) -eq 1
        $wAbsMax = (Get-KokoroChannelStats -Values $W -Channels 128).AbsMax
        $L = [int[]]::new(128); $sW = [double[]]::new(128); $vUnit = [double[]]::new(128)
        for ($o = 0; $o -lt 128; $o++) {
            $wmax = $wAbsMax[$o]
            if ($wmax -eq 0) { throw 'Zero weight channel.' }
            $fine = $wmax / 32512
            # Output units from the conv's own range: the finest 2^L sX sW that holds outMax with margin, with
            # the finest weight scale the shift range (2..15, the HMX table exponent) allows. For conv2 the
            # Q15 ratio vUnit / sR (below one) converts O into R's units in the residual add.
            $need = [math]::Max($outMax[$o] * $Margin, 1e-30) / 32767
            $Lo = [int][math]::Ceiling([math]::Log($need / (256 * $sX * $fine), 2)); $Lo = [math]::Clamp($Lo, 2, 15)
            $scaleW = [math]::Max($fine, $need / ([math]::Pow(2, $Lo + 8) * $sX))
            if ($residual -and [math]::Pow(2, $Lo + 8) * $sX * $scaleW -ge $sR[$o]) {
                # O's range exceeds R's for this channel (they cancel in the sum): take O in R's units
                # (ratio just below one), using R's headroom; fail only if O would clip on this capture.
                $target = 0.999 * $sR[$o]
                $Lo = [math]::Clamp([int][math]::Floor([math]::Log($target / (256 * $sX * $fine), 2)), 2, 15)
                $scaleW = $target / ([math]::Pow(2, $Lo + 8) * $sX)
                if ($scaleW -lt $fine -or $outMax[$o] -gt 32767 * $target) { throw "Residual conv output does not fit R's units at b$b s$s c$o" }
                $wideResidual++
            }
            $L[$o] = $Lo; $sW[$o] = $scaleW; $vUnit[$o] = [math]::Pow(2, $Lo + 8) * $sX * $scaleW
        }
        # Weight planes Wh = floor((Wq + 128) / 256), Wl = Wq - 256 Wh, packed as Kokoro.HmxConv.ps1 (Kokoro.CaptureKernels.psm1).
        $wh = [byte[]]::new(32768 * $K / 2); $wl = [byte[]]::new(32768 * $K / 2)
        $sumH = [long[]]::new(128); $sumL = [long[]]::new(128)
        if ((Get-PackWeightPlanesKernel).Invoke($W, $K, $sW, $wh, $wl, $sumH, $sumL) -ne 0) { throw "Weight plane overflow b$b s$s" }
        [Buffer]::BlockCopy($wh, 0, $weights, $weightAt, $wh.Length); [Buffer]::BlockCopy($wl, 0, $weights, $weightAt + $wh.Length, $wl.Length)
        $weightAt += $wh.Length + $wl.Length
        # Group 3 is read through its low plane alone: its window must stay a signed byte on every sentence here.
        # A channel whose products cancel to a small output (small L) can exceed that: its group 3 window then sits at
        # shift L + 8 + g (range +-127 * 2^g, g <= 6), sign-extended by 8 - g in Kokoro.PlaneCombine.ps1 -Group3Shifts.
        $dil = $(if ($residual) { 1 } else { @(1, 3, 5)[[int]($s / 2)] })
        $scanLowLow = {
            $worst = [int[]]::new(128)
            foreach ($set in @($cals) + , $caps) {
                $xs = Read-Tensor $set[$b] ($p + 'snake')
                if ($raisedInputs) { $len = $xs.Length / 128; $xc = [float[]]::new($xs.Length); for ($i = 0; $i -lt 128; $i++) { $f = $sX / $sXc[$i]; for ($tt = 0; $tt -lt $len; $tt++) { $xc[$i * $len + $tt] = [float]($xs[$i * $len + $tt] * $f) } }; $xs = $xc }
                $perO = [int[]]::new(128); [void](Get-LowLowWindowKernel).Invoke($xs, $xs.Length / 128, $sX, $W, $K, $dil, $sW, $L, $perO)
                for ($o = 0; $o -lt 128; $o++) { $worst[$o] = [math]::Max($worst[$o], $perO[$o]) }
            }
            , $worst
        }
        $worstO = & $scanLowLow
        $g3 = [int[]]::new(128); $widened = 0
        for ($o = 0; $o -lt 128; $o++) {
            while ($worstO[$o] -gt 100 * [math]::Pow(2, $g3[$o]) -and $g3[$o] -lt 6) { $g3[$o]++ }
            if ($g3[$o]) { $widened++ }
            if ($worstO[$o] -gt 127 * [math]::Pow(2, $g3[$o]) -or $L[$o] + $g3[$o] -gt 15) { throw "Low x low window at b$b s$s c$o ($($worstO[$o])) exceeds the widest group 3 range" }
        }
        $lowLow = ($worstO | Measure-Object -Maximum).Maximum
        # Column tables: per output block ob, planes p = 0..5 (group g = p/2; high, low), 64 words each:
        # 32 scale words (fp16 exponent field: 2^(1 - Lg) high, 2^(9 - Lg) low, with the HMX 1/512),
        # then 32 bias words: the window bias 2^(Lg + 15) (32768 window LSB; none for group 3, read through
        # its low plane only) plus half a window LSB, 2^(Lg - 1), where that is a whole accumulator unit.
        # Group 3's unused high plane gets exponent 2^(1 - L) (in range; its bytes are not read).
        for ($o = 0; $o -lt 128; $o++) {
            $ob = [int][math]::Floor($o / 32); $cc = $o % 32
            $Lg = @(($L[$o] - 8), $L[$o], ($L[$o] + 8 + $g3[$o]))
            $sh3 = [uint32](8 - $g3[$o]); [BitConverter]::GetBytes($sh3 -bor ($sh3 -shl 16)).CopyTo($tables, $rec + 11264 + 128 * $ob + 4 * $cc)
            $half = foreach ($x in $Lg) { if ($x -ge 1) { [long][math]::Pow(2, $x - 1) } else { 0L } }
            $Bq = Get-Even ($bias[$o] / (256 * $sX * $sW[$o]))   # in A2 units: 256 sX sW_c
            $biasG = @((-128L * $sumH[$o] + [math]::Pow(2, $Lg[0] + 15) + $half[0]), (-128L * $sumL[$o] + $Bq + [math]::Pow(2, $Lg[1] + 15) + $half[1]), $half[2])
            for ($pl = 0; $pl -lt 6; $pl++) {
                $g = [int][math]::Floor($pl / 2); $e = $(if ($pl % 2) { 9 } else { 1 }) - $(if ($pl -eq 4) { $L[$o] } else { $Lg[$g] }) + 15
                if ($e -lt 1 -or $e -gt 30) { throw "Table exponent out of range b$b s$s c$o" }
                if ($biasG[$g] -lt [int]::MinValue -or $biasG[$g] -gt [int]::MaxValue) { throw 'Table bias overflow.' }
                $at = $rec + 4096 + (3 * $ob * 2 + $pl) * 256
                [BitConverter]::GetBytes([uint32]($e -shl 10)).CopyTo($tables, $at + 4 * $cc)
                [BitConverter]::GetBytes([int]$biasG[$g]).CopyTo($tables, $at + 128 + 4 * $cc)
            }
            if ($residual) {
                $ratio = [int](Get-Even ($vUnit[$o] / $sR[$o] * 32768))
                if ($ratio -lt 1 -or $ratio -gt 32767) { throw 'Residual ratio out of Q15 range.' }
                [BitConverter]::GetBytes($ratio).CopyTo($tables, $rec + 10240 + 4 * $o)
            }
        }
        $records.Add([ordered]@{ Branch = $b; Stage = $s; Kernel = $K; Dilation = $(if ($residual) { 1 } else { @(1, 3, 5)[[int]($s / 2)] }); InputScaleMax = ($inScale | Measure-Object -Maximum).Maximum; ConvInputScale = $sX; ShiftMin = ($L | Measure-Object -Minimum).Minimum; ShiftMax = ($L | Measure-Object -Maximum).Maximum; TurnsGainMax = $kMax; LowLowWindowMax = $lowLow; RaisedInputChannels = $raisedInputs; WidenedGroup3Channels = $widened; WeightBitsMin = [math]::Round((0..127 | ForEach-Object { [math]::Log($wAbsMax[$_] / $sW[$_], 2) + 1 } | Measure-Object -Minimum).Minimum, 2) })
        if ($kMax -ge [math]::Pow(2, 31)) { throw "Turns gain K exceeds the coefficients contract at b$b s$s ($kMax)" }
        # The next stage's AdaIN input: C (per-channel units) after conv1, R after conv2.
        for ($c = 0; $c -lt 128; $c++) { $inScale[$c] = $(if ($residual) { $sR[$c] } else { $vUnit[$c] }); $stageOut[($b * 6 + $s) * 128 + $c] = $inScale[$c] }
    }
    & $lap "Branch$b"
}

# Stock mean of the three blocks.
if ($blockCount -eq 3) { $o3 = Read-Tensor $caps[0] 'output'; $o4 = Read-Tensor $caps[1] 'output'; $o5 = Read-Tensor $caps[2] 'output'; $mean = [float[]]::new($o3.Length); (Get-Mean3Kernel).Invoke($o3, $o4, $o5, $mean) }
elseif ($blockCount -eq 1) { $mean = Read-Tensor $caps[0] 'output' } else { throw 'Two blocks have no stock combination here.' }
$meanBytes = [byte[]]::new(4 * $mean.Length); [Buffer]::BlockCopy($mean, 0, $meanBytes, 0, $meanBytes.Length)

[void][IO.Directory]::CreateDirectory($out)
$stageOutBytes = [byte[]]::new(8 * $stageOut.Length); [Buffer]::BlockCopy($stageOut, 0, $stageOutBytes, 0, $stageOutBytes.Length)
foreach ($f in @(@('stage-output-scales.bin', $stageOutBytes), @('activations.bin', $act), @('weights.bin', $weights), @('tables.bin', $tables), @('expected-f32.bin', $meanBytes))) { [IO.File]::WriteAllBytes((Join-Path $out $f[0]), $f[1]) }
$files = @(Get-ChildItem -LiteralPath $out -File | ForEach-Object { [ordered]@{ Name = $_.Name; Bytes = $_.Length; SHA256 = (Get-FileHash $_.FullName).Hash } })
[ordered]@{
    Graph = 'Generator60x16'; Module = $Module; Blocks = $Blocks; Kernels = $kernels; Frames = $frames; Tiles = $tiles; OutputScales = $sR; Margin = $Margin; ResidualChannelsBelowMargin = $rLowered
    Calibration = $(if ($holdout) { 'holdout: scales from the calibration captures only' } else { 'scales from the evaluated captures' })
    CalibrationCaptures = @($cals | ForEach-Object { [ordered]@{ Directory = $_[0].Root; InputSHA256 = $_[0].Json.tensors.input.sha256 } })
    TurnsBits = $TurnsBits
    LowLowGroup = 'combined: low plane at shift L + 8, sign-extended'
    Captures = @($caps | ForEach-Object { [ordered]@{ Directory = $_.Root; Block = $_.Json.block; CaptureSHA256 = (Get-FileHash (Join-Path $_.Root 'capture.json')).Hash } })
    Stages = $records.ToArray(); Files = $files
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $out 'fixture.json') -Encoding utf8NoBOM
& $lap 'MeanAndWrite'
[pscustomobject]@{ Timings = [pscustomobject]$timings; ResidualChannelsInRUnits = $wideResidual; Directory = $out; ResidualChannelsBelowMargin = $rLowered; Frames = $frames; Tiles = $tiles; ResidualScaleMax = ($sR | Measure-Object -Maximum).Maximum; ResidualScaleMin = ($sR | Measure-Object -Minimum).Minimum; WeightBytes = $weights.Length }
