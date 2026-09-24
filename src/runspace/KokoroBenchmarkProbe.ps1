#requires -Version 7.0
# Hardware Benchmark Probe on Physical Hexagon V73 (Samsung Galaxy S23 / SM8550).
# Side-by-side comparison between:
# Competitor A: Pure PowerShell Direct Emitted V73 Kernel (libkokoro_r0sub0_skel.so)
# Competitor B: Qualcomm Hexagon LLVM Clang 19.0.04 Compiled Kernel (libkokoro_r0sub0_llvm_skel.so)
#
# Enforces:
# Gate A: 100% Cryptographic Bit-Exact Output Parity (PS_OutSHA256 == LLVM_OutSHA256).
# Gate B: DSP-side hardware cycle counter (pcycle) and FastRPC InvokeMs benchmark over 12 warm iterations.

$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$dir = [IO.Path]::Combine($root, 'benchmark')
$null = [IO.Directory]::CreateDirectory($dir)
$receipt = [IO.Path]::Combine($dir, 'receipt.txt')
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('Job=kokoro-r0sub0-benchmark')
$save = { [IO.File]::WriteAllLines($receipt, $lines) }
$hash = { param([byte[]]$Bytes) [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)) }
$M = [Runtime.InteropServices.Marshal]; $native = [IntPtr]::Zero
$pins = [Collections.Generic.List[object]]::new(); $allocations = [Collections.Generic.List[object]]::new()
$passed = $false; $setup = [Diagnostics.Stopwatch]::StartNew()

try {
    $modulePath = [IO.Path]::Combine($root, 'emit.Qnn.Abi.ps1')
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Delegate factory parse failed' }
    $abi = $ast.GetScriptBlock().InvokeReturnAsIs()

    $soPS   = [IO.Path]::Combine($root, 'qnn', 'libkokoro_r0sub0_skel.so')
    $soLLVM = [IO.Path]::Combine($root, 'qnn', 'libkokoro_r0sub0_llvm_skel.so')
    $hashPS   = & $hash ([IO.File]::ReadAllBytes($soPS))
    $hashLLVM = & $hash ([IO.File]::ReadAllBytes($soLLVM))
    $lines.Add("LibraryPS_SHA256=$hashPS")
    $lines.Add("LibraryLLVM_SHA256=$hashLLVM")

    $search = [IO.Path]::Combine($root, 'qnn') + ';/vendor/lib/rfsa/adsp;/vendor/dsp/cdsp;/dsp'
    foreach ($name in 'ADSP_LIBRARY_PATH', 'DSP_LIBRARY_PATH') {
        [Environment]::SetEnvironmentVariable($name, $search)
        [Android.Systems.Os]::Setenv($name, $search, $true)
    }

    $native = [Runtime.InteropServices.NativeLibrary]::Load('libcdsprpc.so')
    $fn = { param($Name, $ReturnType, $Parameters)
        $M::GetDelegateForFunctionPointer([Runtime.InteropServices.NativeLibrary]::GetExport($native, $Name),
            (& $abi.NewDelegateType ('Bench_' + $Name) $ReturnType $Parameters))
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

    # Resident input data:
    $weights = [IO.File]::ReadAllBytes([IO.Path]::Combine($root, 'r0', 'r0_static.bin'))
    $inZ     = [IO.File]::ReadAllBytes([IO.Path]::Combine($root, 'r0', 'in_z.f32'))
    $inMask  = [IO.File]::ReadAllBytes([IO.Path]::Combine($root, 'r0', 'in_mask1.f32'))
    $lines.Add("WeightsBytes=$($weights.Length) InZBytes=$($inZ.Length) InMaskBytes=$($inMask.Length)")

    $dynParams = [byte[]]::new(2048)
    [Buffer]::BlockCopy($weights, 1182720, $dynParams, 0, 512)
    [Buffer]::BlockCopy($weights, 1183232, $dynParams, 512, 512)
    [Buffer]::BlockCopy($weights, 1185792, $dynParams, 1024, 512)
    [Buffer]::BlockCopy($weights, 1186304, $dynParams, 1536, 512)

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

    # Working and output buffers:
    $workspace  = [byte[]]::new($tensorBytes)
    $outputPS   = [byte[]]::new($tensorBytes)
    $outputLLVM = [byte[]]::new($tensorBytes)

    # Pin memory:
    $inZPtr        = & $pin $inZPad
    $inMaskPtr     = & $pin $inMaskPad
    $weightsPtr    = & $pin $weights
    $dynParamsPtr  = & $pin $dynParams
    $workspacePtr  = & $pin $workspace
    $outputPSPtr   = & $pin $outputPS
    $outputLLVMPtr = & $pin $outputLLVM

    $geometry = & $allocate 8
    $M::WriteInt32($geometry, 0, 7681)
    $M::WriteInt32($geometry, 4, 128)

    # Remote args structure: 7 arguments (8 bytes ptr + 8 bytes length = 16 bytes each on DSP)
    $argsPSPtr   = & $allocate (7 * 16)
    $argsLLVMPtr = & $allocate (7 * 16)

    $argListPS = @(
        @($geometry, 8),
        @($inZPtr, $inZPad.Length),
        @($inMaskPtr, $inMaskPad.Length),
        @($weightsPtr, $weights.Length),
        @($dynParamsPtr, $dynParams.Length),
        @($workspacePtr, $workspace.Length),
        @($outputPSPtr, $outputPS.Length)
    )
    for ($i = 0; $i -lt $argListPS.Count; $i++) {
        $M::WriteIntPtr($argsPSPtr, $i * 16, [IntPtr]$argListPS[$i][0])
        $M::WriteInt64($argsPSPtr, $i * 16 + 8, [long]$argListPS[$i][1])
    }

    $argListLLVM = @(
        @($geometry, 8),
        @($inZPtr, $inZPad.Length),
        @($inMaskPtr, $inMaskPad.Length),
        @($weightsPtr, $weights.Length),
        @($dynParamsPtr, $dynParams.Length),
        @($workspacePtr, $workspace.Length),
        @($outputLLVMPtr, $outputLLVM.Length)
    )
    for ($i = 0; $i -lt $argListLLVM.Count; $i++) {
        $M::WriteIntPtr($argsLLVMPtr, $i * 16, [IntPtr]$argListLLVM[$i][0])
        $M::WriteInt64($argsLLVMPtr, $i * 16 + 8, [long]$argListLLVM[$i][1])
    }

    $lines.Add("SetupMs=$($setup.Elapsed.TotalMilliseconds.ToString('F3', [Globalization.CultureInfo]::InvariantCulture))")
    & $save

    # Method 2: 5 in, 2 out -> 0x02050200 (pra[5] workspace and pra[6] output returned to host)
    $methodId = [uint32]0x02050200

    # =========================================================================
    # COMPETITOR A: Pure PowerShell Direct Emitted Hexagon V73 Kernel
    # =========================================================================
    $lines.Add('--- Starting Competitor A: PowerShell Emitted V73 ---')
    $uriPS = [Text.Encoding]::UTF8.GetBytes('file:///libkokoro_r0sub0_skel.so?kokoro_r0sub0_skel_handle_invoke&_modver=1.0&_dom=cdsp' + [char]0)
    $uriPSPtr = & $pin $uriPS
    $oaPS = [object[]]@($uriPSPtr, [uint64]0)
    $rc = [int]$open.DynamicInvoke($oaPS)
    $lines.Add("OpenPS_Rc=$rc")
    if ($rc -ne 0) { throw "PowerShell emitted library open failed: rc=$rc" }
    $handlePS = [uint64]$oaPS[1]

    # Cold invoke:
    [Array]::Clear($workspace, 0, $workspace.Length)
    [Array]::Clear($outputPS, 0, $outputPS.Length)
    $invArgsPS = [object[]]@($handlePS, $methodId, $argsPSPtr)

    $coldPS = [Diagnostics.Stopwatch]::StartNew()
    $rc = [int]$invoke.DynamicInvoke($invArgsPS)
    $coldPS.Stop()
    $lines.Add("ColdInvokePS_Rc=$rc ColdInvokePS_Ms=$($coldPS.Elapsed.TotalMilliseconds.ToString('F3', [Globalization.CultureInfo]::InvariantCulture))")
    if ($rc -ne 0) { throw "PowerShell cold invoke failed: rc=$rc" }

    $outHashPS = & $hash $outputPS
    $lines.Add("OutSHA256_PS=$outHashPS")
    & $save

    # 12 Warm iterations for Competitor A:
    $timingsPS_Ms = [double[]]::new(12)
    $cyclesPS = [ulong[]]::new(12)
    for ($iter = 0; $iter -lt 12; $iter++) {
        [Array]::Clear($workspace, 0, 16)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $rc = [int]$invoke.DynamicInvoke($invArgsPS)
        $sw.Stop()
        if ($rc -ne 0) { throw "PowerShell warm invoke failed at iter $($iter): rc=$rc" }
        $timingsPS_Ms[$iter] = $sw.Elapsed.TotalMilliseconds
        $t0 = [BitConverter]::ToUInt64($workspace, 0)
        $t1 = [BitConverter]::ToUInt64($workspace, 8)
        $cyclesPS[$iter] = $t1 - $t0
        $lines.Add(("Iter={0} PS_Cycles={1} PS_Ms={2:F3}" -f $iter, $cyclesPS[$iter], $timingsPS_Ms[$iter]))
        & $save
    }

    $closeRc = [int]$close.DynamicInvoke([object[]]@($handlePS))
    $lines.Add("ClosePS_Rc=$closeRc")

    # =========================================================================
    # COMPETITOR B: Qualcomm Hexagon LLVM Clang Compiled Kernel
    # =========================================================================
    $lines.Add('--- Starting Competitor B: LLVM Clang 19.0.04 V73 ---')
    $uriLLVM = [Text.Encoding]::UTF8.GetBytes('file:///libkokoro_r0sub0_llvm_skel.so?kokoro_r0sub0_skel_handle_invoke&_modver=1.0&_dom=cdsp' + [char]0)
    $uriLLVMPtr = & $pin $uriLLVM
    $oaLLVM = [object[]]@($uriLLVMPtr, [uint64]0)
    $rc = [int]$open.DynamicInvoke($oaLLVM)
    $lines.Add("OpenLLVM_Rc=$rc")
    if ($rc -ne 0) { throw "LLVM library open failed: rc=$rc" }
    $handleLLVM = [uint64]$oaLLVM[1]

    # Cold invoke:
    [Array]::Clear($workspace, 0, $workspace.Length)
    [Array]::Clear($outputLLVM, 0, $outputLLVM.Length)
    $invArgsLLVM = [object[]]@($handleLLVM, $methodId, $argsLLVMPtr)

    $coldLLVM = [Diagnostics.Stopwatch]::StartNew()
    $rc = [int]$invoke.DynamicInvoke($invArgsLLVM)
    $coldLLVM.Stop()
    $lines.Add("ColdInvokeLLVM_Rc=$rc ColdInvokeLLVM_Ms=$($coldLLVM.Elapsed.TotalMilliseconds.ToString('F3', [Globalization.CultureInfo]::InvariantCulture))")
    if ($rc -ne 0) { throw "LLVM cold invoke failed: rc=$rc" }

    $outHashLLVM = & $hash $outputLLVM
    $lines.Add("OutSHA256_LLVM=$outHashLLVM")
    & $save

    # 12 Warm iterations for Competitor B:
    $timingsLLVM_Ms = [double[]]::new(12)
    $cyclesLLVM = [ulong[]]::new(12)
    for ($iter = 0; $iter -lt 12; $iter++) {
        [Array]::Clear($workspace, 0, 16)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $rc = [int]$invoke.DynamicInvoke($invArgsLLVM)
        $sw.Stop()
        if ($rc -ne 0) { throw "LLVM warm invoke failed at iter $($iter): rc=$rc" }
        $timingsLLVM_Ms[$iter] = $sw.Elapsed.TotalMilliseconds
        $t0 = [BitConverter]::ToUInt64($workspace, 0)
        $t1 = [BitConverter]::ToUInt64($workspace, 8)
        $cyclesLLVM[$iter] = $t1 - $t0
        $lines.Add(("Iter={0} LLVM_Cycles={1} LLVM_Ms={2:F3}" -f $iter, $cyclesLLVM[$iter], $timingsLLVM_Ms[$iter]))
        & $save
    }

    $closeRc = [int]$close.DynamicInvoke([object[]]@($handleLLVM))
    $lines.Add("CloseLLVM_Rc=$closeRc")

    # =========================================================================
    # GATE A: CRYPTOGRAPHIC OUTPUT PARITY & DIFFERENTIAL AUDIT
    # =========================================================================
    $lines.Add('--- Gate A: Output Parity Verification ---')
    $refGoldHash = '29070BE9E9F13568184E5F2BBFDC85577D74236A02B61DC0D97238D8F8B2C75D'
    $lines.Add("ReferenceGoldSHA256=$refGoldHash")

    $psMatchesGold = ($outHashPS -eq $refGoldHash)
    $llvmMatchesGold = ($outHashLLVM -eq $refGoldHash)
    $psMatchesLLVM = ($outHashPS -eq $outHashLLVM)

    $lines.Add("PS_MatchesGold=$psMatchesGold")
    $lines.Add("LLVM_MatchesGold=$llvmMatchesGold")
    $lines.Add("PS_Matches_LLVM=$psMatchesLLVM")

    if (-not $psMatchesLLVM) {
        $firstDiff = -1
        for ($b = 0; $b -lt $outputPS.Length; $b += 4) {
            $fPS = [BitConverter]::ToSingle($outputPS, $b)
            $fLLVM = [BitConverter]::ToSingle($outputLLVM, $b)
            if ([BitConverter]::SingleToInt32Bits($fPS) -ne [BitConverter]::SingleToInt32Bits($fLLVM)) {
                $firstDiff = $b
                $lines.Add("GateA_MismatchByte=$b OffsetFloats=$($b/4) PS_Val=$fPS LLVM_Val=$fLLVM")
                break
            }
        }
        throw "Gate A FAILED: Output SHA256 mismatch between PowerShell and LLVM at byte $firstDiff"
    }

    $lines.Add("GateA_Passed=True")

    # =========================================================================
    # GATE B: CYCLE & TIME BENCHMARK STATISTICS
    # =========================================================================
    $lines.Add('--- Gate B: Hardware Performance Ratchet ---')
    $sortedCyclesPS = ( [ulong[]]$cyclesPS.Clone() ); [Array]::Sort($sortedCyclesPS)
    $sortedCyclesLLVM = ( [ulong[]]$cyclesLLVM.Clone() ); [Array]::Sort($sortedCyclesLLVM)
    $sortedMsPS = ( [double[]]$timingsPS_Ms.Clone() ); [Array]::Sort($sortedMsPS)
    $sortedMsLLVM = ( [double[]]$timingsLLVM_Ms.Clone() ); [Array]::Sort($sortedMsLLVM)

    $medCyclesPS = ($sortedCyclesPS[5] + $sortedCyclesPS[6]) / 2.0
    $medCyclesLLVM = ($sortedCyclesLLVM[5] + $sortedCyclesLLVM[6]) / 2.0
    $p95CyclesPS = $sortedCyclesPS[10]
    $p95CyclesLLVM = $sortedCyclesLLVM[10]

    $medMsPS = ($sortedMsPS[5] + $sortedMsPS[6]) / 2.0
    $medMsLLVM = ($sortedMsLLVM[5] + $sortedMsLLVM[6]) / 2.0

    $cyclesSpeedup = [double]$medCyclesLLVM / [double]$medCyclesPS
    $msSpeedup = [double]$medMsLLVM / [double]$medMsPS

    $lines.Add(("PS_Cycles: Min={0} Med={1:F0} P95={2} Max={3}" -f $sortedCyclesPS[0], $medCyclesPS, $p95CyclesPS, $sortedCyclesPS[11]))
    $lines.Add(("LLVM_Cycles: Min={0} Med={1:F0} P95={2} Max={3}" -f $sortedCyclesLLVM[0], $medCyclesLLVM, $p95CyclesLLVM, $sortedCyclesLLVM[11]))
    $lines.Add(("PS_InvokeMs: Min={0:F3} Med={1:F3} Max={2:F3}" -f $sortedMsPS[0], $medMsPS, $sortedMsPS[11]))
    $lines.Add(("LLVM_InvokeMs: Min={0:F3} Med={1:F3} Max={2:F3}" -f $sortedMsLLVM[0], $medMsLLVM, $sortedMsLLVM[11]))
    $lines.Add(("Speedup_Cycles_LLVM_over_PS={0:F3}x" -f $cyclesSpeedup))
    $lines.Add(("Speedup_InvokeMs_LLVM_over_PS={0:F3}x" -f $msSpeedup))

    $lines.Add("GateB_Passed=True")
    $passed = $true
}
catch {
    $lines.Add('Error=' + $_.Exception.Message)
    $lines.Add('At=' + $_.InvocationInfo.ScriptLineNumber)
}
finally {
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
[void][Android.Util.Log]::Info('KokoroBenchmark', ($lines -join ' | '))
