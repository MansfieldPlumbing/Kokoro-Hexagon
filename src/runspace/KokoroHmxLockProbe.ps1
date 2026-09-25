#requires -Version 7.0
# Device probe harness for physical HMX acquisition via QuRT trap0(#0x1d) on Hexagon V73.
# Invokes emitted libkokoro_hmx_lock_skel.so over FastRPC libcdsprpc.so in unsigned PD.

$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$dir = [IO.Path]::Combine($root, 'hmx-lock-emitted')
$receipt = [IO.Path]::Combine($dir, 'receipt.txt')
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('Job=kokoro-hmx-lock-probe')
$save = { [IO.File]::WriteAllLines($receipt, $lines) }
$hash = { param([byte[]]$Bytes) [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)) }
$M = [Runtime.InteropServices.Marshal]; $native = [IntPtr]::Zero; $opened = $false
$pins = [Collections.Generic.List[object]]::new(); $allocations = [Collections.Generic.List[object]]::new()
$passed = $false; $watch = [Diagnostics.Stopwatch]::StartNew()

try {
    $modulePath = [IO.Path]::Combine($root, 'Native.Binding.psm1')
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Delegate factory parse failed' }
    $abi = $ast.GetScriptBlock().InvokeReturnAsIs()

    $so = [IO.Path]::Combine($root, 'qnn', 'libkokoro_hmx_lock_skel.so')
    $soHash = & $hash ([IO.File]::ReadAllBytes($so))
    $lines.Add('LibrarySHA256=' + $soHash)

    $search = [IO.Path]::Combine($root, 'qnn') + ';/vendor/lib/rfsa/adsp;/vendor/dsp/cdsp;/dsp'
    foreach ($name in 'ADSP_LIBRARY_PATH', 'DSP_LIBRARY_PATH') {
        [Environment]::SetEnvironmentVariable($name, $search)
        [Android.Systems.Os]::Setenv($name, $search, $true)
    }

    $native = [Runtime.InteropServices.NativeLibrary]::Load('libcdsprpc.so')
    $fn = { param($Name, $ReturnType, $Parameters)
        $M::GetDelegateForFunctionPointer([Runtime.InteropServices.NativeLibrary]::GetExport($native, $Name),
            (& $abi.NewDelegateType ('HmxLock_' + $Name) $ReturnType $Parameters))
    }
    $control = & $fn 'remote_session_control' ([int]) ([Type[]]@([uint32], [IntPtr], [uint32]))
    $open    = & $fn 'remote_handle64_open'    ([int]) ([Type[]]@([IntPtr], ([uint64]).MakeByRefType()))
    $invoke  = & $fn 'remote_handle64_invoke'  ([int]) ([Type[]]@([uint64], [uint32], [IntPtr]))
    $close   = & $fn 'remote_handle64_close'   ([int]) ([Type[]]@([uint64]))

    $allocate = { param([int]$Size)
        $ptr = $M::AllocHGlobal($Size)
        $allocations.Add(@($ptr, $Size))
        $M::Copy([byte[]]::new($Size), 0, $ptr, $Size)
        $ptr
    }
    $pin = { param([byte[]]$Bytes)
        $g = [Runtime.InteropServices.GCHandle]::Alloc($Bytes, [Runtime.InteropServices.GCHandleType]::Pinned)
        $pins.Add($g)
        $g.AddrOfPinnedObject()
    }

    # Enable unsigned PD (config: { 3, 1 })
    $config = & $allocate 8
    $M::WriteInt32($config, 0, 3)
    $M::WriteInt32($config, 4, 1)
    $rc = [int]$control.DynamicInvoke([object[]]@([uint32]2, $config, [uint32]8))
    $lines.Add("UnsignedPdRc=$rc")
    if ($rc -ne 0) { throw 'Unsigned PD configuration failed' }

    # Open HMX lock skel handle
    $uri = [Text.Encoding]::UTF8.GetBytes('file:///libkokoro_hmx_lock_skel.so?kokoro_hmx_lock_skel_handle_invoke&_modver=1.0&_dom=cdsp' + [char]0)
    $uriPtr = & $pin $uri
    $oa = [object[]]@($uriPtr, [uint64]0)
    $rc = [int]$open.DynamicInvoke($oa)
    $lines.Add("OpenRc=$rc")
    if ($rc -ne 0) { throw 'Emitted HMX lock library open failed' }
    $handle = [uint64]$oa[1]; $opened = $true

    # Prepare 1 input buffer (4 bytes dummy), 1 output buffer (16 bytes = 4 int32s)
    $inBuf = [byte[]]::new(4)
    $outBuf = [byte[]]::new(16)
    $inBufPtr = & $pin $inBuf
    $outBufPtr = & $pin $outBuf

    # FastRPC remote args structure: 2 arguments (16 bytes each on ARM64)
    $argsPtr = & $allocate (2 * 16)
    $M::WriteIntPtr($argsPtr, 0, $inBufPtr)
    $M::WriteInt64($argsPtr, 8, [long]$inBuf.Length)
    $M::WriteIntPtr($argsPtr, 16, $outBufPtr)
    $M::WriteInt64($argsPtr, 24, [long]$outBuf.Length)

    # Method 2: 1 in, 1 out -> 0x02010100
    $invArgs = [object[]]@($handle, [uint32]0x02010100, $argsPtr)

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $invokeRc = [int]$invoke.DynamicInvoke($invArgs)
    $sw.Stop()
    $lines.Add("InvokeRc=$invokeRc InvokeMs=$($sw.Elapsed.TotalMilliseconds.ToString('F3', [Globalization.CultureInfo]::InvariantCulture))")

    # Read the 4 returned int32s
    $hvxUnlockRc  = [BitConverter]::ToInt32($outBuf, 0)
    $hmxTryLockRc = [BitConverter]::ToInt32($outBuf, 4)
    $hmxUnlockRc  = [BitConverter]::ToInt32($outBuf, 8)
    $hvxRelockRc  = [BitConverter]::ToInt32($outBuf, 12)

    $lines.Add("HvxUnlockRc=$hvxUnlockRc")
    $lines.Add("HmxTryLockRc=$hmxTryLockRc")
    $lines.Add("HmxUnlockRc=$hmxUnlockRc")
    $lines.Add("HvxRelockRc=$hvxRelockRc")

    $passed = ($invokeRc -eq 0)
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
        $M::Copy([byte[]]::new([int]$item[1]), 0, [IntPtr]$item[0], [int]$item[1])
        $M::FreeHGlobal([IntPtr]$item[0])
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
[void][Android.Util.Log]::Info('KokoroHmxLock', ($lines -join ' | '))
