#requires -Version 7.0
# Emit generator resblock 3 (r0) through the QNN C API from weights read out of the Kokoro
# checkpoint, run it on in_z, and score it against oracle_r0. No ONNX, no Python.
#
# AdaINResBlock1 is three passes of: AdaIN -> Snake -> Conv(dilation d) -> AdaIN -> Snake ->
# Conv(dilation 1) -> residual add, with d = 1, 3, 5.
#
# Masked AdaIN, matching the exported reference:
#   k  = W / sum(m)            (constant: the mask is fixed)
#   mu = mean(x*m) * k
#   sc = max(|(x-mu)*m|) + 1e-6      per channel, fp16 headroom only; it cancels algebraically
#   c  = (x-mu)/sc
#   vs = mean((c*m)^2) * k
#   y  = c * rsqrt(vs + eps/sc^2)
#   out = ((1+gamma)*y + beta) * m
# Snake: x + (1/a) * sin(a*x)^2, built from Mul/Sin/Mul/Mul/Add so no Pow is involved.
$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$receiptPath = [IO.Path]::Combine($root, 'receipt.txt')
$lines = [Collections.Generic.List[string]]::new()
$flush = { [IO.File]::WriteAllLines($receiptPath, $lines) }
$lines.Add("Pid=$([Environment]::ProcessId)"); $lines.Add('Job=r0emit')
try {
    $qnn = [IO.Path]::Combine($root, 'qnn')
    $dsp = (@($qnn, '/vendor/lib/rfsa/adsp', '/vendor/dsp/cdsp', '/dsp') -join ';')
    foreach ($v in 'ADSP_LIBRARY_PATH', 'DSP_LIBRARY_PATH') { [Environment]::SetEnvironmentVariable($v, $dsp); [Android.Systems.Os]::Setenv($v, $dsp, $true) }
    foreach ($so in 'libQnnHtpV73Stub.so', 'libQnnHtp.so') { [void][Runtime.InteropServices.NativeLibrary]::Load([IO.Path]::Combine($qnn, $so)) }
    $mr = [IO.Path]::Combine($root, 'r009-modules')
    $load = { param([string]$nm, [object[]]$a) [scriptblock]::Create([IO.File]::ReadAllText([IO.Path]::Combine($mr, $nm))).InvokeReturnAsIs($a) }
    $binding = & $load 'Native.Binding.psm1' ([object[]]@())
    $abi = & $load 'Qnn.Abi.psm1' ([object[]]@($binding))
    $native = & $load 'Qnn.Native.psm1' ([object[]]@($abi))
    $graph = & $load 'Qnn.Graph.psm1' ([object[]]@($abi, $native))
    [void](& $native.Initialize ([pscustomobject]@{ DataRoot = $qnn; NativeLibraryDirectory = $qnn }))
    $lines.Add('Init=ok'); & $flush

    $dd = [IO.Path]::Combine($root, 'r0')
    [byte[]]$statics = [IO.File]::ReadAllBytes([IO.Path]::Combine($dd, 'r0_static.bin'))
    [byte[]]$zBytes  = [IO.File]::ReadAllBytes([IO.Path]::Combine($dd, 'in_z.f32'))
    [byte[]]$mBytes  = [IO.File]::ReadAllBytes([IO.Path]::Combine($dd, 'in_mask1.f32'))
    [byte[]]$oBytes  = [IO.File]::ReadAllBytes([IO.Path]::Combine($dd, 'oracle_r0.f32'))
    [int]$Cch = 128
    [int]$Tlen = [int]($mBytes.Length / 4)
    if ($zBytes.Length -ne $Cch * $Tlen * 4) { throw "z bytes $($zBytes.Length) for C=$Cch T=$Tlen" }
    [int]$TILE = [int]$env:R0_TILE; if ($TILE -le 0) { $TILE = $Cch }
    $lines.Add("Shape C=$Cch T=$Tlen tile=$TILE"); & $flush

    # Fixed layout written by tools/Prepare-Resblock.ps1.
    $off = [Collections.Specialized.OrderedDictionary]::new()
    [int]$p = 0
    foreach ($set in 'convs1', 'convs2') { for ([int]$j = 0; $j -lt 3; $j++) {
        $off["$set.$j.weight"] = $p; $p += $Cch * $Cch * 3 * 4
        $off["$set.$j.bias"]   = $p; $p += $Cch * 4 } }
    foreach ($set in 'adain1', 'adain2') { for ([int]$j = 0; $j -lt 3; $j++) {
        $off["$set.$j.gain"]  = $p; $p += $Cch * 4
        $off["$set.$j.shift"] = $p; $p += $Cch * 4 } }
    foreach ($set in 'alpha1', 'alpha2') { for ([int]$j = 0; $j -lt 3; $j++) {
        $off["$set.$j"]     = $p; $p += $Cch * 4
        $off["$set.$j.inv"] = $p; $p += $Cch * 4 } }
    if ($p -ne $statics.Length) { throw "static layout $p vs file $($statics.Length)" }

    $slice = { param([string]$n, [int]$bytes) [byte[]]$b = [byte[]]::new($bytes); [Array]::Copy($statics, $off[$n], $b, 0, $bytes); , $b }
    $chan = { param([byte[]]$src, [int]$c0, [int]$n) [byte[]]$b = [byte[]]::new($n * 4); [Array]::Copy($src, $c0 * 4, $b, 0, $n * 4); , $b }
    $f32one = { param([float]$v) [byte[]]$b = [byte[]]::new(4); [Buffer]::BlockCopy([float[]]@($v), 0, $b, 0, 4); , $b }

    # k = W / sum(mask), a constant because the mask is fixed for the phrase.
    [double]$msum = 0
    for ([int]$i = 0; $i -lt $Tlen; $i++) { $msum += [BitConverter]::ToSingle($mBytes, $i * 4) }
    [float]$kval = [float]($Tlen / $msum)
    $lines.Add("maskSum=$msum k=$kval"); & $flush

    $trial = & $native.NewTrial 'R0_GRAPH' @(@{ Option = [int]$abi.Enum.HtpVtcmSizeMb; Value = 8 })
    $arena = & $graph.NewArena
    $nOps = 0
    $reg = { param($t) $r = & $graph.RegisterTensor $trial $t; if ($r.Rc -ne 0 -or $r.Id -eq 0) { throw "reg $($t.Name) rc=$($r.Rc)" }; $t }
    $stat = { param([string]$n, [int[]]$shape, [byte[]]$data) & $reg (& $graph.NewTensor $arena $n ([int]$abi.Enum.Static) ([int]$abi.Enum.Float32) $shape $data $null) }
    $nat  = { param([string]$n, [int[]]$shape) & $reg (& $graph.NewTensor $arena $n ([int]$abi.Enum.Native) ([int]$abi.Enum.Float32) $shape $null $null) }
    $node = { param([string]$n, [string]$type, [object[]]$i, [object[]]$o, [IntPtr[]]$prm)
              $op = & $graph.NewOp $arena $n $type $i $o $prm
              [uint64]$rc = & $graph.AddNode $trial $op
              if ($rc -ne 0) { throw "$n ($type) rc=$rc" }
              $script:nOps++ }
    $axesT = & $reg (& $graph.NewTensor $arena 'axes2' ([int]$abi.Enum.Static) ([int]$abi.Enum.UInt32) ([int[]]@(1)) ([byte[]]@(2,0,0,0)) $null)
    $reduce = { param([string]$n, [string]$type, $src, $dst)
                $pa = & $graph.NewTensorParam $arena 'axes' $axesT
                $pk = & $graph.NewScalarBoolParam $arena 'keep_dims' $true
                & $node $n $type @($src) @($dst) ([IntPtr[]]@($pa, $pk)) }

    $X = & $reg (& $graph.NewTensor $arena 'z' ([int]$abi.Enum.AppWrite) ([int]$abi.Enum.Float32) ([int[]]@(1, $Cch, $Tlen)) $null $null)
    $M = & $reg (& $graph.NewTensor $arena 'mask' ([int]$abi.Enum.AppWrite) ([int]$abi.Enum.Float32) ([int[]]@(1, 1, $Tlen)) $null $null)
    $kT   = & $stat 'k'    ([int[]]@(1,1,1)) (& $f32one $kval)
    $epsT = & $stat 'eps'  ([int[]]@(1,1,1)) (& $f32one ([float]1e-5))
    $tiny = & $stat 'tiny' ([int[]]@(1,1,1)) (& $f32one ([float]1e-6))

    # One masked AdaIN followed by Snake, over a channel slice.
    $adainSnake = {
        param([string]$tag, $src, [int]$c0, [int]$n, [byte[]]$gain, [byte[]]$shift, [byte[]]$alpha, [byte[]]$ainv)
        $sh3 = [int[]]@(1, $n, $Tlen); $sh1 = [int[]]@(1, $n, 1)
        $g  = & $stat "$tag.g"  $sh1 $gain
        $b  = & $stat "$tag.b"  $sh1 $shift
        $a  = & $stat "$tag.a"  $sh1 $alpha
        $ai = & $stat "$tag.ai" $sh1 $ainv
        $xm = & $nat "$tag.xm" $sh3;   & $node "$tag.n1" 'ElementWiseMultiply' @($src, $M) @($xm) ([IntPtr[]]@())
        $mn = & $nat "$tag.mn" $sh1;   & $reduce "$tag.n2" 'ReduceMean' $xm $mn
        $mu = & $nat "$tag.mu" $sh1;   & $node "$tag.n3" 'ElementWiseMultiply' @($mn, $kT) @($mu) ([IntPtr[]]@())
        $d  = & $nat "$tag.d"  $sh3;   & $node "$tag.n4" 'ElementWiseSubtract' @($src, $mu) @($d) ([IntPtr[]]@())
        $dm = & $nat "$tag.dm" $sh3;   & $node "$tag.n5" 'ElementWiseMultiply' @($d, $M) @($dm) ([IntPtr[]]@())
        $ad = & $nat "$tag.ad" $sh3;   & $node "$tag.n6" 'ElementWiseAbs' @($dm) @($ad) ([IntPtr[]]@())
        $mx = & $nat "$tag.mx" $sh1;   & $reduce "$tag.n7" 'ReduceMax' $ad $mx
        $sc = & $nat "$tag.sc" $sh1;   & $node "$tag.n8" 'ElementWiseAdd' @($mx, $tiny) @($sc) ([IntPtr[]]@())
        $c  = & $nat "$tag.c"  $sh3;   & $node "$tag.n9" 'ElementWiseDivide' @($d, $sc) @($c) ([IntPtr[]]@())
        $cm = & $nat "$tag.cm" $sh3;   & $node "$tag.n10" 'ElementWiseMultiply' @($c, $M) @($cm) ([IntPtr[]]@())
        $c2 = & $nat "$tag.c2" $sh3;   & $node "$tag.n11" 'ElementWiseMultiply' @($cm, $cm) @($c2) ([IntPtr[]]@())
        $vm = & $nat "$tag.vm" $sh1;   & $reduce "$tag.n12" 'ReduceMean' $c2 $vm
        $vs = & $nat "$tag.vs" $sh1;   & $node "$tag.n13" 'ElementWiseMultiply' @($vm, $kT) @($vs) ([IntPtr[]]@())
        $s2 = & $nat "$tag.s2" $sh1;   & $node "$tag.n14" 'ElementWiseMultiply' @($sc, $sc) @($s2) ([IntPtr[]]@())
        $e2 = & $nat "$tag.e2" $sh1;   & $node "$tag.n15" 'ElementWiseDivide' @($epsT, $s2) @($e2) ([IntPtr[]]@())
        $vv = & $nat "$tag.vv" $sh1;   & $node "$tag.n16" 'ElementWiseAdd' @($vs, $e2) @($vv) ([IntPtr[]]@())
        $rs = & $nat "$tag.rs" $sh1;   & $node "$tag.n17" 'ElementWiseRsqrt' @($vv) @($rs) ([IntPtr[]]@())
        $y  = & $nat "$tag.y"  $sh3;   & $node "$tag.n18" 'ElementWiseMultiply' @($c, $rs) @($y) ([IntPtr[]]@())
        $yg = & $nat "$tag.yg" $sh3;   & $node "$tag.n19" 'ElementWiseMultiply' @($y, $g) @($yg) ([IntPtr[]]@())
        $yb = & $nat "$tag.yb" $sh3;   & $node "$tag.n20" 'ElementWiseAdd' @($yg, $b) @($yb) ([IntPtr[]]@())
        $am = & $nat "$tag.am" $sh3;   & $node "$tag.n21" 'ElementWiseMultiply' @($yb, $M) @($am) ([IntPtr[]]@())
        # Snake: am + (1/a) * sin(a*am)^2
        $t1 = & $nat "$tag.t1" $sh3;   & $node "$tag.n22" 'ElementWiseMultiply' @($am, $a) @($t1) ([IntPtr[]]@())
        $t2 = & $nat "$tag.t2" $sh3;   & $node "$tag.n23" 'ElementWiseSin' @($t1) @($t2) ([IntPtr[]]@())
        $t3 = & $nat "$tag.t3" $sh3;   & $node "$tag.n24" 'ElementWiseMultiply' @($t2, $t2) @($t3) ([IntPtr[]]@())
        $t4 = & $nat "$tag.t4" $sh3;   & $node "$tag.n25" 'ElementWiseMultiply' @($t3, $ai) @($t4) ([IntPtr[]]@())
        $t5 = & $nat "$tag.t5" $sh3;   & $node "$tag.n26" 'ElementWiseAdd' @($am, $t4) @($t5) ([IntPtr[]]@())
        $t5
    }

    # AdaIN + Snake over all channels, tiled if asked, concatenated back for the convolution.
    $block = {
        param([string]$tag, $src, [string]$set, [int]$j)
        [byte[]]$gain  = & $slice "$set.$j.gain"  ($Cch * 4)
        [byte[]]$shift = & $slice "$set.$j.shift" ($Cch * 4)
        [byte[]]$alp   = & $slice (($set -replace 'adain', 'alpha') + ".$j") ($Cch * 4)
        [byte[]]$ainv  = & $slice (($set -replace 'adain', 'alpha') + ".$j.inv") ($Cch * 4)
        if ($TILE -ge $Cch) { return & $adainSnake "$tag.w" $src 0 $Cch $gain $shift $alp $ainv }
        $parts = [Collections.Generic.List[object]]::new()
        for ([int]$c0 = 0; $c0 -lt $Cch; $c0 += $TILE) {
            $sl = & $nat "$tag.sl$c0" ([int[]]@(1, $TILE, $Tlen))
            $rngs = & $reg (& $graph.NewTensor $arena "$tag.rng$c0" ([int]$abi.Enum.Static) ([int]$abi.Enum.UInt32) ([int[]]@(3, 3)) (& $u32ranges $c0) $null)
            $pr = & $graph.NewTensorParam $arena 'ranges' $rngs
            & $node "$tag.sub$c0" 'StridedSlice' @($src) @($sl) ([IntPtr[]]@($pr))
            [void]$parts.Add((& $adainSnake "$tag.t$c0" $sl $c0 $TILE (& $chan $gain $c0 $TILE) (& $chan $shift $c0 $TILE) (& $chan $alp $c0 $TILE) (& $chan $ainv $c0 $TILE)))
        }
        $cat = & $nat "$tag.cat" ([int[]]@(1, $Cch, $Tlen))
        $pa = & $graph.NewScalarUInt32Param $arena 'axis' 1
        & $node "$tag.cc" 'Concat' $parts.ToArray() @($cat) ([IntPtr[]]@($pa))
        $cat
    }

    $u32ranges = { param([int]$c0)
        [uint32[]]$r = @(0,1,1, [uint32]$c0,[uint32]($c0+$TILE),1, 0,[uint32]$Tlen,1)
        [byte[]]$b = [byte[]]::new(36); [Buffer]::BlockCopy($r, 0, $b, 0, 36); , $b }

    # Conv1d as Conv2d over [1,1,T,C]; dilation and padding act on the time axis.
    $conv = {
        param([string]$tag, $src, [string]$set, [int]$j, [int]$dil)
        $perm1 = & $reg (& $graph.NewTensor $arena "$tag.p1" ([int]$abi.Enum.Static) ([int]$abi.Enum.UInt32) ([int[]]@(3)) ([byte[]]@(0,0,0,0, 2,0,0,0, 1,0,0,0)) $null)
        $tr = & $nat "$tag.tr" ([int[]]@(1, $Tlen, $Cch))
        & $node "$tag.t1" 'Transpose' @($src) @($tr) ([IntPtr[]]@((& $graph.NewTensorParam $arena 'perm' $perm1)))
        $r4 = & $nat "$tag.r4" ([int[]]@(1, 1, $Tlen, $Cch))
        & $node "$tag.rs1" 'Reshape' @($tr) @($r4) ([IntPtr[]]@())
        $w = & $stat "$tag.w" ([int[]]@(1, 3, $Cch, $Cch)) (& $slice "$set.$j.weight" ($Cch * $Cch * 3 * 4))
        $b = & $stat "$tag.b" ([int[]]@($Cch)) (& $slice "$set.$j.bias" ($Cch * 4))
        [byte[]]$dilB = [byte[]]::new(8); [Buffer]::BlockCopy([uint32[]]@(1, [uint32]$dil), 0, $dilB, 0, 8)
        [byte[]]$strB = [byte[]]::new(8); [Buffer]::BlockCopy([uint32[]]@(1, 1), 0, $strB, 0, 8)
        [byte[]]$padB = [byte[]]::new(16); [Buffer]::BlockCopy([uint32[]]@(0, 0, [uint32]$dil, [uint32]$dil), 0, $padB, 0, 16)
        $dT = & $reg (& $graph.NewTensor $arena "$tag.d" ([int]$abi.Enum.Static) ([int]$abi.Enum.UInt32) ([int[]]@(2)) $dilB $null)
        $sT = & $reg (& $graph.NewTensor $arena "$tag.s" ([int]$abi.Enum.Static) ([int]$abi.Enum.UInt32) ([int[]]@(2)) $strB $null)
        $pT = & $reg (& $graph.NewTensor $arena "$tag.p" ([int]$abi.Enum.Static) ([int]$abi.Enum.UInt32) ([int[]]@(2,2)) $padB $null)
        $out4 = & $nat "$tag.o4" ([int[]]@(1, 1, $Tlen, $Cch))
        & $node "$tag.cv" 'Conv2d' @($r4, $w, $b) @($out4) ([IntPtr[]]@(
            (& $graph.NewScalarUInt32Param $arena 'group' 1),
            (& $graph.NewTensorParam $arena 'dilation' $dT),
            (& $graph.NewTensorParam $arena 'stride' $sT),
            (& $graph.NewTensorParam $arena 'pad_amount' $pT)))
        $o3 = & $nat "$tag.o3" ([int[]]@(1, $Tlen, $Cch))
        & $node "$tag.rs2" 'Reshape' @($out4) @($o3) ([IntPtr[]]@())
        $perm2 = & $reg (& $graph.NewTensor $arena "$tag.p2" ([int]$abi.Enum.Static) ([int]$abi.Enum.UInt32) ([int[]]@(3)) ([byte[]]@(0,0,0,0, 2,0,0,0, 1,0,0,0)) $null)
        $back = & $nat "$tag.bk" ([int[]]@(1, $Cch, $Tlen))
        & $node "$tag.t2" 'Transpose' @($o3) @($back) ([IntPtr[]]@((& $graph.NewTensorParam $arena 'perm' $perm2)))
        $back
    }

    [int[]]$dils = @(1, 3, 5)
    $cur = $X
    for ([int]$j = 0; $j -lt 3; $j++) {
        $a1 = & $block "b$j.a1" $cur 'adain1' $j
        $c1 = & $conv  "b$j.c1" $a1 'convs1' $j $dils[$j]
        $a2 = & $block "b$j.a2" $c1 'adain2' $j
        $c2 = & $conv  "b$j.c2" $a2 'convs2' $j 1
        [bool]$last = ($j -eq 2)
        $sum = if ($last) { & $reg (& $graph.NewTensor $arena 'r0' ([int]$abi.Enum.AppRead) ([int]$abi.Enum.Float32) ([int[]]@(1, $Cch, $Tlen)) $null $null) }
               else { & $nat "b$j.sum" ([int[]]@(1, $Cch, $Tlen)) }
        & $node "b$j.res" 'ElementWiseAdd' @($c2, $cur) @($sum) ([IntPtr[]]@())
        $cur = $sum
    }
    $lines.Add("Ops=$nOps"); & $flush

    [uint64]$fin = & $graph.Finalize $trial
    $lines.Add("FinalizeRc=$fin"); & $flush
    if ($fin -ne 0) { throw "finalize rc=$fin" }
    [int]$ctxBytes = (& $graph.SerializeContext $trial $arena).Length

    $xi = & $graph.NewExecTensor $arena $X $zBytes
    $mi = & $graph.NewExecTensor $arena $M $mBytes
    [byte[]]$outB = [byte[]]::new($Cch * $Tlen * 4)
    $yo = & $graph.NewExecTensor $arena $cur $outB
    [double[]]$ms = [double[]]::new(8)
    for ([int]$r = 0; $r -lt 8; $r++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        [uint64]$erc = & $graph.Execute $trial $arena ([object[]]@($xi, $mi)) ([object[]]@($yo))
        $ms[$r] = $sw.Elapsed.TotalMilliseconds
        if ($erc -ne 0) { throw "execute rc=$erc" }
    }
    [Runtime.InteropServices.Marshal]::Copy($yo.DataPtr, $outB, 0, $outB.Length)
    [double[]]$warm = $ms[2..7]; [Array]::Sort($warm)
    [double]$sum2 = 0; foreach ($v in $warm) { $sum2 += $v }

    [double]$se = 0; [double]$sr = 0; [double]$mx = 0; [int]$bad = 0
    for ([int]$i = 0; $i -lt $Cch * $Tlen; $i++) {
        [double]$a = [BitConverter]::ToSingle($outB, $i * 4)
        [double]$b = [BitConverter]::ToSingle($oBytes, $i * 4)
        if (-not [double]::IsFinite($a)) { $bad++ }
        [double]$d = $a - $b; $se += $d * $d; $sr += $b * $b
        if ([Math]::Abs($d) -gt $mx) { $mx = [Math]::Abs($d) }
    }
    [double]$snr = if ($se -gt 0) { 10 * [Math]::Log10($sr / $se) } else { 999 }
    $lines.Add(('Result ops={0} ctxBytes={1} meanMs={2:F1} minMs={3:F1} snrDb={4:F2} maxAbs={5:E3} nonFinite={6}' -f $nOps, $ctxBytes, ($sum2 / $warm.Length), $warm[0], $snr, $mx, $bad))
    $lines.Add("Passed=$($snr -gt 20 -and $bad -eq 0)"); & $flush
    [void](& $native.CloseTrial $trial)
}
catch { $lines.Add('Passed=False'); $lines.Add("Error=$($_.Exception.Message)"); & $flush }
[void][Android.Util.Log]::Info('KokoroRpc', ($lines -join ' | '))
