#requires -Version 7.0
# R009 F0/N second pair (F65 -> F130) with the shortcut upsample built as Reshape+Concat+Reshape
# instead of Resize. Graph is constructed through the QNN C API on device; nothing is compiled.
$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$lines = [Collections.Generic.List[string]]::new()
$lines.Add("Pid=$([Environment]::ProcessId)"); $lines.Add('Job=r009-concat')
try {
    $qnn = [IO.Path]::Combine($root, 'qnn')
    $dsp = (@($qnn, '/vendor/lib/rfsa/adsp', '/vendor/dsp/cdsp', '/dsp') -join ';')
    foreach ($v in 'ADSP_LIBRARY_PATH', 'DSP_LIBRARY_PATH') { [Environment]::SetEnvironmentVariable($v, $dsp); [Android.Systems.Os]::Setenv($v, $dsp, $true) }
    foreach ($so in 'libQnnHtpV73Stub.so', 'libQnnHtp.so') { [void][Runtime.InteropServices.NativeLibrary]::Load([IO.Path]::Combine($qnn, $so)) }

    $mr = [IO.Path]::Combine($root, 'r009-modules')
    $load = { param([string]$n, [object[]]$a) [scriptblock]::Create([IO.File]::ReadAllText([IO.Path]::Combine($mr, $n))).InvokeReturnAsIs($a) }
    $abi = & $load 'Qnn.Abi.psm1' ([object[]]@())
    $native = & $load 'Qnn.Native.psm1' ([object[]]@($abi))
    $graph = & $load 'Qnn.Graph.psm1' ([object[]]@($abi, $native))
    $cap = & $load 'Kokoro.F0NSecondPairPolyphaseR009.psm1' ([object[]]@($abi, $native, $graph))

    # Qnn.Native.Initialize wants libQnnHtpPrepare.so under DataRoot and ADSP_LIBRARY_PATH at NativeLibraryDirectory;
    # on this host both are the app-storage qnn directory, not the APK native dir.
    $android = [pscustomobject]@{ DataRoot = $qnn; NativeLibraryDirectory = $qnn }
    $r = $cap.Invoke.InvokeReturnAsIs($android, [IO.Path]::Combine($root, 'r009-polyphase'))
    foreach ($k in 'Proof','Passed','Stage','Error','InputDomain','OutputDomain','OperationCount','ValidateRc','FinalizeRc','ExecuteRc','F0MaxAbs','F0Rmse','N0MaxAbs','N0Rmse','MaxAbs','Rmse','Tolerance','ContextBytes','Diag','CloseRc') {
        $lines.Add("$k=$($r.$k)")
    }
    [int]$bad = 0; foreach ($c in $r.AddCodes) { if ($c -ne 0) { $bad++ } }
    $lines.Add("AddCodesNonZero=$bad")
}
catch { $lines.Add('Passed=False'); $lines.Add("Error=$($_.Exception.Message)"); $lines.Add("At=$($_.InvocationInfo.PositionMessage -replace '\s+', ' ')") }
[IO.File]::WriteAllLines([IO.Path]::Combine($root, 'receipt.txt'), $lines)
[void][Android.Util.Log]::Info('KokoroRpc', ($lines -join ' | '))
