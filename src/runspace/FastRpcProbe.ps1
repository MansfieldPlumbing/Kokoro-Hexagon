#requires -Version 7.0
# FastRPC from the AndroidSMA runspace: unsigned PD on cDSP, open a V73 skel by URI, call sum, time it.
# ABI from Hexagon SDK 6.4.0.2 incs/remote.h and qaic-generated calculator_stub.c.
$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$lines = [Collections.Generic.List[string]]::new(); $lines.Add("Pid=$([Environment]::ProcessId)"); $lines.Add('Job=fastrpc-probe')
$M = [Runtime.InteropServices.Marshal]
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

    # Unsigned PD: DSPRPC_CONTROL_UNSIGNED_MODULE = 2, struct { int domain; int enable; }, CDSP_DOMAIN_ID = 3.
    $um = $M::AllocHGlobal(8); $M::WriteInt32($um, 0, 3); $M::WriteInt32($um, 4, 1)
    $crc = [int]$ctl.DynamicInvoke([object[]]@([uint32]2, $um, [uint32]8)); $M::FreeHGlobal($um)
    $lines.Add("UnsignedPdRc=$crc")

    $uri = 'file:///libcalculator_skel.so?calculator_skel_handle_invoke&_modver=1.0&_idlver=1.2.3&_dom=cdsp'
    $up = $M::StringToHGlobalAnsi($uri)
    $oa = [object[]]@($up, [uint64]0); $orc = [int]$open.DynamicInvoke($oa); $M::FreeHGlobal($up); [uint64]$h = $oa[1]
    $lines.Add("OpenRc=$orc Handle=$(if ($h) { 'set' } else { 'zero' })")
    if ($orc -ne 0) { throw "remote_handle64_open rc=$orc" }
    try {
        # calculator_sum(h, const int* vec, int vecLen, int64* res): mid 2, 2 in, 1 out -> REMOTE_SCALARS_MAKEX(0,2,2,1,0,0) = 0x02020100.
        # remote_arg[3], each { void* pv; size_t nLen; } = 16 bytes: [0] primIn {vecLen}, [1] vec, [2] primROut {res}.
        foreach ($n in 1000, 2458624) {
            [int[]]$vec = [int[]]::new($n); [long]$expected = 0
            for ($i = 0; $i -lt $n; $i++) { $vec[$i] = ($i % 1000) - 500; $expected += $vec[$i] }
            $pVec = $M::AllocHGlobal(4 * $n); $M::Copy($vec, 0, $pVec, $n)
            $pIn = $M::AllocHGlobal(4); $M::WriteInt32($pIn, 0, $n)
            $pOut = $M::AllocHGlobal(8); $pra = $M::AllocHGlobal(48)
            try {
                $M::WriteIntPtr($pra, 0, $pIn);  $M::WriteInt64($pra, 8, 4)
                $M::WriteIntPtr($pra, 16, $pVec); $M::WriteInt64($pra, 24, [long](4 * $n))
                $M::WriteIntPtr($pra, 32, $pOut); $M::WriteInt64($pra, 40, 8)
                [double[]]$ms = [double[]]::new(21); [long]$got = 0; [int]$bad = 0
                for ($k = 0; $k -lt 21; $k++) {
                    $M::WriteInt64($pOut, 0, 0)
                    $sw = [Diagnostics.Stopwatch]::StartNew()
                    $irc = [int]$invoke.DynamicInvoke([object[]]@($h, [uint32]0x02020100, $pra))
                    $ms[$k] = $sw.Elapsed.TotalMilliseconds
                    if ($irc -ne 0) { throw "invoke rc=$irc n=$n" }
                    $got = $M::ReadInt64($pOut, 0); if ($got -ne $expected) { $bad++ }
                }
                [double[]]$warm = $ms[1..20]; [Array]::Sort($warm); [double]$sum = 0; foreach ($v in $warm) { $sum += $v }
                $lines.Add(('Sum n={0} bytes={1} expected={2} got={3} mismatches={4} FirstMs={5:F2} WarmMeanMs={6:F2} P50Ms={7:F2} P95Ms={8:F2}' -f $n, (4 * $n), $expected, $got, $bad, $ms[0], ($sum / 20), $warm[9], $warm[18]))
            }
            finally { foreach ($p in $pVec, $pIn, $pOut, $pra) { $M::FreeHGlobal($p) } }
        }
        $lines.Add('Passed=True')
    }
    finally { $lines.Add("CloseRc=$([int]$close.DynamicInvoke([object[]]@($h)))") }
}
catch { $lines.Add('Passed=False'); $lines.Add("Error=$($_.Exception.Message)"); $lines.Add("At=$($_.InvocationInfo.PositionMessage -replace '\s+', ' ')") }
[IO.File]::WriteAllLines([IO.Path]::Combine($root, 'receipt.txt'), $lines)
[void][Android.Util.Log]::Info('KokoroRpc', ($lines -join ' | '))
