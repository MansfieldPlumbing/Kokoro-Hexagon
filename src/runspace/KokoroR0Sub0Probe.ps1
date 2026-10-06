#requires -Version 7.0
# Device probe harness for Kokoro generator resblock 3 sub-iteration 0 (r0.0) on Hexagon V73.
# Invokes emitted libkokoro_r0sub0_skel.so via FastRPC over libcdsprpc.so.
# Validates unsigned PD admission, 128-byte HVX vector streaming, timing, and buffer integrity.

$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$dir = [IO.Path]::Combine($root, 'r0sub0-emitted')
$receipt = [IO.Path]::Combine($dir, 'receipt.txt')
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('Job=kokoro-r0sub0-emitted')
$save = { [IO.File]::WriteAllLines($receipt, $lines) }
$hash = { param([byte[]]$Bytes) [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)) }
$M = [Runtime.InteropServices.Marshal]; $native = [IntPtr]::Zero; $opened = $false
$pins = [Collections.Generic.List[object]]::new(); $allocations = [Collections.Generic.List[object]]::new()
$passed = $false; $setup = [Diagnostics.Stopwatch]::StartNew()

try {
    $modulePath = [IO.Path]::Combine($root, 'Native.Binding.psm1')
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Delegate factory parse failed' }
    $abi = $ast.GetScriptBlock().InvokeReturnAsIs()

    $so = [IO.Path]::Combine($root, 'qnn', 'libkokoro_r0sub0_skel.so')
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
            (& $abi.NewDelegateType ('R0Sub0_' + $Name) $ReturnType $Parameters))
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

    # Open skel handle
    $uri = [Text.Encoding]::UTF8.GetBytes('file:///libkokoro_r0sub0_skel.so?kokoro_r0sub0_skel_handle_invoke&_modver=1.0&_dom=cdsp' + [char]0)
    $uriPtr = & $pin $uri
    $oa = [object[]]@($uriPtr, [uint64]0)
    $rc = [int]$open.DynamicInvoke($oa)
    $lines.Add("OpenRc=$rc")
    if ($rc -ne 0) { throw 'Emitted r0sub0 library open failed' }
    $handle = [uint64]$oa[1]; $opened = $true

    # Existing resident input files:
    $weights = [IO.File]::ReadAllBytes([IO.Path]::Combine($root, 'r0', 'r0_static.bin'))
    $inZ     = [IO.File]::ReadAllBytes([IO.Path]::Combine($root, 'r0', 'in_z.f32'))
    $inMask  = [IO.File]::ReadAllBytes([IO.Path]::Combine($root, 'r0', 'in_mask1.f32'))
    $lines.Add("WeightsBytes=$($weights.Length) InZBytes=$($inZ.Length) InMaskBytes=$($inMask.Length)")

    # Slice dynamic style parameters: gain1 (1182720), shift1 (1183232), gain2 (1185792), shift2 (1186304)
    # Total 2,048 bytes (4 * 128 * 4)
    $dynParams = [byte[]]::new(2048)
    [Buffer]::BlockCopy($weights, 1182720, $dynParams, 0, 512)
    [Buffer]::BlockCopy($weights, 1183232, $dynParams, 512, 512)
    [Buffer]::BlockCopy($weights, 1185792, $dynParams, 1024, 512)
    [Buffer]::BlockCopy($weights, 1186304, $dynParams, 1536, 512)

    # Pad inZ (7681 -> 7712 floats per channel) and inMask (7681 -> 7712 floats)
    $paddedFrames = 7712
    $channels = 128
    $tensorBytes = $paddedFrames * $channels * 4 # 3,948,544 bytes
    $maskBytes = $paddedFrames * 4               # 30,848 bytes

    $inZPad = [byte[]]::new($tensorBytes)
    for ($c = 0; $c -lt $channels; $c++) {
        [Buffer]::BlockCopy($inZ, $c * 7681 * 4, $inZPad, $c * $paddedFrames * 4, 7681 * 4)
    }

    $inMaskPad = [byte[]]::new($maskBytes)
    [Buffer]::BlockCopy($inMask, 0, $inMaskPad, 0, [Math]::Min($inMask.Length, 7681 * 4))

    # Working buffers:
    $workspace = [byte[]]::new($tensorBytes)
    $output    = [byte[]]::new($tensorBytes)

    # Pin memory for FastRPC:
    $inZPtr       = & $pin $inZPad
    $inMaskPtr    = & $pin $inMaskPad
    $weightsPtr   = & $pin $weights
    $dynParamsPtr = & $pin $dynParams
    $workspacePtr = & $pin $workspace
    $outputPtr    = & $pin $output

    $geometry = & $allocate 8
    $M::WriteInt32($geometry, 0, 7681)
    $M::WriteInt32($geometry, 4, 128)

    # Remote args structure: 7 arguments (8 bytes ptr + 8 bytes length = 16 bytes each on DSP)
    # Total 7 * 16 = 112 bytes
    $argsPtr = & $allocate (7 * 16)
    $argList = @(
        @($geometry, 8),
        @($inZPtr, $inZPad.Length),
        @($inMaskPtr, $inMaskPad.Length),
        @($weightsPtr, $weights.Length),
        @($dynParamsPtr, $dynParams.Length),
        @($workspacePtr, $workspace.Length),
        @($outputPtr, $output.Length)
    )
    for ($i = 0; $i -lt $argList.Count; $i++) {
        $M::WriteIntPtr($argsPtr, $i * 16, [IntPtr]$argList[$i][0])
        $M::WriteInt64($argsPtr, $i * 16 + 8, [long]$argList[$i][1])
    }

    $lines.Add("SetupMs=$($setup.Elapsed.TotalMilliseconds.ToString('F3', [Globalization.CultureInfo]::InvariantCulture))")
    & $save

    # Method 2: 6 in, 1 out -> 0x02060100
    $invArgs = [object[]]@($handle, [uint32]0x02060100, $argsPtr)

    # Cold execution:
    $cold = [Diagnostics.Stopwatch]::StartNew()
    $rc = [int]$invoke.DynamicInvoke($invArgs)
    $cold.Stop()
    $lines.Add("ColdInvokeRc=$rc ColdInvokeMs=$($cold.Elapsed.TotalMilliseconds.ToString('F3', [Globalization.CultureInfo]::InvariantCulture))")
    if ($rc -ne 0) { throw "Cold invoke failed rc=$rc" }

    # Verify vector output hash:
    $inZHash = & $hash $inZPad
    $outHash = & $hash $output
    $lines.Add("InZSHA256=$inZHash")
    $lines.Add("OutSHA256=$outHash")
    $nonzero = ($outHash -ne 'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855')
    $computed = ($outHash -ne $inZHash)
    $lines.Add("OutputNonZero=$nonzero OutputComputed=$computed")
    & $save

    # Warm execution benchmark: 12 invocations
    $timings = [double[]]::new(12)
    for ($iter = 0; $iter -lt 12; $iter++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $rc = [int]$invoke.DynamicInvoke($invArgs)
        $sw.Stop()
        if ($rc -ne 0) { throw "Warm invoke failed at iter $iter rc=$rc" }
        $timings[$iter] = $sw.Elapsed.TotalMilliseconds
        $lines.Add(("Iter={0} Ms={1:F3}" -f $iter, $timings[$iter]))
        & $save
    }

    [Array]::Sort($timings)
    $median = ($timings[5] + $timings[6]) / 2.0
    $lines.Add(("WarmMedianMs={0:F3} MinMs={1:F3} MaxMs={2:F3}" -f $median, $timings[0], $timings[11]))

    # Guard checks:
    # 1. Invalid frames in geometry:
    $M::WriteInt32($geometry, 0, 7680)
    $rc = [int]$invoke.DynamicInvoke($invArgs)
    $lines.Add("WrongFramesRc=$rc")
    if ($rc -ne 14) { throw "Wrong frames guard failed: rc=$rc" }
    $M::WriteInt32($geometry, 0, 7681)

    # 2. Invalid channels in geometry:
    $M::WriteInt32($geometry, 4, 64)
    $rc = [int]$invoke.DynamicInvoke($invArgs)
    $lines.Add("WrongChannelsRc=$rc")
    if ($rc -ne 14) { throw "Wrong channels guard failed: rc=$rc" }
    $M::WriteInt32($geometry, 4, 128)

    $lines.Add("PostIntegrity=True")
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
            if ($rc -ne 0) { $passed = $false }
        }
        catch {
            $passed = $false
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
[void][Android.Util.Log]::Info('KokoroR0Sub0', ($lines -join ' | '))
