#requires -Version 7.0
# Device harness for the emitted HMX conv runner (src/jobs/Kokoro.HmxConvRun.ps1).
# One unsigned-PD session, one handle; Runs invocations of method 2 (sc 0x02040100), each
# re-acquiring its own VTCM/HMX context. Every output's odd bytes are compared with the
# fixture's exact integer reference; ticks are the DSP c31:30 counter (19.2 MHz) around the conv.
$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$dir = [IO.Path]::Combine($root, 'hmx-conv-run')
$receipt = [IO.Path]::Combine($dir, 'receipt.txt')
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('Job=kokoro-hmx-conv-run')
$inv = [Globalization.CultureInfo]::InvariantCulture
$Marshal = [Runtime.InteropServices.Marshal]; $native = [IntPtr]::Zero; $opened = $false; $handle = [uint64]0
$pins = [Collections.Generic.List[object]]::new(); $allocations = [Collections.Generic.List[object]]::new()
$passed = $false
try {
    $spec = [IO.File]::ReadAllLines([IO.Path]::Combine($dir, 'spec.txt'))
    $kv = @{}; foreach ($l in $spec) { $p = $l.Split('=', 2); if ($p.Count -eq 2) { $kv[$p[0]] = $p[1] } }
    $tiles = [int]$kv.Tiles; $runs = [int]$kv.Runs; $macs = [long]$kv.Macs
    if ($tiles -lt 1 -or $tiles -gt 64 -or $runs -lt 1 -or $runs -gt 100) { throw 'Spec out of range' }
    $lines.Add("Shape=$($kv.Shape) Tiles=$tiles Runs=$runs Macs=$macs")

    $ast = [Management.Automation.Language.Parser]::ParseFile([IO.Path]::Combine($root, 'Native.Binding.psm1'), [ref]$null, [ref]$null)
    $abi = $ast.GetScriptBlock().InvokeReturnAsIs()
    $so = [IO.Path]::Combine($root, 'qnn', 'libkokoro_hmx_conv_run_skel.so')
    $lines.Add('LibrarySHA256=' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($so))))
    $search = [IO.Path]::Combine($root, 'qnn') + ';/vendor/lib/rfsa/adsp;/vendor/dsp/cdsp;/dsp'
    foreach ($name in 'ADSP_LIBRARY_PATH', 'DSP_LIBRARY_PATH') {
        [Environment]::SetEnvironmentVariable($name, $search)
        [Android.Systems.Os]::Setenv($name, $search, $true)
    }
    $native = [Runtime.InteropServices.NativeLibrary]::Load('libcdsprpc.so')
    $fn = { param($Name, $ReturnType, $Parameters)
        $Marshal::GetDelegateForFunctionPointer([Runtime.InteropServices.NativeLibrary]::GetExport($native, $Name),
            (& $abi.NewDelegateType ('HmxConvRun_' + $Name) $ReturnType $Parameters))
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

    $uri = [Text.Encoding]::UTF8.GetBytes('file:///libkokoro_hmx_conv_run_skel.so?kokoro_hmx_conv_run_skel_handle_invoke&_modver=1.0&_dom=cdsp' + [char]0)
    $oa = [object[]]@((& $pin $uri), [uint64]0)
    $rc = [int]$open.DynamicInvoke($oa)
    $lines.Add("OpenRc=$rc"); if ($rc -ne 0) { throw 'Kernel library open failed' }
    $handle = [uint64]$oa[1]; $opened = $true

    $act = [IO.File]::ReadAllBytes([IO.Path]::Combine($dir, 'activations.bin'))
    $wts = [IO.File]::ReadAllBytes([IO.Path]::Combine($dir, 'weights.bin'))
    $tbl = [IO.File]::ReadAllBytes([IO.Path]::Combine($dir, 'tables.bin'))
    $expected = [IO.File]::ReadAllBytes([IO.Path]::Combine($dir, 'expected.bin'))
    $config = [BitConverter]::GetBytes([uint32]$tiles)
    $ticks = [Collections.Generic.List[long]]::new()
    $allExact = $true
    for ($run = 0; $run -lt $runs; $run++) {
        $out = [byte[]]::new(64 + $expected.Length)
        $bufs = @($config, $act, $wts, $tbl, $out)
        # Host-side remote_arg is { void* pv; size_t nLen } = 16 bytes on arm64.
        $argBlock = $Marshal::AllocHGlobal(16 * $bufs.Count); $allocations.Add($argBlock)
        for ($i = 0; $i -lt $bufs.Count; $i++) {
            $Marshal::WriteIntPtr($argBlock, 16 * $i, (& $pin $bufs[$i]))
            $Marshal::WriteInt64($argBlock, 16 * $i + 8, [long]$bufs[$i].Length)
        }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $rc = [int]$invoke.DynamicInvoke([object[]]@($handle, [uint32]0x02040100, $argBlock))
        $sw.Stop()
        if ($kv.CaptureOutput -eq '1' -and $rc -eq 0 -and [BitConverter]::ToUInt32($out,36) -ge 6) {
            $captured = [byte[]]::new($expected.Length)
            [Buffer]::BlockCopy($out,64,$captured,0,$captured.Length)
            [IO.File]::WriteAllBytes([IO.Path]::Combine($dir,'captured-output.bin'),$captured)
            $lines.Add('OutputSHA256=' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($captured)))
        }
        $t0 = [BitConverter]::ToUInt64($out, 0); $t1 = [BitConverter]::ToUInt64($out, 8)
        $power = [BitConverter]::ToInt32($out, 16); $ctx = [BitConverter]::ToUInt32($out, 20); $vtcm = [BitConverter]::ToUInt32($out, 24)
        $hvx = [BitConverter]::ToInt32($out, 28); $hmx = [BitConverter]::ToInt32($out, 32); $stageReached = [BitConverter]::ToInt32($out, 36)
        $bad = 0
        for ($b = 1; $b -lt $expected.Length; $b += 2) { if ($out[64 + $b] -ne $expected[$b]) { $bad++ } }
        if ($rc -ne 0 -or $stageReached -ne 7 -or $bad -ne 0) { $allExact = $false }
        $dt = [long]($t1 - $t0); if ($stageReached -ge 6) { $ticks.Add($dt) }
        $lines.Add("Run=$run InvokeRc=$rc Stage=$stageReached PowerRc=$power Ctx=$ctx VtcmBytes=$vtcm HvxLockRc=$hvx HmxLockRc=$hmx ConvTicks=$dt InvokeMs=$($sw.Elapsed.TotalMilliseconds.ToString('F3', $inv)) Mismatches=$bad/$($expected.Length / 2)")
        & { [IO.File]::WriteAllLines($receipt, $lines) }
        if ($rc -ne 0 -or $stageReached -lt 6) { break }
    }
    if ($ticks.Count) {
        $sorted = $ticks.ToArray(); [Array]::Sort($sorted); $median = $sorted[[int][math]::Floor($sorted.Count / 2)]
        $us = $median / 19.2
        $lines.Add("MedianConvTicks=$median MedianConvUs=$($us.ToString('F2', $inv)) GMacPerSecond=$(($macs / ($us * 1000)).ToString('F1', $inv))")
    }
    $passed = $allExact
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
