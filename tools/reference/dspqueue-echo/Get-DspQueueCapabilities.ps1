#requires -Version 7.0
# Diagnostic only: source-defined DSPQueue/FastRPC capability query.
# SDK 6.4.0.2 incs/dspqueue.h (SHA-256 pinned by Build-DspQueueEchoProbe.ps1):
# DSPQUEUE_STAT_SIGNALING_PERF = 7; dspqueue_get_stat(dspqueue_t, stat, uint64_t*).
# quic/fastrpc 228d98b5f143ed917789cde017a8aa548e65b80b:
# inc/fastrpc_cap.h:16; inc/fastrpc_common.h:145,150.
$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$receipt = [IO.Path]::Combine($root, 'dspqueue-echo', 'receipt.txt')
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('Job=dspqueue-capabilities')
$marshal = [Runtime.InteropServices.Marshal]
$native = [IntPtr]::Zero
$queue = [IntPtr]::Zero
$config = [IntPtr]::Zero
$passed = $false
try {
    $abiFile = [IO.Path]::Combine($root, 'emit.Qnn.Abi.ps1')
    $abiHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [IO.File]::ReadAllBytes($abiFile)))
    if ($abiHash -cne 'B4820C76C79FC0B66EE96E27E8D655689F33181165F55E2B0A96A3A4BE34391D') {
        throw 'Diagnostic delegate factory integrity check failed.'
    }
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($abiFile, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Diagnostic delegate factory did not parse.' }
    $abi = $ast.GetScriptBlock().InvokeReturnAsIs()
    $native = [Runtime.InteropServices.NativeLibrary]::Load('libcdsprpc.so')
    $bind = {
        param([string]$name, [Type]$returnType, [Type[]]$parameters)
        $address = [Runtime.InteropServices.NativeLibrary]::GetExport($native, $name)
        $type = & $abi.NewDelegateType ('Capability_' + $name) $returnType $parameters
        $marshal::GetDelegateForFunctionPointer($address, $type)
    }
    $control = & $bind 'remote_session_control' ([int]) ([Type[]]@([uint32], [IntPtr], [uint32]))
    $create = & $bind 'dspqueue_create' ([int]) ([Type[]]@(
        [int], [uint32], [uint32], [uint32], [IntPtr], [IntPtr], [IntPtr], [IntPtr].MakeByRefType()))
    $close = & $bind 'dspqueue_close' ([int]) ([Type[]]@([IntPtr]))
    $stat = & $bind 'dspqueue_get_stat' ([int]) ([Type[]]@([IntPtr], [int], [uint64].MakeByRefType()))
    $config = $marshal::AllocHGlobal(8)
    $marshal::WriteInt32($config, 0, 3)
    $marshal::WriteInt32($config, 4, 1)
    $rc = [int]$control.DynamicInvoke([object[]]@([uint32]2, $config, [uint32]8))
    $lines.Add("UnsignedPdRc=$rc")
    if ($rc -ne 0) { throw 'Unsigned process domain rejected.' }
    $createArgs = [object[]]@([int]3, [uint32]0, [uint32]256, [uint32]256,
        [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
    $rc = [int]$create.DynamicInvoke($createArgs)
    $queue = [IntPtr]$createArgs[7]
    $lines.Add("CreateRc=$rc")
    if ($rc -ne 0 -or $queue -eq [IntPtr]::Zero) { throw 'Queue creation failed.' }
    $statArgs = [object[]]@($queue, [int]7, [uint64]0)
    $rc = [int]$stat.DynamicInvoke($statArgs)
    $lines.Add("SignalingPerfRc=$rc")
    $lines.Add("SignalingPerf=$([uint64]$statArgs[2])")
    try {
        $getCap = & $bind 'fastrpc_get_cap' ([int]) ([Type[]]@(
            [uint32], [uint32], [uint32].MakeByRefType()))
        foreach ($entry in @(@('DspSignal', 130), @('DriverSignal', 259))) {
            $capArgs = [object[]]@([uint32]3, [uint32]$entry[1], [uint32]0)
            $capRc = [int]$getCap.DynamicInvoke($capArgs)
            $lines.Add("$($entry[0])Rc=$capRc")
            $lines.Add("$($entry[0])=$([uint32]$capArgs[2])")
        }
    } catch {
        $lines.Add('FastrpcCapabilityProbeUnavailable=True')
    }
    $passed = ($rc -eq 0)
} catch {
    $lines.Add('Error=' + $_.Exception.Message)
} finally {
    if ($queue -ne [IntPtr]::Zero) {
        try {
            $closeRc = [int]$close.DynamicInvoke([object[]]@($queue))
            $lines.Add("QueueCloseRc=$closeRc")
            if ($closeRc -ne 0) { $passed = $false }
        } catch { $lines.Add('QueueCloseError=' + $_.Exception.Message); $passed = $false }
    }
    if ($config -ne [IntPtr]::Zero) {
        $marshal::WriteInt64($config, 0)
        $marshal::FreeHGlobal($config)
    }
    if ($native -ne [IntPtr]::Zero) { [Runtime.InteropServices.NativeLibrary]::Free($native) }
    $lines.Add("Passed=$passed")
    [IO.File]::WriteAllLines($receipt, $lines)
}
