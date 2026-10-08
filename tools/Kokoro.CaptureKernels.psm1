#requires -Version 7.4
# Per-element build-time kernels for the capture tools, written as .NET expression trees
# (System.Linq.Expressions) and compiled once per session into JIT'd delegates, so PowerShell only
# orchestrates. No C# source and no assembly bytes: the trees are built here and compiled by the runtime.
# Native crouton layout (Kokoro.AdaInSnakeTurns.ps1): halfword (frame t, channel c) of a C-channel tensor at
#   ((t >> 5) * (C >> 5) + (c >> 5)) * 1024 + 64 * ((t & 31) >> 1) + 2 * (c & 31) + (t & 1).

using namespace System.Linq.Expressions

$script:Kernels = @{}

function New-For {
    # for (v = from; v < to; v++) body
    param([ParameterExpression]$Var, [Expression]$From, [Expression]$To, [Expression]$Body)
    $brk = [Expression]::Label("end_$($Var.Name)")
    [Expression]::Block(
        [Expression]::Assign($Var, $From),
        [Expression]::Loop(
            [Expression]::IfThenElse([Expression]::LessThan($Var, $To),
                [Expression]::Block($Body, [Expression]::PostIncrementAssign($Var)),
                [Expression]::Break($brk)),
            $brk))
}
function New-Int([int]$v) { [Expression]::Constant($v, [int]) }

function Get-CroutonIndexExpression {
    # Halfword index of (t, c) for C channels.
    param([Expression]$T, [Expression]$C, [Expression]$Channels)
    $tile = [Expression]::RightShift($T, (New-Int 5)); $blocks = [Expression]::RightShift($Channels, (New-Int 5))
    $block = [Expression]::RightShift($C, (New-Int 5))
    $rowPair = [Expression]::RightShift([Expression]::And($T, (New-Int 31)), (New-Int 1))
    [Expression]::Add([Expression]::Add([Expression]::Add(
        [Expression]::Multiply([Expression]::Add([Expression]::Multiply($tile, $blocks), $block), (New-Int 1024)),
        [Expression]::Multiply((New-Int 64), $rowPair)),
        [Expression]::Multiply((New-Int 2), [Expression]::And($C, (New-Int 31)))),
        [Expression]::And($T, (New-Int 1)))
}

function Get-QuantizeCroutons16Kernel {
    # (float[] src [c][t], int frames, double[] scales, byte[] dst): dst halfword = clamp(round(src / scale_c),
    # +-32767) + 32768 (round half to even), little-endian, at the crouton index. Channels = scales.Length.
    if ($script:Kernels.ContainsKey('QuantizeCroutons16')) { return $script:Kernels.QuantizeCroutons16 }
    $src = [Expression]::Parameter([float[]], 'src'); $frames = [Expression]::Parameter([int], 'frames')
    $scales = [Expression]::Parameter([double[]], 'scales'); $dst = [Expression]::Parameter([byte[]], 'dst')
    $c = [Expression]::Variable([int], 'c'); $t = [Expression]::Variable([int], 't'); $q = [Expression]::Variable([int], 'q'); $at = [Expression]::Variable([int], 'at')
    $ch = [Expression]::Variable([int], 'ch')
    $round = [Math].GetMethod('Round', [Type[]]@([double]))
    $clamp = [Math].GetMethod('Clamp', [Type[]]@([int], [int], [int]))
    $value = [Expression]::Divide([Expression]::Convert([Expression]::ArrayIndex($src, [Expression]::Add([Expression]::Multiply($c, $frames), $t)), [double]), [Expression]::ArrayIndex($scales, $c))
    $inner = [Expression]::Block(
        [Expression]::Assign($q, [Expression]::Add([Expression]::Call($clamp, [Expression]::Convert([Expression]::Call($round, $value), [int]), (New-Int -32767), (New-Int 32767)), (New-Int 32768))),
        [Expression]::Assign($at, [Expression]::Multiply((New-Int 2), (Get-CroutonIndexExpression $t $c $ch))),
        [Expression]::Assign([Expression]::ArrayAccess($dst, $at), [Expression]::Convert([Expression]::And($q, (New-Int 255)), [byte])),
        [Expression]::Assign([Expression]::ArrayAccess($dst, [Expression]::Add($at, (New-Int 1))), [Expression]::Convert([Expression]::RightShift($q, (New-Int 8)), [byte])))
    $body = [Expression]::Block([ParameterExpression[]]@($c, $t, $q, $at, $ch),
        [Expression]::Assign($ch, [Expression]::ArrayLength($scales)),
        (New-For $c (New-Int 0) $ch (New-For $t (New-Int 0) $frames $inner)))
    $k = [Expression]::Lambda([Action[float[], int, double[], byte[]]], $body, [ParameterExpression[]]@($src, $frames, $scales, $dst)).Compile()
    $script:Kernels.QuantizeCroutons16 = $k; $k
}

function Get-PackWeightPlanesKernel {
    # (float[] w [o][i][k] with 128 x 128, int K, double[] sW, byte[] wh, byte[] wl, long[] sumH, long[] sumL) -> int
    # Wq = round(w / sW_o) (half to even); Wh = (Wq + 128) >> 8; Wl = Wq - 256 Wh; packed in HMX order
    # (Kokoro.HmxConv.ps1): ((g*K + k)*4 + blk)*2048 + 1024*hh + 128*(i >> 2) + 4*c + (i & 3) with
    # o = 64 g + 32 hh + c, input channel 32 blk + i. Returns the count of |Wq| > 32512 (must be 0).
    if ($script:Kernels.ContainsKey('PackWeightPlanes')) { return $script:Kernels.PackWeightPlanes }
    $w = [Expression]::Parameter([float[]], 'w'); $K = [Expression]::Parameter([int], 'K'); $sW = [Expression]::Parameter([double[]], 'sW')
    $wh = [Expression]::Parameter([byte[]], 'wh'); $wl = [Expression]::Parameter([byte[]], 'wl'); $sumH = [Expression]::Parameter([long[]], 'sumH'); $sumL = [Expression]::Parameter([long[]], 'sumL')
    $o = [Expression]::Variable([int], 'o'); $ic = [Expression]::Variable([int], 'ic'); $tap = [Expression]::Variable([int], 'tap')
    $q = [Expression]::Variable([int], 'q'); $qh = [Expression]::Variable([int], 'qh'); $ql = [Expression]::Variable([int], 'ql'); $at = [Expression]::Variable([int], 'at'); $bad = [Expression]::Variable([int], 'bad')
    $round = [Math].GetMethod('Round', [Type[]]@([double])); $abs = [Math].GetMethod('Abs', [Type[]]@([int]))
    $src = [Expression]::ArrayIndex($w, [Expression]::Add([Expression]::Multiply([Expression]::Add([Expression]::Multiply($o, (New-Int 128)), $ic), $K), $tap))
    $g = [Expression]::RightShift($o, (New-Int 6)); $hh = [Expression]::And([Expression]::RightShift($o, (New-Int 5)), (New-Int 1)); $cc = [Expression]::And($o, (New-Int 31))
    $blk = [Expression]::RightShift($ic, (New-Int 5)); $i = [Expression]::And($ic, (New-Int 31))
    $pos = [Expression]::Add([Expression]::Add([Expression]::Add([Expression]::Add(
        [Expression]::Multiply([Expression]::Add([Expression]::Multiply([Expression]::Add([Expression]::Multiply($g, $K), $tap), (New-Int 4)), $blk), (New-Int 2048)),
        [Expression]::Multiply((New-Int 1024), $hh)), [Expression]::Multiply((New-Int 128), [Expression]::RightShift($i, (New-Int 2)))),
        [Expression]::Multiply((New-Int 4), $cc)), [Expression]::And($i, (New-Int 3)))
    $inner = [Expression]::Block(
        [Expression]::Assign($q, [Expression]::Convert([Expression]::Call($round, [Expression]::Divide([Expression]::Convert($src, [double]), [Expression]::ArrayIndex($sW, $o))), [int])),
        [Expression]::IfThen([Expression]::GreaterThan([Expression]::Call($abs, $q), (New-Int 32512)), [Expression]::PostIncrementAssign($bad)),
        [Expression]::Assign($qh, [Expression]::RightShift([Expression]::Add($q, (New-Int 128)), (New-Int 8))),
        [Expression]::Assign($ql, [Expression]::Subtract($q, [Expression]::Multiply((New-Int 256), $qh))),
        [Expression]::Assign($at, $pos),
        [Expression]::Assign([Expression]::ArrayAccess($wh, $at), [Expression]::Convert([Expression]::And($qh, (New-Int 255)), [byte])),
        [Expression]::Assign([Expression]::ArrayAccess($wl, $at), [Expression]::Convert([Expression]::And($ql, (New-Int 255)), [byte])),
        [Expression]::AddAssign([Expression]::ArrayAccess($sumH, $o), [Expression]::Convert($qh, [long])),
        [Expression]::AddAssign([Expression]::ArrayAccess($sumL, $o), [Expression]::Convert($ql, [long])))
    $body = [Expression]::Block([int], [ParameterExpression[]]@($o, $ic, $tap, $q, $qh, $ql, $at, $bad),
        [Expression]::Assign($bad, (New-Int 0)),
        (New-For $o (New-Int 0) (New-Int 128) (New-For $ic (New-Int 0) (New-Int 128) (New-For $tap (New-Int 0) $K $inner))),
        $bad)
    $k = [Expression]::Lambda([Func[float[], int, double[], byte[], byte[], long[], long[], int]], $body, [ParameterExpression[]]@($w, $K, $sW, $wh, $wl, $sumH, $sumL)).Compile()
    $script:Kernels.PackWeightPlanes = $k; $k
}

function Get-Mean3Kernel {
    # (float[] a, float[] b, float[] c, float[] dst): dst = (a + b + c) / 3 in double, stored as float.
    if ($script:Kernels.ContainsKey('Mean3')) { return $script:Kernels.Mean3 }
    $a = [Expression]::Parameter([float[]], 'a'); $b = [Expression]::Parameter([float[]], 'b'); $c = [Expression]::Parameter([float[]], 'c'); $d = [Expression]::Parameter([float[]], 'd')
    $i = [Expression]::Variable([int], 'i')
    $sum = [Expression]::Add([Expression]::Add([Expression]::Convert([Expression]::ArrayIndex($a, $i), [double]), [Expression]::Convert([Expression]::ArrayIndex($b, $i), [double])), [Expression]::Convert([Expression]::ArrayIndex($c, $i), [double]))
    $body = [Expression]::Block([ParameterExpression[]]@($i), (New-For $i (New-Int 0) ([Expression]::ArrayLength($a)) ([Expression]::Assign([Expression]::ArrayAccess($d, $i), [Expression]::Convert([Expression]::Divide($sum, [Expression]::Constant(3.0)), [float])))))
    $k = [Expression]::Lambda([Action[float[], float[], float[], float[]]], $body, [ParameterExpression[]]@($a, $b, $c, $d)).Compile()
    $script:Kernels.Mean3 = $k; $k
}

function Get-Croutons16ErrorKernel {
    # (byte[] cap, float[] ref [c][t], int frames, double[] scales, double[] signal, double[] noise) -> double maxAbsError
    # value = (u16 - 32768) * scale_c; per channel accumulates sum ref^2 and sum (ref - value)^2.
    if ($script:Kernels.ContainsKey('Croutons16Error')) { return $script:Kernels.Croutons16Error }
    $cap = [Expression]::Parameter([byte[]], 'cap'); $ref = [Expression]::Parameter([float[]], 'ref'); $frames = [Expression]::Parameter([int], 'frames')
    $scales = [Expression]::Parameter([double[]], 'scales'); $sig = [Expression]::Parameter([double[]], 'sig'); $noi = [Expression]::Parameter([double[]], 'noi')
    $c = [Expression]::Variable([int], 'c'); $t = [Expression]::Variable([int], 't'); $at = [Expression]::Variable([int], 'at'); $ch = [Expression]::Variable([int], 'ch')
    $r = [Expression]::Variable([double], 'r'); $dd = [Expression]::Variable([double], 'dd'); $mx = [Expression]::Variable([double], 'mx')
    $abs = [Math].GetMethod('Abs', [Type[]]@([double])); $max = [Math].GetMethod('Max', [Type[]]@([double], [double]))
    $u16 = [Expression]::Or([Expression]::Convert([Expression]::ArrayIndex($cap, $at), [int]), [Expression]::LeftShift([Expression]::Convert([Expression]::ArrayIndex($cap, [Expression]::Add($at, (New-Int 1))), [int]), (New-Int 8)))
    $value = [Expression]::Multiply([Expression]::Convert([Expression]::Subtract($u16, (New-Int 32768)), [double]), [Expression]::ArrayIndex($scales, $c))
    $inner = [Expression]::Block(
        [Expression]::Assign($at, [Expression]::Multiply((New-Int 2), (Get-CroutonIndexExpression $t $c $ch))),
        [Expression]::Assign($r, [Expression]::Convert([Expression]::ArrayIndex($ref, [Expression]::Add([Expression]::Multiply($c, $frames), $t)), [double])),
        [Expression]::Assign($dd, [Expression]::Subtract($r, $value)),
        [Expression]::AddAssign([Expression]::ArrayAccess($sig, $c), [Expression]::Multiply($r, $r)),
        [Expression]::AddAssign([Expression]::ArrayAccess($noi, $c), [Expression]::Multiply($dd, $dd)),
        [Expression]::Assign($mx, [Expression]::Call($max, $mx, [Expression]::Call($abs, $dd))))
    $body = [Expression]::Block([double], [ParameterExpression[]]@($c, $t, $at, $ch, $r, $dd, $mx),
        [Expression]::Assign($ch, [Expression]::ArrayLength($scales)), [Expression]::Assign($mx, [Expression]::Constant(0.0)),
        (New-For $c (New-Int 0) $ch (New-For $t (New-Int 0) $frames $inner)), $mx)
    $k = [Expression]::Lambda([Func[byte[], float[], int, double[], double[], double[], double]], $body, [ParameterExpression[]]@($cap, $ref, $frames, $scales, $sig, $noi)).Compile()
    $script:Kernels.Croutons16Error = $k; $k
}

function Get-DecodeCroutons16Kernel {
    # (byte[] src, int frames, int channels, float[] dst [c][t]): dst = u16 - 32768 at the crouton index.
    if ($script:Kernels.ContainsKey('DecodeCroutons16')) { return $script:Kernels.DecodeCroutons16 }
    $src = [Expression]::Parameter([byte[]], 'src'); $frames = [Expression]::Parameter([int], 'frames'); $ch = [Expression]::Parameter([int], 'ch'); $dst = [Expression]::Parameter([float[]], 'dst')
    $c = [Expression]::Variable([int], 'c'); $t = [Expression]::Variable([int], 't'); $at = [Expression]::Variable([int], 'at')
    $u16 = [Expression]::Or([Expression]::Convert([Expression]::ArrayIndex($src, $at), [int]), [Expression]::LeftShift([Expression]::Convert([Expression]::ArrayIndex($src, [Expression]::Add($at, (New-Int 1))), [int]), (New-Int 8)))
    $inner = [Expression]::Block(
        [Expression]::Assign($at, [Expression]::Multiply((New-Int 2), (Get-CroutonIndexExpression $t $c $ch))),
        [Expression]::Assign([Expression]::ArrayAccess($dst, [Expression]::Add([Expression]::Multiply($c, $frames), $t)), [Expression]::Convert([Expression]::Subtract($u16, (New-Int 32768)), [float])))
    $body = [Expression]::Block([ParameterExpression[]]@($c, $t, $at), (New-For $c (New-Int 0) $ch (New-For $t (New-Int 0) $frames $inner)))
    $k = [Expression]::Lambda([Action[byte[], int, int, float[]]], $body, [ParameterExpression[]]@($src, $frames, $ch, $dst)).Compile()
    $script:Kernels.DecodeCroutons16 = $k; $k
}

function Get-InterleavePlanesKernel {
    # (byte[] hi, int hiOff, byte[] lo, int loOff, int halfwords, byte[] dst): dst halfword i = (hi[hiOff + 2i + 1] << 8) |
    # lo[loOff + 2i + 1], the biased 16-bit value of a high/low byte-plane pair held in odd bytes.
    if ($script:Kernels.ContainsKey('InterleavePlanes')) { return $script:Kernels.InterleavePlanes }
    $hi = [Expression]::Parameter([byte[]], 'hi'); $ho = [Expression]::Parameter([int], 'ho'); $lo = [Expression]::Parameter([byte[]], 'lo'); $lo2 = [Expression]::Parameter([int], 'lo2')
    $n = [Expression]::Parameter([int], 'n'); $dst = [Expression]::Parameter([byte[]], 'dst'); $i = [Expression]::Variable([int], 'i')
    $two = [Expression]::Multiply((New-Int 2), $i)
    $inner = [Expression]::Block(
        [Expression]::Assign([Expression]::ArrayAccess($dst, $two), [Expression]::ArrayIndex($lo, [Expression]::Add([Expression]::Add($lo2, $two), (New-Int 1)))),
        [Expression]::Assign([Expression]::ArrayAccess($dst, [Expression]::Add($two, (New-Int 1))), [Expression]::ArrayIndex($hi, [Expression]::Add([Expression]::Add($ho, $two), (New-Int 1)))))
    $body = [Expression]::Block([ParameterExpression[]]@($i), (New-For $i (New-Int 0) $n $inner))
    $kk = [Expression]::Lambda([Action[byte[], int, byte[], int, int, byte[]]], $body, [ParameterExpression[]]@($hi, $ho, $lo, $lo2, $n, $dst)).Compile()
    $script:Kernels.InterleavePlanes = $kk; $kk
}
function Get-ChannelStatsKernel {
    # (float[] v [c][f], int channels, double[] absMax, double[] sum, double[] sumSquares): per-channel
    # accumulation in double over f = v.Length / channels values.
    if ($script:Kernels.ContainsKey('ChannelStats')) { return $script:Kernels.ChannelStats }
    $v = [Expression]::Parameter([float[]], 'v'); $ch = [Expression]::Parameter([int], 'ch')
    $am = [Expression]::Parameter([double[]], 'am'); $s1 = [Expression]::Parameter([double[]], 's1'); $s2 = [Expression]::Parameter([double[]], 's2')
    $c = [Expression]::Variable([int], 'c'); $i = [Expression]::Variable([int], 'i'); $f = [Expression]::Variable([int], 'f'); $x = [Expression]::Variable([double], 'x')
    $abs = [Math].GetMethod('Abs', [Type[]]@([double])); $max = [Math].GetMethod('Max', [Type[]]@([double], [double]))
    $inner = [Expression]::Block(
        [Expression]::Assign($x, [Expression]::Convert([Expression]::ArrayIndex($v, [Expression]::Add([Expression]::Multiply($c, $f), $i)), [double])),
        [Expression]::Assign([Expression]::ArrayAccess($am, $c), [Expression]::Call($max, [Expression]::ArrayIndex($am, $c), [Expression]::Call($abs, $x))),
        [Expression]::AddAssign([Expression]::ArrayAccess($s1, $c), $x),
        [Expression]::AddAssign([Expression]::ArrayAccess($s2, $c), [Expression]::Multiply($x, $x)))
    $body = [Expression]::Block([ParameterExpression[]]@($c, $i, $f, $x),
        [Expression]::Assign($f, [Expression]::Divide([Expression]::ArrayLength($v), $ch)),
        (New-For $c (New-Int 0) $ch (New-For $i (New-Int 0) $f $inner)))
    $k = [Expression]::Lambda([Action[float[], int, double[], double[], double[]]], $body, [ParameterExpression[]]@($v, $ch, $am, $s1, $s2)).Compile()
    $script:Kernels.ChannelStats = $k; $k
}

Export-ModuleMember -Function Get-QuantizeCroutons16Kernel, Get-PackWeightPlanesKernel, Get-Mean3Kernel, Get-Croutons16ErrorKernel, Get-ChannelStatsKernel, Get-DecodeCroutons16Kernel, Get-InterleavePlanesKernel
