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
$fdObject = $null
$passed = $false

try {
    $modulePath = [IO.Path]::Combine($root, 'emit.Qnn.Abi.ps1')
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Delegate factory parse failed' }
    $abi = $ast.GetScriptBlock().InvokeReturnAsIs()

    $native = [Runtime.InteropServices.NativeLibrary]::Load('libc.so')
    $fn = { param($Name, $ReturnType, $Parameters)
        $M::GetDelegateForFunctionPointer(
            [Runtime.InteropServices.NativeLibrary]::GetExport($native, $Name),
            (& $abi.NewDelegateType ('Direct_' + $Name) $ReturnType $Parameters))
    }
    $ioctl = & $fn 'ioctl' ([int]) ([Type[]]@([int], [uint64], [IntPtr]))
    $errnoLocation = & $fn '__errno' ([IntPtr]) ([Type[]]@())

    $fdObject = [Android.Systems.Os]::Open('/dev/adsprpc-smd', 0, 0) # O_RDONLY
    $flags = [Reflection.BindingFlags]'Instance,Public,NonPublic'
    $member = $fdObject.GetType().GetProperty('Descriptor', $flags)
    if ($null -ne $member) { $fd = [int]$member.GetValue($fdObject) }
    if ($fd -lt 0) {
        $member = $fdObject.GetType().GetFields($flags) | Where-Object {
            $_.FieldType -eq [int] -and $_.Name -match 'descriptor|fd'
        } | Select-Object -First 1
        if ($null -ne $member) { $fd = [int]$member.GetValue($fdObject) }
    }
    $lines.Add("OpenSucceeded=$($null -ne $fdObject) RawFd=$fd")
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
    $ioctlErrno = if ($rc -lt 0) { $M::ReadInt32($errnoLocation.DynamicInvoke()) } else { 0 }
    $arch = [uint32]$M::ReadInt32($cap, 8)
    $lines.Add("GetDspInfoRc=$rc GetDspInfoErrno=$ioctlErrno")
    $lines.Add("ArchVersion=$arch")
    $passed = ($rc -eq 0 -and $arch -gt 0)
}
catch {
    $lines.Add('Error=' + $_.Exception.Message)
    $lines.Add('At=' + $_.InvocationInfo.ScriptLineNumber)
}
finally {
    if ($null -ne $fdObject) {
        try { [Android.Systems.Os]::Close($fdObject); $lines.Add('CloseRc=0') } catch { }
    }
    foreach ($ptr in $allocations) {
        $M::Copy([byte[]]::new(28), 0, $ptr, 28)
        $M::FreeHGlobal($ptr)
    }
    foreach ($pin in $pins) { if ($pin.IsAllocated) { $pin.Free() } }
    if ($native -ne [IntPtr]::Zero) { [Runtime.InteropServices.NativeLibrary]::Free($native) }
}

$lines.Add("Passed=$passed")
& $save
[void][Android.Util.Log]::Info('FastRpcDirect', ($lines -join ' | '))
