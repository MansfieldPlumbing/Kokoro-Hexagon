#requires -Version 7.0
# Device harness for the emitted VTCM query skel (src/hexagon/Kokoro.VtcmQueryProbe.ps1).
# One unsigned-PD session, one handle; method 2 (sc 0x02010100) for application IDs 0..8, each
# querying that ID's VTCM partition and acquiring all of it with HMX under that application type.
$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$dir = [IO.Path]::Combine($root, 'vtcm-query')
$receipt = [IO.Path]::Combine($dir, 'receipt.txt')
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('Job=kokoro-vtcm-query')
$Marshal = [Runtime.InteropServices.Marshal]; $native = [IntPtr]::Zero; $opened = $false; $handle = [uint64]0
$pins = [Collections.Generic.List[object]]::new(); $allocations = [Collections.Generic.List[object]]::new()
$passed = $false
try {
    $ast = [Management.Automation.Language.Parser]::ParseFile([IO.Path]::Combine($root, 'Native.Binding.psm1'), [ref]$null, [ref]$null)
    $abi = $ast.GetScriptBlock().InvokeReturnAsIs()
    $so = [IO.Path]::Combine($root, 'qnn', 'libkokoro_vtcm_query_skel.so')
    $lines.Add('LibrarySHA256=' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($so))))
    $search = [IO.Path]::Combine($root, 'qnn') + ';/vendor/lib/rfsa/adsp;/vendor/dsp/cdsp;/dsp'
    foreach ($name in 'ADSP_LIBRARY_PATH', 'DSP_LIBRARY_PATH') {
        [Environment]::SetEnvironmentVariable($name, $search)
        [Android.Systems.Os]::Setenv($name, $search, $true)
    }
    $native = [Runtime.InteropServices.NativeLibrary]::Load('libcdsprpc.so')
    $fn = { param($Name, $ReturnType, $Parameters)
        $Marshal::GetDelegateForFunctionPointer([Runtime.InteropServices.NativeLibrary]::GetExport($native, $Name),
            (& $abi.NewDelegateType ('VtcmQuery_' + $Name) $ReturnType $Parameters))
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

    $uri = [Text.Encoding]::UTF8.GetBytes('file:///libkokoro_vtcm_query_skel.so?kokoro_vtcm_query_skel_handle_invoke&_modver=1.0&_dom=cdsp' + [char]0)
    $oa = [object[]]@((& $pin $uri), [uint64]0)
    $rc = [int]$open.DynamicInvoke($oa)
    $lines.Add("OpenRc=$rc"); if ($rc -ne 0) { throw 'Kernel library open failed' }
    $handle = [uint64]$oa[1]; $opened = $true

    $layout = { param([byte[]]$b, [int]$at)
        $count = [BitConverter]::ToUInt32($b, $at + 4)
        $pages = for ($p = 0; $p -lt [math]::Min($count, 8); $p++) {
            '{0}x{1}' -f [BitConverter]::ToUInt32($b, $at + 8 + 8 * $p), [BitConverter]::ToUInt32($b, $at + 12 + 8 * $p)
        }
        'Block={0} Pages=[{1}]' -f [BitConverter]::ToUInt32($b, $at), ($pages -join ',')
    }
    $defaultGranted = $false
    for ($app = 0; $app -le 8; $app++) {
        $config = [BitConverter]::GetBytes([uint32]$app)
        $out = [byte[]]::new(256)
        $argBlock = $Marshal::AllocHGlobal(32); $allocations.Add($argBlock)
        $Marshal::WriteIntPtr($argBlock, 0, (& $pin $config)); $Marshal::WriteInt64($argBlock, 8, [long]$config.Length)
        $Marshal::WriteIntPtr($argBlock, 16, (& $pin $out)); $Marshal::WriteInt64($argBlock, 24, [long]$out.Length)
        $rc = [int]$invoke.DynamicInvoke([object[]]@($handle, [uint32]0x02010100, $argBlock))
        $u = { param([int]$o) [BitConverter]::ToUInt32($out, $o) }
        $total = & $u 4; $granted = & $u 168
        $lines.Add(("App={0} Echo={1} InvokeRc={2} Stage={3} QueryRc={4} TotalBytes={5} AvailableBytes={6} SetAppTypeRc={7} PowerRc={8} Ctx={9} GrantedBytes={10} PointerValid={11} ReleaseRc={12}" -f
            $app, (& $u 184), $rc, (& $u 180), [BitConverter]::ToInt32($out, 0), $total, (& $u 80), [BitConverter]::ToInt32($out, 188),
            [BitConverter]::ToInt32($out, 160), (& $u 164), $granted, (& $u 172), [BitConverter]::ToInt32($out, 176)))
        $lines.Add("App=$app TotalLayout " + (& $layout $out 8))
        $lines.Add("App=$app AvailableLayout " + (& $layout $out 84))
        if ($app -eq 0 -and $rc -eq 0 -and (& $u 180) -eq 5 -and $total -gt 0 -and $granted -eq $total -and (& $u 172) -eq 1) { $defaultGranted = $true }
        [IO.File]::WriteAllLines($receipt, $lines)
        if ($rc -ne 0) { break }
    }
    $passed = $defaultGranted
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
