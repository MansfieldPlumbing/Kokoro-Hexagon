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

function Get-QuantizeRowsKernel {
    # (double[] w [r][i], int rows, int per, int levels, double[] clip [r], double[] q, double[] err [r]): per row r,
    # scale = clip_r * max|w_r| / levels, q = clamp(round(w / scale), +-levels) * scale (round half to even), err_r = the
    # squared error of the row. Rows with max 0 stay 0. Build-time analysis of weight quantization
    # (tools/Measure-KokoroDecoderWeightError.ps1).
    if ($script:Kernels.ContainsKey('QuantizeRows')) { return $script:Kernels.QuantizeRows }
    $E = [Expression]
    $w = $E::Parameter([double[]], 'w'); $rows = $E::Parameter([int], 'rows'); $per = $E::Parameter([int], 'per'); $levels = $E::Parameter([int], 'levels')
    $clip = $E::Parameter([double[]], 'clip'); $q = $E::Parameter([double[]], 'q'); $err = $E::Parameter([double[]], 'err')
    $r = $E::Variable([int], 'r'); $i = $E::Variable([int], 'i'); $base = $E::Variable([int], 'rowBase'); $max = $E::Variable([double], 'max')
    $scale = $E::Variable([double], 'scale'); $v = $E::Variable([double], 'v'); $acc = $E::Variable([double], 'acc'); $lv = $E::Variable([double], 'lv')
    $round = [Math].GetMethod('Round', [Type[]]@([double])); $abs = [Math].GetMethod('Abs', [Type[]]@([double]))
    $mx = [Math].GetMethod('Max', [Type[]]@([double], [double])); $clamp = [Math].GetMethod('Clamp', [Type[]]@([double], [double], [double]))
    $wi = $E::ArrayIndex($w, $E::Add($base, $i))
    $findMax = New-For $i (New-Int 0) $per ($E::Assign($max, $E::Call($mx, $max, $E::Call($abs, $wi))))
    $quantize = New-For $i (New-Int 0) $per ($E::Block(
        $E::Assign($v, $E::Multiply($E::Call($clamp, $E::Call($round, $E::Divide($wi, $scale)), $E::Negate($lv), $lv), $scale)),
        $E::Assign($E::ArrayAccess($q, $E::Add($base, $i)), $v),
        $E::AddAssign($acc, $E::Multiply($E::Subtract($v, $wi), $E::Subtract($v, $wi)))))
    $row = $E::Block(
        $E::Assign($base, $E::Multiply($r, $per)), $E::Assign($max, $E::Constant(0.0)), $findMax, $E::Assign($acc, $E::Constant(0.0)),
        $E::IfThen($E::GreaterThan($max, $E::Constant(0.0)), $E::Block(
            $E::Assign($scale, $E::Divide($E::Multiply($E::ArrayIndex($clip, $r), $max), $lv)), $quantize)),
        $E::Assign($E::ArrayAccess($err, $r), $acc))
    $body = $E::Block([ParameterExpression[]]@($r, $i, $base, $max, $scale, $v, $acc, $lv),
        $E::Assign($lv, $E::Convert($levels, [double])), (New-For $r (New-Int 0) $rows $row))
    $k = $E::Lambda([Action[double[], int, int, int, double[], double[], double[]]], $body, [ParameterExpression[]]@($w, $rows, $per, $levels, $clip, $q, $err)).Compile()
    $script:Kernels.QuantizeRows = $k; $k
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

function Get-PackWeightPlanesShapedKernel {
    # As Get-PackWeightPlanesKernel for any cout, cin (multiples of 64 and 32): (float[] w [o][i][k], int cout, int cin,
    # int K, double[] sW, byte[] wh, byte[] wl, long[] sumH, long[] sumL) -> int count of |Wq| > 32512.
    # HMX order (Kokoro.HmxConvPlanes.ps1): ((g*K + k)*CB + blk)*2048 + 1024*hh + 128*(i >> 2) + 4*c + (i & 3).
    if ($script:Kernels.ContainsKey('PackWeightPlanesShaped')) { return $script:Kernels.PackWeightPlanesShaped }
    $E = [Expression]
    $w = $E::Parameter([float[]], 'w'); $cout = $E::Parameter([int], 'cout'); $cin = $E::Parameter([int], 'cin'); $K = $E::Parameter([int], 'K'); $sW = $E::Parameter([double[]], 'sW')
    $wh = $E::Parameter([byte[]], 'wh'); $wl = $E::Parameter([byte[]], 'wl'); $sumH = $E::Parameter([long[]], 'sumH'); $sumL = $E::Parameter([long[]], 'sumL')
    $o = $E::Variable([int], 'o'); $ic = $E::Variable([int], 'ic'); $tap = $E::Variable([int], 'tap'); $cb = $E::Variable([int], 'cb')
    $q = $E::Variable([int], 'q'); $qh = $E::Variable([int], 'qh'); $ql = $E::Variable([int], 'ql'); $at = $E::Variable([int], 'at'); $bad = $E::Variable([int], 'bad')
    $round = [Math].GetMethod('Round', [Type[]]@([double])); $abs = [Math].GetMethod('Abs', [Type[]]@([int]))
    $src = $E::ArrayIndex($w, $E::Add($E::Multiply($E::Add($E::Multiply($o, $cin), $ic), $K), $tap))
    $g = $E::RightShift($o, (New-Int 6)); $hh = $E::And($E::RightShift($o, (New-Int 5)), (New-Int 1)); $cc = $E::And($o, (New-Int 31))
    $blk = $E::RightShift($ic, (New-Int 5)); $i = $E::And($ic, (New-Int 31))
    $pos = $E::Add($E::Add($E::Add($E::Add(
        $E::Multiply($E::Add($E::Multiply($E::Add($E::Multiply($g, $K), $tap), $cb), $blk), (New-Int 2048)),
        $E::Multiply((New-Int 1024), $hh)), $E::Multiply((New-Int 128), $E::RightShift($i, (New-Int 2)))),
        $E::Multiply((New-Int 4), $cc)), $E::And($i, (New-Int 3)))
    $inner = $E::Block(
        $E::Assign($q, $E::Convert($E::Call($round, $E::Divide($E::Convert($src, [double]), $E::ArrayIndex($sW, $o))), [int])),
        $E::IfThen($E::GreaterThan($E::Call($abs, $q), (New-Int 32512)), $E::PostIncrementAssign($bad)),
        $E::Assign($qh, $E::RightShift($E::Add($q, (New-Int 128)), (New-Int 8))),
        $E::Assign($ql, $E::Subtract($q, $E::Multiply((New-Int 256), $qh))),
        $E::Assign($at, $pos),
        $E::Assign($E::ArrayAccess($wh, $at), $E::Convert($E::And($qh, (New-Int 255)), [byte])),
        $E::Assign($E::ArrayAccess($wl, $at), $E::Convert($E::And($ql, (New-Int 255)), [byte])),
        $E::AddAssign($E::ArrayAccess($sumH, $o), $E::Convert($qh, [long])),
        $E::AddAssign($E::ArrayAccess($sumL, $o), $E::Convert($ql, [long])))
    $body = $E::Block([int], [ParameterExpression[]]@($o, $ic, $tap, $cb, $q, $qh, $ql, $at, $bad),
        $E::Assign($bad, (New-Int 0)), $E::Assign($cb, $E::RightShift($cin, (New-Int 5))),
        (New-For $o (New-Int 0) $cout (New-For $ic (New-Int 0) $cin (New-For $tap (New-Int 0) $K $inner))),
        $bad)
    $kk = $E::Lambda([Func[float[], int, int, int, double[], byte[], byte[], long[], long[], int]], $body, [ParameterExpression[]]@($w, $cout, $cin, $K, $sW, $wh, $wl, $sumH, $sumL)).Compile()
    $script:Kernels.PackWeightPlanesShaped = $kk; $kk
}

function Get-FoldConvWeightsKernel {
    # (float[] w [o][i][k] with cinReal inputs, int cout, int cinReal, int cinPad, int K, double[] inScale [cinReal],
    # float[] dst [o][cinPad][k], double[] wMax [o]): dst = w * inScale_i (weights per input LSB), inputs cinReal..cinPad-1
    # zero; wMax_o = max |dst| of the row. Decoder fixture (tools/New-KokoroDecoderFixture.ps1).
    if ($script:Kernels.ContainsKey('FoldConvWeights')) { return $script:Kernels.FoldConvWeights }
    $E = [Expression]
    $w = $E::Parameter([float[]], 'w'); $cout = $E::Parameter([int], 'cout'); $cinReal = $E::Parameter([int], 'cinReal'); $cinPad = $E::Parameter([int], 'cinPad')
    $taps = $E::Parameter([int], 'K'); $scale = $E::Parameter([double[]], 'inScale'); $dst = $E::Parameter([float[]], 'dst'); $wMax = $E::Parameter([double[]], 'wMax')
    $o = $E::Variable([int], 'o'); $i = $E::Variable([int], 'i'); $k = $E::Variable([int], 'k'); $v = $E::Variable([double], 'v')
    $abs = [Math].GetMethod('Abs', [Type[]]@([double])); $mx = [Math].GetMethod('Max', [Type[]]@([double], [double]))
    $src = $E::ArrayIndex($w, $E::Add($E::Multiply($E::Add($E::Multiply($o, $cinReal), $i), $taps), $k))
    $inner = $E::Block(
        $E::Assign($v, $E::Multiply($E::Convert($src, [double]), $E::ArrayIndex($scale, $i))),
        $E::Assign($E::ArrayAccess($dst, $E::Add($E::Multiply($E::Add($E::Multiply($o, $cinPad), $i), $taps), $k)), $E::Convert($v, [float])),
        $E::Assign($E::ArrayAccess($wMax, $o), $E::Call($mx, $E::ArrayIndex($wMax, $o), $E::Call($abs, $v))))
    $body = $E::Block([ParameterExpression[]]@($o, $i, $k, $v),
        (New-For $o (New-Int 0) $cout (New-For $i (New-Int 0) $cinReal (New-For $k (New-Int 0) $taps $inner))))
    $kk = $E::Lambda([Action[float[], int, int, int, int, double[], float[], double[]]], $body, [ParameterExpression[]]@($w, $cout, $cinReal, $cinPad, $taps, $scale, $dst, $wMax)).Compile()
    $script:Kernels.FoldConvWeights = $kk; $kk
}

function Get-SplitPlanesKernel {
    # (byte[] u16 biased halfwords, byte[] hi, byte[] lo): per halfword i, hi odd byte = high byte of u16 ((q >> 8) + 128),
    # lo odd byte = low byte (q & 255); even bytes zero. The two HMX conv-input planes (Kokoro.AdaInSnakeTurns.ps1 layout).
    if ($script:Kernels.ContainsKey('SplitPlanes')) { return $script:Kernels.SplitPlanes }
    $E = [Expression]
    $src = $E::Parameter([byte[]], 'src'); $hi = $E::Parameter([byte[]], 'hi'); $lo = $E::Parameter([byte[]], 'lo'); $i = $E::Variable([int], 'i')
    $two = $E::Multiply((New-Int 2), $i); $odd = $E::Add($two, (New-Int 1))
    $inner = $E::Block(
        $E::Assign($E::ArrayAccess($hi, $odd), $E::ArrayIndex($src, $odd)),
        $E::Assign($E::ArrayAccess($lo, $odd), $E::ArrayIndex($src, $two)))
    $body = $E::Block([ParameterExpression[]]@($i), (New-For $i (New-Int 0) ($E::Divide($E::ArrayLength($src), (New-Int 2))) $inner))
    $k = $E::Lambda([Action[byte[], byte[], byte[]]], $body, [ParameterExpression[]]@($src, $hi, $lo)).Compile()
    $script:Kernels.SplitPlanes = $k; $k
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

function Get-LowLowWindowKernel {
    # (float[] x [i][t] 128 inputs, int frames, double sX, float[] w [o][i][k] 128 x 128, int K, int dilation, double[] sW,
    # int[] L, int[] maxAbs) -> int: the low x low group of the 16-bit conv (tools/New-KokoroGenerator60x16Fixture.ps1)
    # on real inputs. xq = clamp(round(x / sX), +-32767), l = xq & 255 (zero outside the frames, as the padded window);
    # Wq = round(w / sW_o), Wl = Wq - 256 ((Wq + 128) >> 8); A3 = sum l Wl (same-padded dilated taps); window
    # (A3 + 2^(L+7)) >> (L+8). maxAbs[o] = max |window| over frames; returns the maximum over o.
    if ($script:Kernels.ContainsKey('LowLowWindow')) { return $script:Kernels.LowLowWindow }
    $x = [Expression]::Parameter([float[]], 'x'); $frames = [Expression]::Parameter([int], 'frames'); $sX = [Expression]::Parameter([double], 'sX')
    $w = [Expression]::Parameter([float[]], 'w'); $K = [Expression]::Parameter([int], 'K'); $dil = [Expression]::Parameter([int], 'dil')
    $sW = [Expression]::Parameter([double[]], 'sW'); $L = [Expression]::Parameter([int[]], 'L'); $maxAbs = [Expression]::Parameter([int[]], 'maxAbs')
    $v = @{}; foreach ($n in 'i','o','tap','ic','t','t0','t1','shift','q','ql','base','sh','win','m','all') { $v[$n] = [Expression]::Variable([int], $n) }
    $lowByte = [Expression]::Variable([int[]], 'lowByte'); $acc = [Expression]::Variable([int[]], 'acc'); $hb = [Expression]::Variable([long], 'hb')
    $round = [Math].GetMethod('Round', [Type[]]@([double])); $clamp = [Math].GetMethod('Clamp', [Type[]]@([int], [int], [int]))
    $absI = [Math].GetMethod('Abs', [Type[]]@([int])); $maxI = [Math].GetMethod('Max', [Type[]]@([int], [int])); $minI = [Math].GetMethod('Min', [Type[]]@([int], [int]))
    $E = [Expression]
    $quantX = $E::Call($clamp, $E::Convert($E::Call($round, $E::Divide($E::Convert($E::ArrayIndex($x, $v.i), [double]), $sX)), [int]), (New-Int -32767), (New-Int 32767))
    $fillL = New-For $v.i (New-Int 0) ($E::ArrayLength($x)) ($E::Assign($E::ArrayAccess($lowByte, $v.i), $E::And($quantX, (New-Int 255))))
    $wq = $E::Convert($E::Call($round, $E::Divide($E::Convert($E::ArrayIndex($w, $E::Add($E::Multiply($E::Add($E::Multiply($v.o, (New-Int 128)), $v.ic), $K), $v.tap)), [double]), $E::ArrayIndex($sW, $v.o))), [int])
    $macT = New-For $v.t $v.t0 $v.t1 ($E::AddAssign($E::ArrayAccess($acc, $v.t), $E::Multiply($E::ArrayIndex($lowByte, $E::Add($v.base, $v.t)), $v.ql)))
    $perIc = $E::Block(
        $E::Assign($v.q, $wq),
        $E::Assign($v.ql, $E::Subtract($v.q, $E::Multiply((New-Int 256), $E::RightShift($E::Add($v.q, (New-Int 128)), (New-Int 8))))),
        $E::IfThen($E::NotEqual($v.ql, (New-Int 0)), $E::Block($E::Assign($v.base, $E::Add($E::Multiply($v.ic, $frames), $v.shift)), $macT)))
    $perTap = $E::Block(
        $E::Assign($v.shift, $E::Multiply($dil, $E::Subtract($v.tap, $E::Divide($E::Subtract($K, (New-Int 1)), (New-Int 2))))),
        $E::Assign($v.t0, $E::Call($maxI, (New-Int 0), $E::Negate($v.shift))),
        $E::Assign($v.t1, $E::Call($minI, $frames, $E::Subtract($frames, $v.shift))),
        (New-For $v.ic (New-Int 0) (New-Int 128) $perIc))
    $window = $E::Convert($E::RightShift($E::Add($E::Convert($E::ArrayIndex($acc, $v.t), [long]), $hb), $v.sh), [int])
    $perO = $E::Block(
        (New-For $v.t (New-Int 0) $frames ($E::Assign($E::ArrayAccess($acc, $v.t), (New-Int 0)))),
        (New-For $v.tap (New-Int 0) $K $perTap),
        $E::Assign($v.sh, $E::Add($E::ArrayIndex($L, $v.o), (New-Int 8))),
        $E::Assign($hb, $E::LeftShift($E::Constant(1L), $E::Subtract($v.sh, (New-Int 1)))),
        $E::Assign($v.m, (New-Int 0)),
        (New-For $v.t (New-Int 0) $frames ($E::Assign($v.m, $E::Call($maxI, $v.m, $E::Call($absI, $window))))),
        $E::Assign($E::ArrayAccess($maxAbs, $v.o), $v.m),
        $E::Assign($v.all, $E::Call($maxI, $v.all, $v.m)))
    $vars = [ParameterExpression[]]@(@($v.Values) + $lowByte + $acc + $hb)
    $body = $E::Block([int], $vars,
        $E::Assign($lowByte, $E::NewArrayBounds([int], $E::ArrayLength($x))), $E::Assign($acc, $E::NewArrayBounds([int], $frames)),
        $E::Assign($v.all, (New-Int 0)), $fillL,
        (New-For $v.o (New-Int 0) (New-Int 128) $perO), $v.all)
    $k = $E::Lambda([Func[float[], int, double, float[], int, int, double[], int[], int[], int]], $body, [ParameterExpression[]]@($x, $frames, $sX, $w, $K, $dil, $sW, $L, $maxAbs)).Compile()
    $script:Kernels.LowLowWindow = $k; $k
}

function Get-LowLowWindowShapedKernel {
    # As Get-LowLowWindowKernel for cin inputs and cout outputs: (float[] x [i][t], int frames, double sX, float[] w [o][i][k],
    # int cin, int cout, int K, int dilation, double[] sW, int[] L, int[] maxAbs) -> int: the low x low group of the 16-bit conv (tools/New-KokoroGenerator60x16Fixture.ps1)
    # on real inputs. xq = clamp(round(x / sX), +-32767), l = xq & 255 (zero outside the frames, as the padded window);
    # Wq = round(w / sW_o), Wl = Wq - 256 ((Wq + 128) >> 8); A3 = sum l Wl (same-padded dilated taps); window
    # (A3 + 2^(L+7)) >> (L+8). maxAbs[o] = max |window| over frames; returns the maximum over o.
    if ($script:Kernels.ContainsKey('LowLowWindowShaped')) { return $script:Kernels.LowLowWindowShaped }
    $x = [Expression]::Parameter([float[]], 'x'); $frames = [Expression]::Parameter([int], 'frames'); $sX = [Expression]::Parameter([double], 'sX')
    $w = [Expression]::Parameter([float[]], 'w'); $cin = [Expression]::Parameter([int], 'cin'); $cout = [Expression]::Parameter([int], 'cout'); $K = [Expression]::Parameter([int], 'K'); $dil = [Expression]::Parameter([int], 'dil')
    $sW = [Expression]::Parameter([double[]], 'sW'); $L = [Expression]::Parameter([int[]], 'L'); $maxAbs = [Expression]::Parameter([int[]], 'maxAbs')
    $v = @{}; foreach ($n in 'i','o','tap','ic','t','t0','t1','shift','q','ql','base','sh','win','m','all') { $v[$n] = [Expression]::Variable([int], $n) }
    $lowByte = [Expression]::Variable([int[]], 'lowByte'); $acc = [Expression]::Variable([int[]], 'acc'); $hb = [Expression]::Variable([long], 'hb')
    $round = [Math].GetMethod('Round', [Type[]]@([double])); $clamp = [Math].GetMethod('Clamp', [Type[]]@([int], [int], [int]))
    $absI = [Math].GetMethod('Abs', [Type[]]@([int])); $maxI = [Math].GetMethod('Max', [Type[]]@([int], [int])); $minI = [Math].GetMethod('Min', [Type[]]@([int], [int]))
    $E = [Expression]
    $quantX = $E::Call($clamp, $E::Convert($E::Call($round, $E::Divide($E::Convert($E::ArrayIndex($x, $v.i), [double]), $sX)), [int]), (New-Int -32767), (New-Int 32767))
    $fillL = New-For $v.i (New-Int 0) ($E::ArrayLength($x)) ($E::Assign($E::ArrayAccess($lowByte, $v.i), $E::And($quantX, (New-Int 255))))
    $wq = $E::Convert($E::Call($round, $E::Divide($E::Convert($E::ArrayIndex($w, $E::Add($E::Multiply($E::Add($E::Multiply($v.o, $cin), $v.ic), $K), $v.tap)), [double]), $E::ArrayIndex($sW, $v.o))), [int])
    $macT = New-For $v.t $v.t0 $v.t1 ($E::AddAssign($E::ArrayAccess($acc, $v.t), $E::Multiply($E::ArrayIndex($lowByte, $E::Add($v.base, $v.t)), $v.ql)))
    $perIc = $E::Block(
        $E::Assign($v.q, $wq),
        $E::Assign($v.ql, $E::Subtract($v.q, $E::Multiply((New-Int 256), $E::RightShift($E::Add($v.q, (New-Int 128)), (New-Int 8))))),
        $E::IfThen($E::NotEqual($v.ql, (New-Int 0)), $E::Block($E::Assign($v.base, $E::Add($E::Multiply($v.ic, $frames), $v.shift)), $macT)))
    $perTap = $E::Block(
        $E::Assign($v.shift, $E::Multiply($dil, $E::Subtract($v.tap, $E::Divide($E::Subtract($K, (New-Int 1)), (New-Int 2))))),
        $E::Assign($v.t0, $E::Call($maxI, (New-Int 0), $E::Negate($v.shift))),
        $E::Assign($v.t1, $E::Call($minI, $frames, $E::Subtract($frames, $v.shift))),
        (New-For $v.ic (New-Int 0) $cin $perIc))
    $window = $E::Convert($E::RightShift($E::Add($E::Convert($E::ArrayIndex($acc, $v.t), [long]), $hb), $v.sh), [int])
    $perO = $E::Block(
        (New-For $v.t (New-Int 0) $frames ($E::Assign($E::ArrayAccess($acc, $v.t), (New-Int 0)))),
        (New-For $v.tap (New-Int 0) $K $perTap),
        $E::Assign($v.sh, $E::Add($E::ArrayIndex($L, $v.o), (New-Int 8))),
        $E::Assign($hb, $E::LeftShift($E::Constant(1L), $E::Subtract($v.sh, (New-Int 1)))),
        $E::Assign($v.m, (New-Int 0)),
        (New-For $v.t (New-Int 0) $frames ($E::Assign($v.m, $E::Call($maxI, $v.m, $E::Call($absI, $window))))),
        $E::Assign($E::ArrayAccess($maxAbs, $v.o), $v.m),
        $E::Assign($v.all, $E::Call($maxI, $v.all, $v.m)))
    $vars = [ParameterExpression[]]@(@($v.Values) + $lowByte + $acc + $hb)
    $body = $E::Block([int], $vars,
        $E::Assign($lowByte, $E::NewArrayBounds([int], $E::ArrayLength($x))), $E::Assign($acc, $E::NewArrayBounds([int], $frames)),
        $E::Assign($v.all, (New-Int 0)), $fillL,
        (New-For $v.o (New-Int 0) $cout $perO), $v.all)
    $k = $E::Lambda([Func[float[], int, double, float[], int, int, int, int, double[], int[], int[], int]], $body, [ParameterExpression[]]@($x, $frames, $sX, $w, $cin, $cout, $K, $dil, $sW, $L, $maxAbs)).Compile()
    $script:Kernels.LowLowWindowShaped = $k; $k
}

function Get-Conv1dKernel {
    # (double[] x [i][t], int cin, int frames, double[] w [o][i][k], int cout, int K, int first, double[] y [o][t]):
    # y[o][t] = sum_i sum_k w[o][i][k] x[i][t + first + k], zero outside 0..frames-1. Build-time checks of
    # folded linear stages against stock captures.
    if ($script:Kernels.ContainsKey('Conv1d')) { return $script:Kernels.Conv1d }
    $E = [Expression]
    $x = $E::Parameter([double[]], 'x'); $cin = $E::Parameter([int], 'cin'); $frames = $E::Parameter([int], 'frames'); $w = $E::Parameter([double[]], 'w')
    $cout = $E::Parameter([int], 'cout'); $K = $E::Parameter([int], 'K'); $first = $E::Parameter([int], 'first'); $y = $E::Parameter([double[]], 'y')
    $o = $E::Variable([int], 'o'); $i = $E::Variable([int], 'i'); $tap = $E::Variable([int], 'tap'); $t = $E::Variable([int], 't')
    $tt = $E::Variable([int], 'tt'); $wv = $E::Variable([double], 'wv')
    $inner = $E::Block(
        $E::Assign($tt, $E::Add($E::Add($t, $first), $tap)),
        $E::IfThen($E::AndAlso($E::GreaterThanOrEqual($tt, (New-Int 0)), $E::LessThan($tt, $frames)),
            $E::AddAssign($E::ArrayAccess($y, $E::Add($E::Multiply($o, $frames), $t)), $E::Multiply($wv, $E::ArrayIndex($x, $E::Add($E::Multiply($i, $frames), $tt))))))
    $perTap = $E::Block(
        $E::Assign($wv, $E::ArrayIndex($w, $E::Add($E::Multiply($E::Add($E::Multiply($o, $cin), $i), $K), $tap))),
        $E::IfThen($E::NotEqual($wv, $E::Constant(0.0)), (New-For $t (New-Int 0) $frames $inner)))
    $body = $E::Block([ParameterExpression[]]@($o, $i, $tap, $t, $tt, $wv),
        (New-For $o (New-Int 0) $cout (New-For $i (New-Int 0) $cin (New-For $tap (New-Int 0) $K $perTap))))
    $k = $E::Lambda([Action[double[], int, int, double[], int, int, int, double[]]], $body, [ParameterExpression[]]@($x, $cin, $frames, $w, $cout, $K, $first, $y)).Compile()
    $script:Kernels.Conv1d = $k; $k
}

Export-ModuleMember -Function Get-FoldConvWeightsKernel, Get-QuantizeRowsKernel, Get-SplitPlanesKernel, Get-LowLowWindowShapedKernel, Get-Conv1dKernel, Get-PackWeightPlanesShapedKernel, Get-LowLowWindowKernel, Get-QuantizeCroutons16Kernel, Get-PackWeightPlanesKernel, Get-Mean3Kernel, Get-Croutons16ErrorKernel, Get-ChannelStatsKernel, Get-DecodeCroutons16Kernel, Get-InterleavePlanesKernel
