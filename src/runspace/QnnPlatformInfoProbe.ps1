#requires -Version 7.0
# Diagnostic harness: asks the pinned QNN 2.46 HTP runtime what it reports for this SoC
# (QnnDevice_getPlatformInfo). QNN is a reference here only; the product never loads it.
# Offsets from lib/qairt-2.46/Layouts.psd1 (aarch64):
#   QnnInterface_t: implementation at +40; deviceGetPlatformInfo slot 37, deviceFreePlatformInfo 38, backendCreate 1.
#   QnnDevice_PlatformInfo_t: version @0, v1.numHwDevices @8, v1.hwDevices @16.
#   QnnDevice_HardwareDeviceInfo_t (40 B): version @0, deviceId @8, deviceType @12, numCores @16,
#     cores @24, deviceInfoExtension @32 (pointer).
#   QnnHtpDevice_DeviceInfoExtension_t: devType @0, onChipDevice @8:
#     vtcmSize (size_t) @8, socModel @16, signedPdSupport @20, dlbcSupport @21, arch @24.
$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$qnn = [IO.Path]::Combine($root, 'qnn')
$dir = [IO.Path]::Combine($root, 'qnn-platform')
$receipt = [IO.Path]::Combine($dir, 'receipt.txt')
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('Job=qnn-platform-info')
$M = [Runtime.InteropServices.Marshal]; $passed = $false
try {
    $ast = [Management.Automation.Language.Parser]::ParseFile([IO.Path]::Combine($root, 'Native.Binding.psm1'), [ref]$null, [ref]$null)
    $abi = $ast.GetScriptBlock().InvokeReturnAsIs()
    foreach ($n in 'libQnnHtp.so', 'libQnnHtpV73Stub.so', 'libQnnHtpV73Skel.so') {
        $lines.Add("$n SHA256=" + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes([IO.Path]::Combine($qnn, $n)))))
    }
    $search = $qnn + ';/vendor/lib/rfsa/adsp;/vendor/dsp/cdsp;/dsp'
    foreach ($name in 'ADSP_LIBRARY_PATH', 'DSP_LIBRARY_PATH') {
        [Environment]::SetEnvironmentVariable($name, $search)
        [Android.Systems.Os]::Setenv($name, $search, $true)
    }
    $null = [Runtime.InteropServices.NativeLibrary]::Load([IO.Path]::Combine($qnn, 'libQnnHtpV73Stub.so'))
    $lib = [Runtime.InteropServices.NativeLibrary]::Load([IO.Path]::Combine($qnn, 'libQnnHtp.so'))
    $delegate = { param($Pointer, $Name, $ReturnType, $Parameters)
        $M::GetDelegateForFunctionPointer($Pointer, (& $abi.NewDelegateType ('QnnInfo_' + $Name) $ReturnType $Parameters))
    }
    $getProviders = & $delegate ([Runtime.InteropServices.NativeLibrary]::GetExport($lib, 'QnnInterface_getProviders')) 'GetProviders' ([uint64]) ([Type[]]@(([IntPtr]).MakeByRefType(), ([uint32]).MakeByRefType()))
    $pa = [object[]]@([IntPtr]::Zero, [uint32]0)
    $rc = [uint64]$getProviders.DynamicInvoke($pa)
    $lines.Add("GetProvidersRc=$rc Providers=$($pa[1])"); if ($rc -ne 0) { throw 'getProviders failed' }
    $provider = $M::ReadIntPtr([IntPtr]$pa[0], 0)
    $functions = [IntPtr]($provider.ToInt64() + 40)
    $slot = { param([int]$i) $M::ReadIntPtr($functions, 8 * $i) }
    $getInfo = & $delegate (& $slot 37) 'GetPlatformInfo' ([uint64]) ([Type[]]@([IntPtr], ([IntPtr]).MakeByRefType()))
    $freeInfo = & $delegate (& $slot 38) 'FreePlatformInfo' ([uint64]) ([Type[]]@([IntPtr], [IntPtr]))
    $ia = [object[]]@([IntPtr]::Zero, [IntPtr]::Zero)
    $rc = [uint64]$getInfo.DynamicInvoke($ia)
    $lines.Add("GetPlatformInfoRc=$rc (before backendCreate)")
    if ($rc -ne 0) {
        $backendCreate = & $delegate (& $slot 1) 'BackendCreate' ([uint64]) ([Type[]]@([IntPtr], [IntPtr], ([IntPtr]).MakeByRefType()))
        $ba = [object[]]@([IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
        $lines.Add("BackendCreateRc=" + [uint64]$backendCreate.DynamicInvoke($ba))
        $ia = [object[]]@([IntPtr]::Zero, [IntPtr]::Zero)
        $rc = [uint64]$getInfo.DynamicInvoke($ia)
        $lines.Add("GetPlatformInfoRc=$rc (after backendCreate)")
    }
    if ($rc -ne 0) { throw 'getPlatformInfo failed' }
    $info = [IntPtr]$ia[1]
    $count = $M::ReadInt32($info, 8); $devices = $M::ReadIntPtr($info, 16)
    $lines.Add("PlatformInfoVersion=$($M::ReadInt32($info, 0)) HwDevices=$count")
    for ($d = 0; $d -lt [math]::Min($count, 8); $d++) {
        $dev = [IntPtr]($devices.ToInt64() + 40 * $d)
        $ext = $M::ReadIntPtr($dev, 32)
        $line = "Device=$d Version=$($M::ReadInt32($dev, 0)) DeviceId=$($M::ReadInt32($dev, 8)) DeviceType=$($M::ReadInt32($dev, 12)) Cores=$($M::ReadInt32($dev, 16))"
        if ($ext -ne [IntPtr]::Zero) {
            $line += " ExtDevType=$($M::ReadInt32($ext, 0)) VtcmSize=$($M::ReadInt64($ext, 8)) SocModel=$($M::ReadInt32($ext, 16))"
            $line += " SignedPd=$($M::ReadByte($ext, 20)) Dlbc=$($M::ReadByte($ext, 21)) Arch=$($M::ReadInt32($ext, 24))"
        }
        $lines.Add($line)
    }
    $lines.Add("FreePlatformInfoRc=" + [uint64]$freeInfo.DynamicInvoke([object[]]@([IntPtr]::Zero, $info)))
    $passed = $count -gt 0
}
catch { $lines.Add('Error=' + $_.Exception.Message.Replace("`r", ' ').Replace("`n", ' ')) }
finally {
    $lines.Add("Passed=$passed")
    [IO.File]::WriteAllLines($receipt, $lines)
}
