#requires -Version 7.0
# Device probe harness for Tri-Precision HMX Matrix Contraction Probes on Hexagon V73.
# Measures hardware timer deltas (c31:30 at 19.2 MHz) for HVX->HMX transition, compute, and HMX->HVX restoration.
# Probes Mode 0 (Control Baseline), Mode 1 (FP16), Mode 2 (W8A8), and Mode 3 (W4A8) over dedicated VTCM buffers.

$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$dir = [IO.Path]::Combine($root, 'hmx-matrix-emitted')
if (-not [IO.Directory]::Exists($dir)) { [void][IO.Directory]::CreateDirectory($dir) }
$receipt = [IO.Path]::Combine($dir, 'receipt.txt')
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('Job=kokoro-hmx-matrix-probe')
$save = { [IO.File]::WriteAllLines($receipt, $lines) }
$hash = { param([byte[]]$Bytes) [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)) }
$Marshal = [Runtime.InteropServices.Marshal]; $native = [IntPtr]::Zero; $opened = $false
$keeperOpened = $false; $keeperHandle = [uint64]0
$pins = [Collections.Generic.List[object]]::new(); $allocations = [Collections.Generic.List[object]]::new()
$passed = $false; $watch = [Diagnostics.Stopwatch]::StartNew()

try {
    $modulePath = [IO.Path]::Combine($root, 'Native.Binding.psm1')
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Delegate factory parse failed' }
    $abi = $ast.GetScriptBlock().InvokeReturnAsIs()

    $so = [IO.Path]::Combine($root, 'qnn', 'libkokoro_hmx_matrix_skel.so')
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
            (& $abi.NewDelegateType ('HmxMatrix_' + $Name) $ReturnType $Parameters))
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
    $phaseWatch = [Diagnostics.Stopwatch]::StartNew()
    $rc = [int]$control.DynamicInvoke([object[]]@([uint32]2, $config, [uint32]8))
    $phaseWatch.Stop()
    $lines.Add("UnsignedPdRc=$rc SessionControlMs=$($phaseWatch.Elapsed.TotalMilliseconds.ToString('F3', [Globalization.CultureInfo]::InvariantCulture))")
    if ($rc -ne 0) { throw 'Unsigned PD configuration failed' }

    # Hold a proven HAP HMX power vote while the independently emitted kernel runs.
    $keeperUri = [Text.Encoding]::UTF8.GetBytes('file:///libkokoro_hmx_power_keeper_skel.so?kokoro_hmx_power_keeper_skel_handle_invoke&_modver=1.0&_dom=cdsp' + [char]0)
    $keeperOpenArgs = [object[]]@((& $pin $keeperUri), [uint64]0)
    $phaseWatch.Restart()
    $rc = [int]$open.DynamicInvoke($keeperOpenArgs)
    $phaseWatch.Stop()
    $lines.Add("PowerKeeperOpenRc=$rc PowerKeeperOpenMs=$($phaseWatch.Elapsed.TotalMilliseconds.ToString('F3', [Globalization.CultureInfo]::InvariantCulture))")
    if ($rc -ne 0) { throw 'HMX power keeper open failed' }
    $keeperHandle = [uint64]$keeperOpenArgs[1]; $keeperOpened = $true

    # Open HMX matrix skel handle
    $uri = [Text.Encoding]::UTF8.GetBytes('file:///libkokoro_hmx_matrix_skel.so?kokoro_hmx_matrix_skel_handle_invoke&_modver=1.0&_dom=cdsp' + [char]0)
    $uriPtr = & $pin $uri
    $oa = [object[]]@($uriPtr, [uint64]0)
    $phaseWatch.Restart()
    $rc = [int]$open.DynamicInvoke($oa)
    $phaseWatch.Stop()
    $lines.Add("OpenRc=$rc KernelOpenMs=$($phaseWatch.Elapsed.TotalMilliseconds.ToString('F3', [Globalization.CultureInfo]::InvariantCulture)) PreFirstInvokeMs=$($watch.Elapsed.TotalMilliseconds.ToString('F3', [Globalization.CultureInfo]::InvariantCulture))")
    if ($rc -ne 0) { throw 'Emitted HMX tile library open failed' }
    $handle = [uint64]$oa[1]; $opened = $true

    # Method 2: 3 inputs, 1 output -> sc = 0x02030100
    # arg0: config { mode, vtcm activation, vtcm weight, vtcm output }
    # arg1: activation buffer
    # arg2: weight buffer
    # arg3: output buffer (64 bytes telemetry + output tensor)
    $modes = @(
        @{ Id=0; Name='Control_Baseline'; ActBytes=2048; WtBytes=2048; OutBytes=2112 },
        # Run diagnostics before any mxmem contraction can reset the PD.
        @{ Id=9; Name='FP16_Cvt_Only';      ActBytes=2048; WtBytes=2048; OutBytes=2112 },
        @{ Id=10; Name='FP16_CvtWrite_Only'; ActBytes=2048; WtBytes=2048; OutBytes=2112 },
        @{ Id=1; Name='FP16_32x32';       ActBytes=2048; WtBytes=2048; OutBytes=2112 },
        @{ Id=2; Name='W8A8_64x32x32';     ActBytes=2048; WtBytes=1024; OutBytes=8256 },
        @{ Id=3; Name='W4A8_64x32x32';     ActBytes=2048; WtBytes=512;  OutBytes=8256 }
    )

    $allPassed = $true

    foreach ($spec in $modes) {
        $modeId = [int]$spec.Id
        $modeName = [string]$spec.Name

        # Prepare inputs
        $cfgBytes = [byte[]]::new(20)
        [Array]::Copy([BitConverter]::GetBytes($modeId), 0, $cfgBytes, 0, 4)
        $actBytes = [byte[]]::new($spec.ActBytes)
        $wtBytes  = [byte[]]::new($spec.WtBytes)
        $outBytes = [byte[]]::new($spec.OutBytes)

        # Synthesize known test specimens
        if ($modeId -eq 1) {
            # FP16: dense 1.0 tiles. This is layout-independent: any valid lane mapping
            # must produce a nonzero contraction if the operand load reaches HMX.
            for ($i = 0; $i -lt $actBytes.Length; $i += 2) {
                $actBytes[$i] = 0x00; $actBytes[$i + 1] = 0x3C
                $wtBytes[$i]  = 0x00; $wtBytes[$i + 1]  = 0x3C
            }
        } elseif ($modeId -eq 2) {
            # W8A8: dense ones, independent of physical lane permutation.
            [Array]::Fill[byte]($actBytes, 1)
            [Array]::Fill[byte]($wtBytes, 1)
        } elseif ($modeId -eq 3) {
            # W4A8: dense activation ones and packed signed-nibble ones (0x11).
            [Array]::Fill[byte]($actBytes, 1)
            [Array]::Fill[byte]($wtBytes, 0x11)
        }

        $actPtr = & $pin $actBytes
        $wtPtr  = & $pin $wtBytes
        $residentMeta = [byte[]]::new(32)
        $residentMetaPtr = & $pin $residentMeta
        $residentArgs = & $allocate 64
        $keeperMode = if ($modeId -in 1,2,3) { 100 + $modeId } else { $modeId }
        $Marshal::WriteIntPtr($residentArgs, 0, (& $pin ([BitConverter]::GetBytes($keeperMode))))
        $Marshal::WriteInt64($residentArgs, 8, 4)
        $Marshal::WriteIntPtr($residentArgs, 16, $actPtr); $Marshal::WriteInt64($residentArgs, 24, $actBytes.Length)
        $Marshal::WriteIntPtr($residentArgs, 32, $wtPtr);  $Marshal::WriteInt64($residentArgs, 40, $wtBytes.Length)
        $Marshal::WriteIntPtr($residentArgs, 48, $residentMetaPtr); $Marshal::WriteInt64($residentArgs, 56, 32)
        $residentRc = [int]$invoke.DynamicInvoke([object[]]@($keeperHandle, [uint32]0x02030100, $residentArgs))
        $residentStatus = [BitConverter]::ToInt32($residentMeta, 0)
        $vtcmBase = [BitConverter]::ToUInt32($residentMeta, 4)
        $vtcmAct = [BitConverter]::ToUInt32($residentMeta, 8)
        $vtcmWt = [BitConverter]::ToUInt32($residentMeta, 12)
        $vtcmOut = [BitConverter]::ToUInt32($residentMeta, 16)
        $actSum = [BitConverter]::ToUInt32($residentMeta, 20)
        $wtSum = [BitConverter]::ToUInt32($residentMeta, 24)
        $vtcmBias = [BitConverter]::ToUInt32($residentMeta, 28)
        $lines.Add("Resident_${modeId}: KeeperMode=$keeperMode InvokeRc=$residentRc Status=$residentStatus Base=0x$($vtcmBase.ToString('X8')) ActSum=$actSum WtSum=$wtSum")
        if ($residentRc -ne 0 -or $residentStatus -ne 0 -or $vtcmBase -eq 0) { throw "VTCM residency setup failed for mode $modeId" }
        if ($modeId -in 1,2,3) {
            $oracleOut = [byte[]]::new($spec.OutBytes - 64)
            $oracleArgs = & $allocate 16
            $Marshal::WriteIntPtr($oracleArgs, 0, (& $pin $oracleOut))
            $Marshal::WriteInt64($oracleArgs, 8, $oracleOut.Length)
            $oracleReadRc = [int]$invoke.DynamicInvoke([object[]]@($keeperHandle, [uint32]0x03000100, $oracleArgs))
            $oracleNonZero = 0
            foreach ($b in $oracleOut) { if ($b -ne 0) { $oracleNonZero++ } }
            $lines.Add("CrmOracle_${modeId}: ReadRc=$oracleReadRc NonZeroBytes=$oracleNonZero SHA256=$(& $hash $oracleOut)")
            if ($oracleReadRc -ne 0 -or $oracleNonZero -eq 0 -or $oracleNonZero -eq $oracleOut.Length) { $allPassed = $false }

            # Restage the same inputs and restore the 0xA5 sentinel without running
            # the oracle, so the emitted kernel is measured against a clean output.
            $plainModeBytes = [BitConverter]::GetBytes($modeId)
            $Marshal::WriteIntPtr($residentArgs, 0, (& $pin $plainModeBytes))
            $resetRc = [int]$invoke.DynamicInvoke([object[]]@($keeperHandle, [uint32]0x02030100, $residentArgs))
            $resetStatus = [BitConverter]::ToInt32($residentMeta, 0)
            $lines.Add("ResidentReset_${modeId}: InvokeRc=$resetRc Status=$resetStatus")
            if ($resetRc -ne 0 -or $resetStatus -ne 0) { throw "VTCM output reset failed for mode $modeId" }
        }
        [Array]::Copy([BitConverter]::GetBytes($vtcmAct), 0, $cfgBytes, 4, 4)
        [Array]::Copy([BitConverter]::GetBytes($vtcmWt), 0, $cfgBytes, 8, 4)
        [Array]::Copy([BitConverter]::GetBytes($vtcmOut), 0, $cfgBytes, 12, 4)
        [Array]::Copy([BitConverter]::GetBytes($vtcmBias), 0, $cfgBytes, 16, 4)

        $cfgPtr = & $pin $cfgBytes
        $outPtr = & $pin $outBytes

        # FastRPC remote args: 4 arguments (16 bytes each on ARM64)
        $argsPtr = & $allocate (4 * 16)
        $Marshal::WriteIntPtr($argsPtr, 0,  $cfgPtr)
        $Marshal::WriteInt64($argsPtr,  8,  [long]$cfgBytes.Length)
        $Marshal::WriteIntPtr($argsPtr, 16, $actPtr)
        $Marshal::WriteInt64($argsPtr,  24, [long]$actBytes.Length)
        $Marshal::WriteIntPtr($argsPtr, 32, $wtPtr)
        $Marshal::WriteInt64($argsPtr,  40, [long]$wtBytes.Length)
        $Marshal::WriteIntPtr($argsPtr, 48, $outPtr)
        $Marshal::WriteInt64($argsPtr,  56, [long]$outBytes.Length)

        $invArgs = [object[]]@($handle, [uint32]0x02030100, $argsPtr)

        $sw = [Diagnostics.Stopwatch]::StartNew()
        $invokeRc = [int]$invoke.DynamicInvoke($invArgs)
        $sw.Stop()
        $invokeMs = $sw.Elapsed.TotalMilliseconds

        if ($invokeRc -eq 0) {
            $residentOut = [byte[]]::new($spec.OutBytes - 64)
            $readbackArgs = & $allocate 16
            $Marshal::WriteIntPtr($readbackArgs, 0, (& $pin $residentOut))
            $Marshal::WriteInt64($readbackArgs, 8, $residentOut.Length)
            $readbackRc = [int]$invoke.DynamicInvoke([object[]]@($keeperHandle, [uint32]0x03000100, $readbackArgs))
            $lines.Add("ResidentReadback_${modeId}Rc=$readbackRc")
            if ($readbackRc -ne 0) { $allPassed = $false }
            [Array]::Copy($residentOut, 0, $outBytes, 64, $residentOut.Length)
        }

        # Read Telemetry from output buffer
        $t0 = [BitConverter]::ToUInt64($outBytes, 0)
        $t1 = [BitConverter]::ToUInt64($outBytes, 8)
        $t2 = [BitConverter]::ToUInt64($outBytes, 16)
        $t3 = [BitConverter]::ToUInt64($outBytes, 24)

        $hvxUnlockRc  = [BitConverter]::ToInt32($outBytes, 32)
        $hmxTryLockRc = [BitConverter]::ToInt32($outBytes, 36)
        $hmxUnlockRc  = [BitConverter]::ToInt32($outBytes, 40)
        $hvxRelockRc  = [BitConverter]::ToInt32($outBytes, 44)
        $stepReached  = [BitConverter]::ToInt32($outBytes, 48)

        # Compute hardware tick deltas (19.2 MHz QTimer)
        $acquireTicks = if ($t1 -ge $t0) { $t1 - $t0 } else { 0 }
        $computeTicks = if ($t2 -ge $t1) { $t2 - $t1 } else { 0 }
        $releaseTicks = if ($t3 -ge $t2) { $t3 - $t2 } else { 0 }
        $totalTicks   = if ($t3 -ge $t0) { $t3 - $t0 } else { 0 }

        $acquireUs = [double]$acquireTicks / 19.2
        $computeUs = [double]$computeTicks / 19.2
        $releaseUs = [double]$releaseTicks / 19.2
        $totalUs   = [double]$totalTicks   / 19.2

        # Extract output tensor data (offset 64..)
        $dataBytes = [byte[]]::new($spec.OutBytes - 64)
        [Array]::Copy($outBytes, 64, $dataBytes, 0, $dataBytes.Length)
        $dataHash = & $hash $dataBytes

        $lines.Add("--- Mode_${modeId}_${modeName} ---")
        $lines.Add("InvokeRc=$invokeRc InvokeMs=$($invokeMs.ToString('F3', [Globalization.CultureInfo]::InvariantCulture))")
        $lines.Add("QuRTRc: HvxUnlock=$hvxUnlockRc HmxTryLock=$hmxTryLockRc HmxUnlock=$hmxUnlockRc HvxRelock=$hvxRelockRc")
        $lines.Add("StepReached=$stepReached")
        $lines.Add("RawTicks: T0=$t0 T1=$t1 T2=$t2 T3=$t3")
        $lines.Add("TickDeltas: Acquire=$acquireTicks Compute=$computeTicks Release=$releaseTicks Total=$totalTicks")
        $lines.Add("TimeUs: Acquire=$($acquireUs.ToString('F2', [Globalization.CultureInfo]::InvariantCulture))us Compute=$($computeUs.ToString('F2', [Globalization.CultureInfo]::InvariantCulture))us Release=$($releaseUs.ToString('F2', [Globalization.CultureInfo]::InvariantCulture))us Total=$($totalUs.ToString('F2', [Globalization.CultureInfo]::InvariantCulture))us")
        $lines.Add("DataBytes=$($dataBytes.Length) DataSHA256=$dataHash")

        # Sample output values (first 16 bytes)
        $sampleHex = [Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt [Math]::Min(16, $dataBytes.Length); $i++) {
            $sampleHex.Add(('{0:X2}' -f $dataBytes[$i]))
        }
        $lines.Add("DataHeaderBytes=" + ($sampleHex -join ' '))

        # Decode diagnostic telemetry words
        if ($dataBytes.Length -ge 64) {
            $diagWords = [Collections.Generic.List[string]]::new()
            for ($w = 0; $w -lt 16; $w++) {
                $u = [BitConverter]::ToUInt32($dataBytes, $w * 4)
                $diagWords.Add("w$w=0x$($u.ToString('X8'))")
            }
            $lines.Add("DiagWords=" + ($diagWords -join ' '))
        }

        $nonZeroBytes = 0
        foreach ($b in $dataBytes) { if ($b -ne 0) { $nonZeroBytes++ } }
        $lines.Add("NonZeroDataBytes=$nonZeroBytes")

        $expectedStep = switch ($modeId) {
            0 { 0 }
            9 { 93 }
            10 { 104 }
            1 { 14 }
            2 { 24 }
            3 { 34 }
        }
        $expectedHash = ''
        $semanticPass = if ($modeId -eq 1) {
            $expected = [byte[]]::new(2048)
            for ($i = 0; $i -lt $expected.Length; $i += 2) { $expected[$i] = 0x00; $expected[$i + 1] = 0x50 }
            $expectedHash = & $hash $expected
            $dataHash -eq $expectedHash
        } elseif ($modeId -in 2,3) {
            $expected = [byte[]]::new(8192)
            for ($i = 0; $i -lt $expected.Length; $i += 4) { $expected[$i] = 0x20 }
            $expectedHash = & $hash $expected
            $dataHash -eq $expectedHash
        } elseif ($modeId -eq 10) {
            # The keeper poisons VTCM output with 0xA5. A clear-accumulator store must replace it with zero.
            $nonZeroBytes -eq 0
        } else {
            $true
        }
        if ($expectedHash) { $lines.Add("ExpectedSHA256=$expectedHash") }
        $modePassed = ($invokeRc -eq 0 -and $hvxUnlockRc -eq 0 -and $hmxTryLockRc -eq 0 -and
            $hmxUnlockRc -eq 0 -and $hvxRelockRc -eq 0 -and $stepReached -eq $expectedStep -and $semanticPass)
        $lines.Add("ModePassed=$modePassed SemanticPass=$semanticPass")
        if (-not $modePassed) {
            $allPassed = $false
        } elseif ($modeId -in 1,2,3) {
            # Warm distribution with resident operands. QTimer isolates the DSP
            # section; Stopwatch records the FastRPC boundary separately.
            $warmTicks = [Collections.Generic.List[uint64]]::new()
            $warmInvokeMs = [Collections.Generic.List[double]]::new()
            for ($iteration = 0; $iteration -lt 31; $iteration++) {
                $warmWatch = [Diagnostics.Stopwatch]::StartNew()
                $warmRc = [int]$invoke.DynamicInvoke($invArgs)
                $warmWatch.Stop()
                if ($warmRc -ne 0) { throw "Warm matrix invocation failed for mode $modeId at iteration $iteration" }
                $warmT1 = [BitConverter]::ToUInt64($outBytes, 8)
                $warmT2 = [BitConverter]::ToUInt64($outBytes, 16)
                if ($warmT2 -lt $warmT1) { throw "QTimer regressed for mode $modeId at iteration $iteration" }
                $warmTicks.Add($warmT2 - $warmT1)
                $warmInvokeMs.Add($warmWatch.Elapsed.TotalMilliseconds)
            }
            $tickArray = $warmTicks.ToArray(); [Array]::Sort($tickArray)
            $invokeArray = $warmInvokeMs.ToArray(); [Array]::Sort($invokeArray)
            $p95 = [Math]::Ceiling($tickArray.Length * 0.95) - 1
            $lines.Add("Warm31_ComputeTicks: Min=$($tickArray[0]) Med=$($tickArray[15]) P95=$($tickArray[$p95]) Max=$($tickArray[-1])")
            $lines.Add("Warm31_InvokeMs: Min=$($invokeArray[0].ToString('F3', [Globalization.CultureInfo]::InvariantCulture)) Med=$($invokeArray[15].ToString('F3', [Globalization.CultureInfo]::InvariantCulture)) P95=$($invokeArray[$p95].ToString('F3', [Globalization.CultureInfo]::InvariantCulture)) Max=$($invokeArray[-1].ToString('F3', [Globalization.CultureInfo]::InvariantCulture))")
        }
    }

    $passed = $allPassed
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
    if ($keeperOpened) {
        try {
            $rc = [int]$close.DynamicInvoke([object[]]@($keeperHandle))
            $lines.Add("PowerKeeperCloseRc=$rc")
        }
        catch { $lines.Add('PowerKeeperCloseError=' + $_.Exception.Message) }
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
[void][Android.Util.Log]::Info('KokoroHmxMatrix', ($lines -join ' | '))
