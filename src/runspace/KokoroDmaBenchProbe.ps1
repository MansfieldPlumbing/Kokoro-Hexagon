#requires -Version 7.0
# Device harness for the emitted DMA bench skel (src/hexagon/Kokoro.DmaBenchProbe.ps1).
# One unsigned-PD session, one handle; method 2 (sc 0x02010100), three invocations of one
# native tensor (244 tiles x 8192 B) with fresh random data each time.
$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$dir = [IO.Path]::Combine($root, 'dma-bench')
$receipt = [IO.Path]::Combine($dir, 'receipt.txt')
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('Job=kokoro-dma-bench')
$Marshal = [Runtime.InteropServices.Marshal]; $native = [IntPtr]::Zero; $opened = $false; $handle = [uint64]0
$pins = [Collections.Generic.List[object]]::new(); $allocations = [Collections.Generic.List[object]]::new()
$passed = $false
try {
    $ast = [Management.Automation.Language.Parser]::ParseFile([IO.Path]::Combine($root, 'Native.Binding.psm1'), [ref]$null, [ref]$null)
    $abi = $ast.GetScriptBlock().InvokeReturnAsIs()
    $so = [IO.Path]::Combine($root, 'qnn', 'libkokoro_dma_bench_skel.so')
    $lines.Add('LibrarySHA256=' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($so))))
    $search = [IO.Path]::Combine($root, 'qnn') + ';/vendor/lib/rfsa/adsp;/vendor/dsp/cdsp;/dsp'
    foreach ($name in 'ADSP_LIBRARY_PATH', 'DSP_LIBRARY_PATH') {
        [Environment]::SetEnvironmentVariable($name, $search)
        [Android.Systems.Os]::Setenv($name, $search, $true)
    }
    $native = [Runtime.InteropServices.NativeLibrary]::Load('libcdsprpc.so')
    $fn = { param($Name, $ReturnType, $Parameters)
        $Marshal::GetDelegateForFunctionPointer([Runtime.InteropServices.NativeLibrary]::GetExport($native, $Name),
            (& $abi.NewDelegateType ('DmaBench_' + $Name) $ReturnType $Parameters))
    }
    $control = & $fn 'remote_session_control' ([int]) ([Type[]]@([uint32], [IntPtr], [uint32]))
    $open    = & $fn 'remote_handle64_open'    ([int]) ([Type[]]@([IntPtr], ([uint64]).MakeByRefType()))
    $invoke  = & $fn 'remote_handle64_invoke'  ([int]) ([Type[]]@([uint64], [uint32], [IntPtr]))
    $close   = & $fn 'remote_handle64_close'   ([int]) ([Type[]]@([uint64]))
    $pin = { param([byte[]]$Bytes)
        $g = [Runtime.InteropServices.GCHandle]::Alloc($Bytes, [Runtime.InteropServices.GCHandleType]::Pinned)
        $pins.Add($g); $g.AddrOfPinnedObject()
    }

    $cfg = $Marshal::AllocHGlobal(8); $allocations.Add($cfg)
    $Marshal::WriteInt32($cfg, 0, 3); $Marshal::WriteInt32($cfg, 4, 1)
    $rc = [int]$control.DynamicInvoke([object[]]@([uint32]2, $cfg, [uint32]8))
    $lines.Add("UnsignedPdRc=$rc"); if ($rc -ne 0) { throw 'Unsigned PD configuration failed' }

    $uri = [Text.Encoding]::UTF8.GetBytes('file:///libkokoro_dma_bench_skel.so?kokoro_dma_bench_skel_handle_invoke&_modver=1.0&_dom=cdsp' + [char]0)
    $oa = [object[]]@((& $pin $uri), [uint64]0)
    $rc = [int]$open.DynamicInvoke($oa)
    $lines.Add("OpenRc=$rc"); if ($rc -ne 0) { throw 'Kernel library open failed' }
    $handle = [uint64]$oa[1]; $opened = $true

    $bytes = 244 * 8192; $reps = 8
    $good = 0
    for ($run = 0; $run -lt 3; $run++) {
        $in = [byte[]]::new(128 + $bytes)
        [BitConverter]::GetBytes([uint32]$bytes).CopyTo($in, 0); [BitConverter]::GetBytes([uint32]$reps).CopyTo($in, 4)
        [Array]::Copy([Security.Cryptography.RandomNumberGenerator]::GetBytes($bytes), 0, $in, 128, $bytes)
        $out = [byte[]]::new(256 + 2 * $bytes)
        $argBlock = $Marshal::AllocHGlobal(32); $allocations.Add($argBlock)
        $Marshal::WriteIntPtr($argBlock, 0, (& $pin $in)); $Marshal::WriteInt64($argBlock, 8, [long]$in.Length)
        $Marshal::WriteIntPtr($argBlock, 16, (& $pin $out)); $Marshal::WriteInt64($argBlock, 24, [long]$out.Length)
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $rc = [int]$invoke.DynamicInvoke([object[]]@($handle, [uint32]0x02010100, $argBlock))
        $hostMs = $watch.Elapsed.TotalMilliseconds
        $u = { param([int]$o) [BitConverter]::ToUInt32($out, $o) }
        $sha = [Security.Cryptography.SHA256]::Create(); $source = [Convert]::ToHexString($sha.ComputeHash($in, 128, $bytes))
        $dmaEqual = $source -eq [Convert]::ToHexString($sha.ComputeHash($out, 256, $bytes))
        $copyEqual = $source -eq [Convert]::ToHexString($sha.ComputeHash($out, 256 + $bytes, $bytes)); $sha.Dispose()
        $ms = { param([int]$o) [math]::Round((& $u $o) / 19200.0 / $reps, 3) }
        $gbs = { param([int]$o) $t = & $u $o; if ($t) { [math]::Round($bytes * $reps / ($t / 19.2e6) / 1e9, 2) } else { 0 } }
        $lines.Add(("Run={0} InvokeRc={1} Stage={2} QueryRc={3} PowerRc={4} Ctx={5} GrantedBytes={6} DmaInCheck=0x{7:X8} DmaStatus=0x{8:X8} ReleaseRc={9} DmaOutEqual={10} MemcpyOutEqual={11} HostMs={12:F1}" -f
            $run, $rc, (& $u 0), [BitConverter]::ToInt32($out, 28), [BitConverter]::ToInt32($out, 4), (& $u 8), (& $u 12), (& $u 16), (& $u 24),
            [BitConverter]::ToInt32($out, 20), $dmaEqual, $copyEqual, $hostMs))
        $lines.Add(("Run={0} Bytes={1} Reps={2} MemcpyInMs={3} DmaInMs={4} MemcpyOutMs={5} DmaOutMs={6} MemcpyInGBs={7} DmaInGBs={8} MemcpyOutGBs={9} DmaOutGBs={10}" -f
            $run, $bytes, $reps, (& $ms 32), (& $ms 36), (& $ms 40), (& $ms 44), (& $gbs 32), (& $gbs 36), (& $gbs 40), (& $gbs 44)))
        $lines.Add(("Run={0} CheckedDmaInMs={1} CheckedDmaOutMs={2} CheckedDmaInGBs={3} CheckedDmaOutGBs={4} InDoneBits={5} InLastWordXor=0x{6:X8} OutDoneBits={7} OutLastWordXor=0x{8:X8}" -f $run, [math]::Round((& $u 48) / 19200.0, 3), [math]::Round((& $u 52) / 19200.0, 3), [math]::Round($bytes / ((& $u 48) / 19.2e6) / 1e9, 2), [math]::Round($bytes / ((& $u 52) / 19.2e6) / 1e9, 2), (& $u 56), (& $u 60), (& $u 64), (& $u 68)))
        if ($rc -eq 0 -and (& $u 56) -eq 3 -and (& $u 60) -eq 0 -and (& $u 64) -eq 3 -and (& $u 68) -eq 0 -and (& $u 0) -eq 7 -and (& $u 16) -eq 0 -and $dmaEqual -and $copyEqual -and [BitConverter]::ToInt32($out, 20) -eq 0) { $good++ }
        [IO.File]::WriteAllLines($receipt, $lines)
        if ($rc -ne 0) { break }
    }
    $passed = $good -eq 3
}
catch { $lines.Add('Error=' + $_.Exception.Message.Replace("`r", ' ').Replace("`n", ' ')) }
finally {
    if ($opened) { $null = $close.DynamicInvoke([object[]]@($handle)) }
    foreach ($g in $pins) { $g.Free() }
    foreach ($a in $allocations) { $Marshal::FreeHGlobal($a) }
    if ($native -ne [IntPtr]::Zero) { [Runtime.InteropServices.NativeLibrary]::Free($native) }
    $lines.Add("Passed=$passed")
    [IO.File]::WriteAllLines($receipt, $lines)
}
