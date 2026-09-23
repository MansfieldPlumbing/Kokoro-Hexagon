#requires -Version 7.0
# Project-shaped DSP kernel probe: per-channel statistics over a real generator tensor (128 x 19,208 int16),
# in rpcmem shared memory, with the DSP reporting its own QTimer ticks so boundary cost and compute separate.
# ABI from qaic-generated kqnn_stub.c: noop mid 2 (0x02020100), stats mid 3 (0x03020200); remote_arg = 16 bytes.
$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$lines = [Collections.Generic.List[string]]::new(); $lines.Add("Pid=$([Environment]::ProcessId)"); $lines.Add('Job=kqnn-probe')
$M = [Runtime.InteropServices.Marshal]
$QTIMER_HZ = 19200000.0
try {
    $qnn = [IO.Path]::Combine($root, 'qnn')
    $dsp = (@($qnn, '/vendor/lib/rfsa/adsp', '/vendor/dsp/cdsp', '/dsp') -join ';')
    foreach ($v in 'ADSP_LIBRARY_PATH', 'DSP_LIBRARY_PATH') { [Environment]::SetEnvironmentVariable($v, $dsp); [Android.Systems.Os]::Setenv($v, $dsp, $true) }
    $abi = [scriptblock]::Create([IO.File]::ReadAllText([IO.Path]::Combine($root, 'modules', 'Qnn.Abi.psm1'))).InvokeReturnAsIs(@())
    $lib = [Runtime.InteropServices.NativeLibrary]::Load('libcdsprpc.so')
    $fn = { param([string]$n, [Type]$ret, [Type[]]$ptypes) $M::GetDelegateForFunctionPointer([Runtime.InteropServices.NativeLibrary]::GetExport($lib, $n), (& $abi.NewDelegateType ('Rpc_' + $n) $ret $ptypes)) }
    $ctl = & $fn 'remote_session_control' ([int]) ([Type[]]@([uint32], [IntPtr], [uint32]))
    $open = & $fn 'remote_handle64_open' ([int]) ([Type[]]@([IntPtr], ([uint64]).MakeByRefType()))
    $invoke = & $fn 'remote_handle64_invoke' ([int]) ([Type[]]@([uint64], [uint32], [IntPtr]))
    $close = & $fn 'remote_handle64_close' ([int]) ([Type[]]@([uint64]))
    $ralloc = & $fn 'rpcmem_alloc' ([IntPtr]) ([Type[]]@([int], [uint32], [int]))
    $rfree = & $fn 'rpcmem_free' ([void]) ([Type[]]@([IntPtr]))
    [void](& $fn 'rpcmem_init' ([void]) ([Type[]]@())).DynamicInvoke([object[]]@())

    $um = $M::AllocHGlobal(8); $M::WriteInt32($um, 0, 3); $M::WriteInt32($um, 4, 1)
    $lines.Add("UnsignedPdRc=$([int]$ctl.DynamicInvoke([object[]]@([uint32]2, $um, [uint32]8)))"); $M::FreeHGlobal($um)
    $up = $M::StringToHGlobalAnsi('file:///libkqnn_skel.so?kqnn_skel_handle_invoke&_modver=1.0&_dom=cdsp')
    $oa = [object[]]@($up, [uint64]0); $orc = [int]$open.DynamicInvoke($oa); $M::FreeHGlobal($up); [uint64]$h = $oa[1]
    $lines.Add("OpenRc=$orc")
    if ($orc -ne 0) { throw "remote_handle64_open rc=$orc" }
    try {
        [int]$C = 128; [int]$T = 19208; [int]$n = $C * $T                     # the last generator stage's tensor
        [byte[]]$xb = [IO.File]::ReadAllBytes([IO.Path]::Combine($root, 'kqnn_x.i16'))
        [byte[]]$eb = [IO.File]::ReadAllBytes([IO.Path]::Combine($root, 'kqnn_expected.i64'))
        if ($xb.Length -ne 2 * $n) { throw "test tensor bytes=$($xb.Length) expected=$(2 * $n)" }
        [long[]]$expSum = [long[]]::new($C); [long[]]$expSq = [long[]]::new($C)
        for ($c = 0; $c -lt $C; $c++) { $expSum[$c] = [BitConverter]::ToInt64($eb, 16 * $c); $expSq[$c] = [BitConverter]::ToInt64($eb, 16 * $c + 8) }
        $pX = [IntPtr]$ralloc.DynamicInvoke([object[]]@(25, [uint32]1, (2 * $n)))     # RPCMEM_HEAP_ID_SYSTEM, cached
        if ($pX -eq [IntPtr]::Zero) { throw 'rpcmem_alloc failed' }
        $M::Copy($xb, 0, $pX, $xb.Length)
        $pSums = [IntPtr]$ralloc.DynamicInvoke([object[]]@(25, [uint32]1, (16 * $C)))
        $pIn = $M::AllocHGlobal(12); $pTicks = $M::AllocHGlobal(8); $pra = $M::AllocHGlobal(64)
        try {
            $run = {
                param([uint32]$sc, [int]$nArgs, [int]$reps)
                [double[]]$ms = [double[]]::new($reps + 1); [double[]]$dsp = [double[]]::new($reps + 1)
                for ($k = 0; $k -le $reps; $k++) {
                    $M::WriteInt64($pTicks, 0, 0)
                    $sw = [Diagnostics.Stopwatch]::StartNew()
                    $rc = [int]$invoke.DynamicInvoke([object[]]@($h, $sc, $pra))
                    $ms[$k] = $sw.Elapsed.TotalMilliseconds
                    if ($rc -ne 0) { $lines.Add("InvokeRc=$rc sc=0x$($sc.ToString('X8')) echo0=$($M::ReadInt64($pSums,0)) echo1=$($M::ReadInt64($pSums,8)) echo2=$($M::ReadInt64($pSums,16))"); throw "invoke rc=$rc" }
                    $dsp[$k] = [double]$M::ReadInt64($pTicks, 0) * 1000.0 / $QTIMER_HZ
                }
                $w = $ms[1..$reps]; [Array]::Sort($w); $d = $dsp[1..$reps]; [Array]::Sort($d)
                [double]$sw1 = 0; foreach ($v in $w) { $sw1 += $v }; [double]$sd = 0; foreach ($v in $d) { $sd += $v }
                [pscustomobject]@{ WallMean = $sw1 / $reps; WallP50 = $w[[int](0.5 * ($reps - 1))]; DspMean = $sd / $reps }
            }
            # noop: pra[0] primIn{xLen}, pra[1] x, pra[2] primROut{ticks}
            $M::WriteInt32($pIn, 0, $n)
            $M::WriteIntPtr($pra, 0, $pIn);   $M::WriteInt64($pra, 8, 4)
            $M::WriteIntPtr($pra, 16, $pX);   $M::WriteInt64($pra, 24, [long](2 * $n))
            $M::WriteIntPtr($pra, 32, $pTicks); $M::WriteInt64($pra, 40, 8)
            $b = & $run ([uint32]0x02020100) 3 20
            $lines.Add(('Noop bytes={0} WallMeanMs={1:F2} WallP50Ms={2:F2} DspMeanMs={3:F3}' -f (2 * $n), $b.WallMean, $b.WallP50, $b.DspMean))
            # stats: primIn{xLen, channels, sumsLen}, pra[3] = sums out
            $M::WriteInt32($pIn, 0, $n); $M::WriteInt32($pIn, 4, $C); $M::WriteInt32($pIn, 8, 2 * $C)
            $M::WriteInt64($pra, 8, 12)
            $M::WriteIntPtr($pra, 48, $pSums); $M::WriteInt64($pra, 56, [long](16 * $C))
            $b = & $run ([uint32]0x03020200) 4 20
            [int]$bad = 0
            for ($c = 0; $c -lt $C; $c++) {
                if ($M::ReadInt64($pSums, 16 * $c) -ne $expSum[$c]) { $bad++ }
                if ($M::ReadInt64($pSums, 16 * $c + 8) -ne $expSq[$c]) { $bad++ }
            }
            $lines.Add(('Stats C={0} T={1} bytes={2} mismatches={3} WallMeanMs={4:F2} WallP50Ms={5:F2} DspMeanMs={6:F3}' -f $C, $T, (2 * $n), $bad, $b.WallMean, $b.WallP50, $b.DspMean))
            $lines.Add("Passed=$($bad -eq 0)")
        }
        finally { [void]$rfree.DynamicInvoke([object[]]@($pX)); [void]$rfree.DynamicInvoke([object[]]@($pSums)); foreach ($p in $pIn, $pTicks, $pra) { $M::FreeHGlobal($p) } }
    }
    finally { $lines.Add("CloseRc=$([int]$close.DynamicInvoke([object[]]@($h)))") }
}
catch { $lines.Add('Passed=False'); $lines.Add("Error=$($_.Exception.Message)"); $lines.Add("At=$($_.InvocationInfo.PositionMessage -replace '\s+', ' ')") }
[IO.File]::WriteAllLines([IO.Path]::Combine($root, 'receipt.txt'), $lines)
[void][Android.Util.Log]::Info('KokoroRpc', ($lines -join ' | '))
