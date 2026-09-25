#requires -Version 7.0
# Device probe harness for Active VTCM Allocation Characterization on Hexagon V73 CDSP.
# Discovers usable VTCM pool, allocation mechanisms, contiguous allocatable bounds, and read/write integrity.

$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$dir = [IO.Path]::Combine($root, 'vtcm-probe-emitted')
if (-not [IO.Directory]::Exists($dir)) { [void][IO.Directory]::CreateDirectory($dir) }
$receipt = [IO.Path]::Combine($dir, 'receipt.txt')
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('Job=kokoro-vtcm-alloc-probe')
$save = { [IO.File]::WriteAllLines($receipt, $lines) }
$hash = { param([byte[]]$Bytes) [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)) }
$Marshal = [Runtime.InteropServices.Marshal]; $native = [IntPtr]::Zero; $opened = $false
$pins = [Collections.Generic.List[object]]::new(); $allocations = [Collections.Generic.List[object]]::new()
$passed = $false; $watch = [Diagnostics.Stopwatch]::StartNew()

try {
    $modulePath = [IO.Path]::Combine($root, 'Native.Binding.psm1')
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Delegate factory parse failed' }
    $abi = $ast.GetScriptBlock().InvokeReturnAsIs()

    $so = [IO.Path]::Combine($root, 'qnn', 'libkokoro_vtcm_probe_skel.so')
    if (-not [IO.File]::Exists($so)) { throw "Library missing: $so" }
    $soHash = & $hash ([IO.File]::ReadAllBytes($so))
    $lines.Add('LibrarySHA256=' + $soHash)

    $search = [IO.Path]::Combine($root, 'qnn') + ';/vendor/lib/rfsa/adsp;/vendor/dsp/cdsp;/dsp'
    foreach ($name in 'ADSP_LIBRARY_PATH', 'DSP_LIBRARY_PATH') {
        [Environment]::SetEnvironmentVariable($name, $search)
        [Android.Systems.Os]::Setenv($name, $search, $true)
    }

    $native = [Runtime.InteropServices.NativeLibrary]::Load('libcdsprpc.so')
    $fn = { param($Name, $ReturnType, $Parameters)
        $Marshal::GetDelegateForFunctionPointer([Runtime.InteropServices.NativeLibrary]::GetExport($native, $Name),
            (& $abi.NewDelegateType ('VtcmProbe_' + $Name) $ReturnType $Parameters))
    }
    $control = & $fn 'remote_session_control' ([int]) ([Type[]]@([uint32], [IntPtr], [uint32]))
    $open    = & $fn 'remote_handle64_open'    ([int]) ([Type[]]@([IntPtr], ([uint64]).MakeByRefType()))
    $invoke  = & $fn 'remote_handle64_invoke'  ([int]) ([Type[]]@([uint64], [uint32], [IntPtr]))
    $close   = & $fn 'remote_handle64_close'   ([int]) ([Type[]]@([uint64]))

    $allocate = { param([int]$Size)
        $ptr = $Marshal::AllocHGlobal($Size)
        $allocations.Add(@($ptr, $Size))
        $Marshal::Copy([byte[]]::new($Size), 0, $ptr, $Size)
        $ptr
    }
    $pin = { param([byte[]]$Bytes)
        $g = [Runtime.InteropServices.GCHandle]::Alloc($Bytes, [Runtime.InteropServices.GCHandleType]::Pinned)
        $pins.Add($g)
        $g.AddrOfPinnedObject()
    }

    # Enable unsigned PD (config: { 3, 1 })
    $config = & $allocate 8
    $Marshal::WriteInt32($config, 0, 3)
    $Marshal::WriteInt32($config, 4, 1)
    $rc = [int]$control.DynamicInvoke([object[]]@([uint32]2, $config, [uint32]8))
    $lines.Add("UnsignedPdRc=$rc")
    if ($rc -ne 0) { throw 'Unsigned PD configuration failed' }

    # Open VTCM probe skel handle
    $uri = [Text.Encoding]::UTF8.GetBytes('file:///libkokoro_vtcm_probe_skel.so?kokoro_vtcm_skel_handle_invoke&_modver=1.0&_dom=cdsp' + [char]0)
    $uriPtr = & $pin $uri
    $oa = [object[]]@($uriPtr, [uint64]0)
    $rc = [int]$open.DynamicInvoke($oa)
    $lines.Add("OpenRc=$rc")
    if ($rc -ne 0) { throw 'Emitted VTCM probe library open failed' }
    $handle = [uint64]$oa[1]; $opened = $true

    # Method 2: 1 input, 1 output -> sc = 0x02010100
    # arg0: request_size (4 bytes: uint32)
    # arg1: results buffer (60 bytes = 15 x uint32)
    $sizesToTest = @(
        0,              # Query only
        1048576,        # 1.0 MiB
        2097152,        # 2.0 MiB
        4194304,        # 4.0 MiB
        6291456,        # 6.0 MiB
        8388608         # 8.0 MiB
    )

    $resSize = 60
    $outBuf = [byte[]]::new($resSize)
    $outPtr = & $pin $outBuf

    foreach ($sizeBytes in $sizesToTest) {
        $sizeMB = [double]$sizeBytes / (1024 * 1024)
        $inBuf = [BitConverter]::GetBytes([uint32]$sizeBytes)
        $inPtr = & $pin $inBuf

        $argsPtr = & $allocate (2 * 16)
        $Marshal::WriteIntPtr($argsPtr, 0,  $inPtr)
        $Marshal::WriteInt64($argsPtr,  8,  [long]$inBuf.Length)
        $Marshal::WriteIntPtr($argsPtr, 16, $outPtr)
        $Marshal::WriteInt64($argsPtr,  24, [long]$outBuf.Length)

        $invArgs = [object[]]@($handle, [uint32]0x02010100, $argsPtr)

        $sw = [Diagnostics.Stopwatch]::StartNew()
        $invokeRc = [int]$invoke.DynamicInvoke($invArgs)
        $sw.Stop()

        # Parse results struct
        $qdiHandle           = [BitConverter]::ToInt32($outBuf, 0)
        $qdiQueryAvailRc     = [BitConverter]::ToUInt32($outBuf, 4)
        $qdiAvailSize        = [BitConverter]::ToUInt32($outBuf, 8)
        $qdiMaxPageSize      = [BitConverter]::ToUInt32($outBuf, 12)
        $qdiNumPages         = [BitConverter]::ToUInt32($outBuf, 16)
        $poolAttachRc        = [BitConverter]::ToUInt32($outBuf, 20)
        $hasComputeAcquire   = [BitConverter]::ToUInt32($outBuf, 24)
        $hasComputeQuery     = [BitConverter]::ToUInt32($outBuf, 28)
        $queryTotalSize      = [BitConverter]::ToUInt32($outBuf, 32)
        $queryAvailSize      = [BitConverter]::ToUInt32($outBuf, 36)
        $queryRc             = [BitConverter]::ToUInt32($outBuf, 40)
        $acquireCtx          = [BitConverter]::ToUInt32($outBuf, 44)
        $vtcmPtr             = [BitConverter]::ToUInt32($outBuf, 48)
        $writeReadVerified   = [BitConverter]::ToUInt32($outBuf, 52)
        $releaseRc           = [BitConverter]::ToUInt32($outBuf, 56)

        $lines.Add("--- RequestSize=${sizeBytes} (${sizeMB} MiB) ---")
        $lines.Add("InvokeRc=$invokeRc InvokeMs=$($sw.Elapsed.TotalMilliseconds.ToString('F3', [Globalization.CultureInfo]::InvariantCulture))")
        $lines.Add("QDI: Handle=$qdiHandle QueryRc=$qdiQueryAvailRc AvailBytes=$qdiAvailSize MaxPage=$qdiMaxPageSize NumPages=$qdiNumPages")
        $lines.Add("PoolAttach: Rc=$poolAttachRc")
        $lines.Add("DynamicComputeRes: HasAcquire=$hasComputeAcquire HasQuery=$hasComputeQuery QueryRc=$queryRc TotalBytes=$queryTotalSize AvailBytes=$queryAvailSize")
        $lines.Add("AllocResult: Ctx=$acquireCtx VtcmPtr=0x$($vtcmPtr.ToString('X8')) Verified=$writeReadVerified ReleaseRc=$releaseRc")
    }

    $passed = $true
}
catch {
    $lines.Add('Error=' + $_.Exception.Message)
    $lines.Add('At=' + $_.InvocationInfo.ScriptLineNumber)
}
finally {
    if ($opened) {
        try {
            $rc = [int]$close.DynamicInvoke([object[]]@($handle))
            $lines.Add("CloseRc=$rc")
        }
        catch {
            $lines.Add('CloseError=' + $_.Exception.Message)
        }
    }
    foreach ($item in $allocations) {
        $Marshal::Copy([byte[]]::new([int]$item[1]), 0, [IntPtr]$item[0], [int]$item[1])
        $Marshal::FreeHGlobal([IntPtr]$item[0])
    }
    foreach ($pinHandle in $pins) {
        if ($pinHandle.IsAllocated) { $pinHandle.Free() }
    }
    if ($native -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.NativeLibrary]::Free($native)
    }
}

$lines.Add("Passed=$passed")
& $save
[void][Android.Util.Log]::Info('KokoroVtcmAlloc', ($lines -join ' | '))
