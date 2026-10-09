#requires -Version 7.4
<# .SYNOPSIS
Packs the stock decoder front for src/emit/Kokoro.DecoderRun16.ps1 (docs/decoder-design.md) from a stock decoder capture.
.DESCRIPTION
Stock Kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec istftnet.py Decoder.forward up to the generator. Weights W8 per output
channel (one plane, absmax / 127) of the folded checkpoint tensors, per input LSB of the tensor each conv reads: conv1 and
conv2 read AdaIN + LeakyReLU windows (one scale per conv input), the shortcut conv1x1 and asr_res read stored tensors with
per-channel scales. Each conv's output unit is sW_o * 2^L_o; L from the calibration peak of the stock conv output (Margin),
and for the shortcut and conv2 (added into the block output) at most what keeps the Q15 ratio unit / (sOut sqrt 2) below 1.
AdaIN style terms are folded at voice load (fc(s), norm affine) into per-channel records for
New-KokoroAdaInAffineCoefficientsLoopSteps; eps N^2 / s^2 uses the group's frame count. Scales come from -CalibrationDirectory
captures (other sentences); the decoder output uses the generator front fixture's DecoderScales so the job chains.
Outputs (new build/ directory): activations.bin (asr croutons, F0 and N curves), weights.bin, tables.bin, expected-*.bin
(stock decoder output and block outputs, float32 [channel][frame]), fixture.json.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $CaptureDirectory,
    [Parameter(Mandatory)][string[]] $CalibrationDirectory,
    # tools/New-KokoroGeneratorFront10x16Fixture.ps1 output: its DecoderScales are the decoder output's units.
    [Parameter(Mandatory)][string] $FrontFixture,
    [Parameter(Mandatory)][string] $OutputDirectory,
    [ValidateRange(1.0, 4.0)][double] $Margin = 1.25
)
$ErrorActionPreference = 'Stop'
$build = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build')) + [IO.Path]::DirectorySeparatorChar
$out = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $out.StartsWith($build, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)) { throw 'Use a new directory in build/.' }
Import-Module (Join-Path $PSScriptRoot 'Kokoro.CaptureMath.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Kokoro.CaptureKernels.psm1') -Force
. (Join-Path $PSScriptRoot '../src/emit/Kokoro.DecoderRun16.ps1')
function Get-Even([double]$x) { [math]::Round($x, [MidpointRounding]::ToEven) }

$cap = Read-KokoroCapture -Directory $CaptureDirectory
$cals = @(foreach ($d in $CalibrationDirectory) { Read-KokoroCapture -Directory $d })
$read = { param($c, [string]$n) , (Read-KokoroCaptureTensor -Capture $c -Name "decoder.$n") }
$front = Get-Content -LiteralPath (Join-Path ([IO.Path]::GetFullPath($FrontFixture)) 'fixture.json') -Raw | ConvertFrom-Json
$sD = [double[]]@($front.DecoderScales); if ($sD.Count -ne 512) { throw 'Expected 512 decoder scales.' }
$asr = & $read $cap 'input.0'; $F = $asr.Length / 512
$L = Get-KokoroDecoder16Layout -Frames $F
$T = $L.Tiles; $T2 = $L.Tiles2
# Per-channel calibration peak of a [channel][frame] tensor over the calibration captures.
$peak = { param([string]$name, [int]$ch) $m = [double[]]::new($ch); foreach ($c in $cals) { $st = Get-KokoroChannelStats -Values (& $read $c $name) -Channels $ch; for ($i = 0; $i -lt $ch; $i++) { $m[$i] = [math]::Max($m[$i], $st.AbsMax[$i]) } }; , $m }
$scalar = { param([string]$name) $m = 0.0; foreach ($c in $cals) { $m = [math]::Max($m, (Get-KokoroAbsMax -Values (& $read $c $name))) }; [math]::Max($m, 1e-12) * $Margin / 32767 }
$perChannel = { param([string]$name, [int]$ch) $m = & $peak $name $ch; for ($i = 0; $i -lt $ch; $i++) { $m[$i] = [math]::Max($m[$i], 1e-12) * $Margin / 32767 }; , $m }
$report = [ordered]@{}

# Input scales: asr per channel, F0 / N curves (int32, 2^24 at the calibration peak), F0_conv / N_conv outputs.
$sAsr = & $perChannel 'input.0' 512
$curveScale = @{}; foreach ($n in 'input.1', 'input.2') { $m = 0.0; foreach ($c in $cals) { $m = [math]::Max($m, (Get-KokoroAbsMax -Values (& $read $c $n))) }; $curveScale[$n] = [math]::Max($m, 1e-12) * $Margin / 16777216 }
$sF0 = & $scalar 'F0_conv.output'; $sN = & $scalar 'N_conv.output'

$weights = [byte[]]::new($L.WeightBytes); $tables = [byte[]]::new($L.ParameterBytes)
$putI32 = { param([long]$at, [long]$v) if ($v -lt [int]::MinValue -or $v -gt [int]::MaxValue) { throw "int32 overflow at $at" }; [BitConverter]::GetBytes([int]$v).CopyTo($tables, $at) }
$putI64 = { param([long]$at, [long]$v) [BitConverter]::GetBytes($v).CopyTo($tables, $at) }
$putRatio = { param([long]$at, [int]$o, [double]$r) $q = [long](Get-Even ($r * 32768)); if ($q -lt 1 -or $q -gt 32767) { throw "Q15 ratio $r out of range at output $o" }; [BitConverter]::GetBytes([uint32]($q -bor ($q -shl 16))).CopyTo($tables, $at + 4 * $o) }

# One conv: fold, pack W8, choose L, write tables. Returns the output unit per channel.
# L is the finest that keeps the calibration peak in the 16-bit window; the block raises an output channel's scale where a
# conv added into it would otherwise need a Q15 ratio of 1 or more.
function Add-Conv([int]$index, [string]$name, [double[]]$inScale, [int]$cinReal, [string]$peakName, [long]$tablesAt) {
    $c = $L.Convs[$index]; if ($c.Name -ne $name) { throw "Conv order: $($c.Name) is not $name" }
    $w = & $read $cap "$name.weight"; $bias = $null; if ($cap.Json.tensors.ContainsKey("decoder.$name.bias")) { $bias = & $read $cap "$name.bias" }
    $cout = $c.Cout; $cin = $c.Cin; $K = $c.K
    if ($w.Length -ne $cout * $cinReal * $K) { throw "$name weight shape" }
    $fold = [float[]]::new($cout * $cin * $K); $wMax = [double[]]::new($cout)
    (Get-FoldConvWeightsKernel).Invoke($w, $cout, $cinReal, $cin, $K, $inScale, $fold, $wMax)
    # Output unit sW * 2^L: L the finest (from 2) that holds the peak, at most 14 (the bias term stays inside int32);
    # past that the weight unit is coarsened (a row whose bias dominates its tiny weights).
    $need = & $peak $peakName $cout
    $sW = [double[]]::new($cout); $Ls = [int[]]::new($cout); $unit = [double[]]::new($cout); $coarse = 0
    for ($o = 0; $o -lt $cout; $o++) {
        $nd = [math]::Max($need[$o] * $Margin / 32767, 1e-30)
        $sW[$o] = if ($wMax[$o] -gt 0) { $wMax[$o] / 127 } else { $nd / 16384 }
        $Lo = [math]::Max(2, [int][math]::Ceiling([math]::Log($nd / $sW[$o], 2)))
        if ($Lo -gt 14) { $Lo = 14; $sW[$o] = $nd / 16384; $coarse++ }
        $Ls[$o] = $Lo
    }
    $wh = [byte[]]::new($c.Bytes); $wl = [byte[]]::new($c.Bytes); $sumH = [long[]]::new($cout); $sumL = [long[]]::new($cout)
    if ((Get-PackWeightPlanesShapedKernel).Invoke($fold, $cout, $cin, $K, $sW, $wh, $wl, $sumH, $sumL) -ne 0) { throw "$name weight overflow" }
    foreach ($h in $sumH) { if ($h -ne 0) { throw "${name}: W8 weights left a high plane" } }
    [Array]::Copy($wl, 0, $weights, $c.Offset, $c.Bytes)
    for ($o = 0; $o -lt $cout; $o++) {
        $Lo = $Ls[$o]
        $unit[$o] = $sW[$o] * [math]::Pow(2, $Lo)
        if ($need[$o] -gt 32767 * $unit[$o]) { throw "$name output ${o}: calibration peak $($need[$o]) exceeds the 16-bit window ($(32767 * $unit[$o]))" }
        $ob = [int][math]::Floor($o / 32); $cc = $o % 32
        $bq = if ($bias) { [long](Get-Even ($bias[$o] / $sW[$o])) } else { 0L }
        $lg = @(($Lo - 8), $Lo); $half = foreach ($x in $lg) { if ($x -ge 1) { [long][math]::Pow(2, $x - 1) } else { 0L } }
        $biasG = @((-128L * $sumL[$o] + [long][math]::Pow(2, $lg[0] + 15) + $half[0]), ($bq + [long][math]::Pow(2, $lg[1] + 15) + $half[1]))
        for ($pl = 0; $pl -lt 4; $pl++) {
            $g = $pl -shr 1; $e = $(if ($pl % 2) { 9 } else { 1 }) - $lg[$g] + 15
            if ($e -lt 1 -or $e -gt 30) { throw "$name table exponent out of range at $o" }
            $a = $tablesAt + (4 * $ob + $pl) * 256
            [BitConverter]::GetBytes([uint32]($e -shl 10)).CopyTo($tables, $a + 4 * $cc)
            & $putI32 ($a + 128 + 4 * $cc) $biasG[$g]
        }
    }
    $report[$name] = "L $(($Ls | Measure-Object -Minimum).Minimum)..$(($Ls | Measure-Object -Maximum).Maximum), coarsened rows $coarse"
    , $unit
}

# AdaIN1d style affine folded at voice load: A = (1 + gamma) w, B = (1 + gamma) b + beta, gamma, beta = fc(s).
# Record per channel: Ka = A 2^15 / sTarget (int64), Mb = B / sTarget, epsD = eps N^2 / sIn^2 (u64); padded channels zero.
function Add-AdaIn([string]$norm, [int]$cReal, [int]$cPad, [double[]]$inScale, [double[]]$target, [int]$frames, [long]$at, [float[]]$x) {
    $style = & $read $cap "$norm.input.1"; $fw = & $read $cap "$norm.fc.weight"; $fb = & $read $cap "$norm.fc.bias"
    $nw = & $read $cap "$norm.norm.weight"; $nb = & $read $cap "$norm.norm.bias"
    if ($fb.Length -ne 2 * $cReal -or $style.Length -ne 128) { throw "$norm shape" }
    $st = Get-KokoroChannelStats -Values $x -Channels $cReal; $worstK = 0.0
    for ($c = 0; $c -lt $cPad; $c++) {
        $r = $at + 32 * $c
        if ($c -ge $cReal) { & $putI64 $r 0; & $putI32 ($r + 8) 0; & $putI64 ($r + 16) 1; continue }
        $g = [double]$fb[$c]; $be = [double]$fb[$cReal + $c]
        for ($i = 0; $i -lt 128; $i++) { $g += [double]$fw[$c * 128 + $i] * $style[$i]; $be += [double]$fw[($cReal + $c) * 128 + $i] * $style[$i] }
        $A = (1 + $g) * $nw[$c]; $B = (1 + $g) * $nb[$c] + $be
        $ka = [long](Get-Even ($A * 32768 / $target[$c])); $mb = [long](Get-Even ($B / $target[$c]))
        $eps = [long][math]::Max(1, (Get-Even (1e-5 * [double]$frames * $frames / ($inScale[$c] * $inScale[$c]))))
        & $putI64 $r $ka; & $putI32 ($r + 8) $mb; & $putI64 ($r + 16) $eps
        $sdL = [math]::Sqrt($st.Variance[$c] + 1e-5) / $inScale[$c]; $worstK = [math]::Max($worstK, [math]::Abs($ka) / $sdL)
    }
    if ($worstK -ge 2147483647) { throw "$norm K exceeds int32 ($worstK)" }
    $report["$norm.K"] = [math]::Round($worstK)
}

# Inputs.
$act = [byte[]]::new($L.InputBytes)
$z = [uint16[]]::new($T * 16384); [Array]::Fill($z, [uint16]0x8000); [Buffer]::BlockCopy($z, 0, $act, 0, $T * 32768)
$asrCroutons = [byte[]]::new($T * 32768); [Buffer]::BlockCopy($z, 0, $asrCroutons, 0, $asrCroutons.Length)
(Get-QuantizeCroutons16Kernel).Invoke($asr, $F, $sAsr, $asrCroutons); [Array]::Copy($asrCroutons, 0, $act, $L.Input.Asr, $asrCroutons.Length)
foreach ($pair in @(@('input.1', $L.Input.F0), @('input.2', $L.Input.N))) {
    $curve = & $read $cap $pair[0]; if ($curve.Length -ne 2 * $F) { throw 'Curve length is not 2F' }
    for ($i = 0; $i -lt 2 * $F; $i++) { [BitConverter]::GetBytes([int](Get-Even ($curve[$i] / $curveScale[$pair[0]]))).CopyTo($act, $pair[1] + 4 * $i) } }

# F0_conv, N_conv: v_L = (sum W_k c_L + B + 2^14) >> 15.
foreach ($pair in @(@('F0_conv', 'input.1', $sF0, $L.Params.F0), @('N_conv', 'input.2', $sN, $L.Params.N))) {
    $w = & $read $cap "$($pair[0]).weight"; $b = & $read $cap "$($pair[0]).bias"; $sc = $curveScale[$pair[1]]
    for ($k = 0; $k -lt 3; $k++) { & $putI32 ($pair[3] + 4 * $k) ([long](Get-Even ($w[$k] * $sc / $pair[2] * 32768))) }
    & $putI64 ($pair[3] + 16) ([long](Get-Even ($b[0] / $pair[2] * 32768))) }

# Tensor channel scales: E = [asr, F0, N, pad]; block inputs = [previous output, asr_res, F0, N, pad].
$sE = [double[]]::new(544); [Array]::Fill($sE, 1.0); [Array]::Copy($sAsr, $sE, 512); $sE[512] = $sF0; $sE[513] = $sN
$uAsrRes = Add-Conv 0 'asr_res.0' $sE 512 'asr_res.0.output' $L.Params.AsrTables $null
$sX = $sE; $cinReal = 514
$names = 'encode', 'decode.0', 'decode.1', 'decode.2', 'decode.3'
for ($j = 0; $j -lt 5; $j++) {
    $b = $L.Blocks[$j]; $q = $L.BlockParams[$j]; $n = $names[$j]; $cout = $b.Cout; $ci = 1 + 3 * $j
    $sOut = if ($b.Up) { $sD } else { & $perChannel "$n.output" $cout }
    $frames2 = if ($b.Up) { 2 * $F } else { $F }
    # Shortcut on the raw block input, Scale ratio unit / (sOut sqrt 2).
    $uSc = Add-Conv $ci "$n.conv1x1" $sX $cinReal "$n.conv1x1.output" $q.TablesSc
    # AdaIN1 -> windows (decode.3: -> tensor in sA, then the pool to windows in sX1).
    $sX1 = & $scalar "$n.conv1.input.0"
    $xIn = & $read $cap "$n.norm1.input.0"
    if ($b.Up) {
        # Per-channel pool input scales (the AdaIN record sets each channel's LSB), so every tap multiplier is below 1.
        $sA = [double[]]::new($b.Cin); [Array]::Fill($sA, 1.0); [Array]::Copy((& $perChannel "$n.pool.input.0" $cinReal), $sA, $cinReal)
        Add-AdaIn "$n.norm1" $cinReal $b.Cin $sX $sA $F $q.Records1 $xIn
        $pw = & $read $cap "$n.pool.weight"; $pb = & $read $cap "$n.pool.bias"
        for ($c = 0; $c -lt $b.Cin; $c++) {
            $base = $q.Pool + 512 * [math]::Floor($c / 32) + 4 * ($c % 32)
            for ($k = 0; $k -lt 3; $k++) {
                $v = if ($c -lt $cinReal) { [long](Get-Even ($pw[3 * $c + $k] * $sA[$c] / $sX1 * 2147483648)) } else { 0L }
                if ([math]::Abs($v) -ge 2147483647) { throw "Pool Q31 multiplier out of range at channel $c tap $k" }
                & $putI32 ($base + 128 * $k) $v }
            & $putI32 ($base + 384) $(if ($c -lt $cinReal) { [long](Get-Even ($pb[$c] / $sX1)) } else { 0L }) }
    } else {
        $t1 = [double[]]::new($b.Cin); [Array]::Fill($t1, $sX1); Add-AdaIn "$n.norm1" $cinReal $b.Cin $sX $t1 $F $q.Records1 $xIn
    }
    $inX1 = [double[]]::new($b.Cin); [Array]::Fill($inX1, $sX1)
    $uC = Add-Conv ($ci + 1) "$n.conv1" $inX1 $cinReal "$n.conv1.output" $q.Tables1 $null
    # AdaIN2 over C (units uC) -> windows in sX2; conv2 added in Residual mode.
    $sX2 = & $scalar "$n.conv2.input.0"
    $t2 = [double[]]::new($cout); [Array]::Fill($t2, $sX2); Add-AdaIn "$n.norm2" $cout $cout $uC $t2 $frames2 $q.Records2 (& $read $cap "$n.norm2.input.0")
    $inX2 = [double[]]::new($cout); [Array]::Fill($inX2, $sX2)
    $u2 = Add-Conv ($ci + 2) "$n.conv2" $inX2 $cout "$n.conv2.output" $q.Tables2
    # Both terms enter the output through Q15 ratios unit / (sOut sqrt 2) < 1: raise sOut where a unit needs it.
    $raised = 0
    for ($o = 0; $o -lt $cout; $o++) {
        $need = [math]::Max($uSc[$o], $u2[$o]) / (0.999 * [math]::Sqrt(2))
        # decode.3: the generator fixes sOut; its combines double the product (ratios up to 2, stored halved).
        $half = if ($b.Up) { 0.5 } else { 1.0 }
        if ($need * $half -gt $sOut[$o]) { if ($b.Up) { throw "$n output ${o}: the generator's decoder scale is below half a conv unit ($($sOut[$o]) < $($need / 2))" }; $sOut[$o] = $need; $raised++ }
        & $putRatio ($q.RatioSc + 128 * [math]::Floor($o / 32)) ($o % 32) ($half * $uSc[$o] / ($sOut[$o] * [math]::Sqrt(2)))
        & $putRatio ($q.Ratio2 + 128 * [math]::Floor($o / 32)) ($o % 32) ($half * $u2[$o] / ($sOut[$o] * [math]::Sqrt(2)))
    }
    $report["$n.OutputScalesRaised"] = $raised
    $report["$n.scales"] = [ordered]@{ X1 = $sX1; X2 = $sX2; OutMax = ($sOut | Measure-Object -Maximum).Maximum }
    # Next block's input: [this output, asr_res, F0, N, pad].
    if (-not $b.Up) {
        $sX = [double[]]::new(1120); [Array]::Fill($sX, 1.0); [Array]::Copy($sOut, $sX, 1024); [Array]::Copy($uAsrRes, 0, $sX, 1024, 64); $sX[1088] = $sF0; $sX[1089] = $sN
        $cinReal = 1090; $report["$n.OutputScales"] = $sOut
    }
}

[void][IO.Directory]::CreateDirectory($out)
$files = @(@('activations.bin', $act), @('weights.bin', $weights), @('tables.bin', $tables))
foreach ($e in @(@('expected-decoder-f32.bin', 'generator.input.0'), @('expected-encode-f32.bin', 'encode.output'), @('expected-decode0-f32.bin', 'decode.0.output'), @('expected-decode1-f32.bin', 'decode.1.output'), @('expected-decode2-f32.bin', 'decode.2.output'))) {
    $v = & $read $cap $e[1]; $bytes = [byte[]]::new(4 * $v.Length); [Buffer]::BlockCopy($v, 0, $bytes, 0, $bytes.Length); $files += , @($e[0], $bytes) }
foreach ($f in $files) { [IO.File]::WriteAllBytes((Join-Path $out $f[0]), $f[1]) }
$fileList = @(Get-ChildItem -LiteralPath $out -File | ForEach-Object { [ordered]@{ Name = $_.Name; Bytes = $_.Length; SHA256 = (Get-FileHash $_.FullName).Hash } })
[ordered]@{ Graph = 'Decoder16'; Frames = $F; Tiles = $T; Tiles2 = $T2; Margin = $Margin; DecoderScales = $sD
    BlockOutputScales = [ordered]@{ encode = $report['encode.OutputScales']; 'decode.0' = $report['decode.0.OutputScales']; 'decode.1' = $report['decode.1.OutputScales']; 'decode.2' = $report['decode.2.OutputScales'] }
    AsrResUnits = $uAsrRes; F0Scale = $sF0; NScale = $sN; Report = ($report.Keys | Where-Object { $_ -notlike '*OutputScales' } | ForEach-Object { [ordered]@{ Name = $_; Value = $report[$_] } })
    Capture = $cap.Root; CalibrationCaptures = @($cals | ForEach-Object { $_.Root }); FrontFixture = [IO.Path]::GetFullPath($FrontFixture); Files = $fileList } |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $out 'fixture.json') -Encoding utf8NoBOM
[pscustomobject]@{ Directory = $out; Frames = $F; InputBytes = $act.Length; WeightBytes = $weights.Length; TableBytes = $tables.Length }
