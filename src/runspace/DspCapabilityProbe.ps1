#requires -Version 7.0
# Hardware capability and resource probe for Qualcomm CDSP via libcdsprpc.so.
# Queries Hexagon architecture version, HVX unit count, VTCM page geometry, and HMX silicon availability.

$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$dir = [IO.Path]::Combine($root, 'cap-emitted')
$receipt = [IO.Path]::Combine($dir, 'receipt.txt')
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('Job=dsp-capability-probe')
$save = { [IO.File]::WriteAllLines($receipt, $lines) }
$M = [Runtime.InteropServices.Marshal]; $native = [IntPtr]::Zero
$allocations = [Collections.Generic.List[object]]::new()
$passed = $false; $watch = [Diagnostics.Stopwatch]::StartNew()

try {
    $modulePath = [IO.Path]::Combine($root, 'emit.Qnn.Abi.ps1')
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Delegate factory parse failed' }
    $abi = $ast.GetScriptBlock().InvokeReturnAsIs()

    $search = [IO.Path]::Combine($root, 'qnn') + ';/vendor/lib/rfsa/adsp;/vendor/dsp/cdsp;/dsp'
    foreach ($name in 'ADSP_LIBRARY_PATH', 'DSP_LIBRARY_PATH') {
        [Environment]::SetEnvironmentVariable($name, $search)
        [Android.Systems.Os]::Setenv($name, $search, $true)
    }

    $native = [Runtime.InteropServices.NativeLibrary]::Load('libcdsprpc.so')
    $fn = { param($Name, $ReturnType, $Parameters)
        $M::GetDelegateForFunctionPointer([Runtime.InteropServices.NativeLibrary]::GetExport($native, $Name),
            (& $abi.NewDelegateType ('Cap_' + $Name) $ReturnType $Parameters))
    }
    $sessionControl = & $fn 'remote_session_control' ([int]) ([Type[]]@([uint32], [IntPtr], [uint32]))
    $handleControl  = & $fn 'remote_handle_control'  ([int]) ([Type[]]@([uint32], [IntPtr], [uint32]))

    $allocate = { param([int]$Size)
        $ptr = $M::AllocHGlobal($Size)
        $allocations.Add(@($ptr, $Size))
        $M::Copy([byte[]]::new($Size), 0, $ptr, $Size)
        $ptr
    }

    # Enable unsigned PD (config: { 3, 1 })
    $config = & $allocate 8
    $M::WriteInt32($config, 0, 3)
    $M::WriteInt32($config, 4, 1)
    $rc = [int]$sessionControl.DynamicInvoke([object[]]@([uint32]2, $config, [uint32]8))
    $lines.Add("UnsignedPdRc=$rc")
    if ($rc -ne 0) { throw 'Unsigned PD configuration failed' }

    # Query DSP capabilities via DSPRPC_GET_DSP_INFO (req = 2)
    # fastrpc_capability: { uint32 domain, uint32 attribute_ID, uint32 capability }
    $capBuffer = & $allocate 12
    $cdspDomain = [uint32]3

    $attributes = [ordered]@{
        DOMAIN_SUPPORT             = 0
        UNSIGNED_PD_SUPPORT        = 1
        HVX_SUPPORT_64B            = 2
        HVX_SUPPORT_128B           = 3
        VTCM_PAGE                  = 4
        VTCM_COUNT                 = 5
        ARCH_VER                   = 6
        HMX_SUPPORT_DEPTH          = 7
        HMX_SUPPORT_SPATIAL        = 8
        ASYNC_FASTRPC_SUPPORT      = 9
        STATUS_NOTIFICATION_SUPPORT = 10
        MCID_MULTICAST             = 11
        EXTENDED_MAP_SUPPORT       = 12
        HANDLE_PRIORITY_SUPPORT    = 13
        DSP_IMAGE_CONFIG           = 14
    }

    foreach ($kv in $attributes.GetEnumerator()) {
        $attrName = $kv.Key
        $attrId = [uint32]$kv.Value

        $M::WriteInt32($capBuffer, 0, [int]$cdspDomain)
        $M::WriteInt32($capBuffer, 4, [int]$attrId)
        $M::WriteInt32($capBuffer, 8, 0)

        $qrc = [int]$handleControl.DynamicInvoke([object[]]@([uint32]2, $capBuffer, [uint32]12))
        $val = [uint32]$M::ReadInt32($capBuffer, 8)
        $lines.Add("Cap_${attrName}=${val} (rc=${qrc})")
    }

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
    if ($native -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.NativeLibrary]::Free($native)
    }
}

$lines.Add("ElapsedMs=$($watch.Elapsed.TotalMilliseconds.ToString('F3', [Globalization.CultureInfo]::InvariantCulture))")
$lines.Add("Passed=$passed")
& $save
[void][Android.Util.Log]::Info('DspCapProbe', ($lines -join ' | '))
