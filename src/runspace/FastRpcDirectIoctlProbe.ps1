#requires -Version 7.0
# Read-only transport smoke test: call the FastRPC driver ABI directly, without libcdsprpc.so.

$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$dir = [IO.Path]::Combine($root, 'direct-fastrpc')
$receipt = [IO.Path]::Combine($dir, 'receipt.txt')
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('Job=fastrpc-direct-ioctl-smoke')
$save = { [IO.File]::WriteAllLines($receipt, $lines) }
$M = [Runtime.InteropServices.Marshal]
$native = [IntPtr]::Zero
$pins = [Collections.Generic.List[object]]::new()
$allocations = [Collections.Generic.List[IntPtr]]::new()
$fd = -1
$devicePath = [IntPtr]::Zero
$passed = $false

try {
    $modulePath = [IO.Path]::Combine($dir, 'Native.Binding.psm1')
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Delegate factory parse failed' }
    $binding = $ast.GetScriptBlock().InvokeReturnAsIs()

    $native = [Runtime.InteropServices.NativeLibrary]::Load('libc.so')
    $ioctl = & $binding.BindExport $native 'ioctl' ([int]) ([Type[]]@([int], [uint64], [IntPtr])) $true
    $open = & $binding.BindExport $native 'open' ([int]) ([Type[]]@([IntPtr], [int], [int])) $true
    $close = & $binding.BindExport $native 'close' ([int]) ([Type[]]@([int])) $true

    # This is the only exposed non-secure FastRPC node on the current devices.
    # A successful open would not by itself establish a CDSP session.
    $devicePath = $M::StringToHGlobalAnsi('/dev/adsprpc-smd')
    $fd = [int]$open.DynamicInvoke([object[]]@($devicePath, 0, 0)) # O_RDONLY
    $openError = $M::GetLastPInvokeError()
    $lines.Add("OpenRc=$fd")
    $lines.Add("OpenErrno=$openError")
    if ($fd -lt 0) { throw 'Direct FastRPC raw descriptor unavailable' }

    # Qualcomm upstream d247519650fe5cb16de6c78edaa95bcc4be25073:
    # _IOWR('R', 13, struct fastrpc_ioctl_capability[28]) = 0xC01C520D.
    # Payload: domain=CDSP(3), attribute=ARCH_VER(6), capability(out), reserved[4].
    $cap = $M::AllocHGlobal(28)
    $allocations.Add($cap)
    $M::Copy([byte[]]::new(28), 0, $cap, 28)
    $M::WriteInt32($cap, 0, 3)
    $M::WriteInt32($cap, 4, 6)
    $rc = [int]$ioctl.DynamicInvoke([object[]]@($fd, [uint64]0xC01C520D, $cap))
    $ioctlError = $M::GetLastPInvokeError()
    $arch = [uint32]$M::ReadInt32($cap, 8)
    $lines.Add("GetDspInfoRc=$rc")
    $lines.Add("GetDspInfoErrno=$ioctlError")
    $lines.Add("ArchVersion=$arch")
    $passed = ($rc -eq 0 -and $arch -gt 0)
}
catch {
    $lines.Add('Error=' + $_.Exception.Message)
    $lines.Add('At=' + $_.InvocationInfo.ScriptLineNumber)
}
finally {
    if ($fd -ge 0) {
        try { $lines.Add("CloseRc=$([int]$close.DynamicInvoke([object[]]@($fd)))") } catch { }
    }
    foreach ($ptr in $allocations) {
        $M::Copy([byte[]]::new(28), 0, $ptr, 28)
        $M::FreeHGlobal($ptr)
    }
    foreach ($pin in $pins) { if ($pin.IsAllocated) { $pin.Free() } }
    if ($devicePath -ne [IntPtr]::Zero) { $M::FreeHGlobal($devicePath) }
    if ($native -ne [IntPtr]::Zero) { [Runtime.InteropServices.NativeLibrary]::Free($native) }
}

$lines.Add("Passed=$passed")
& $save
[void][Android.Util.Log]::Info('FastRpcDirect', ($lines -join ' | '))
