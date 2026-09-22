#requires -Version 7.0
# Executes a precompiled Kokoro context on Hexagon HTP from the AndroidSMA runspace and writes a receipt.
# Layout under files/kokoro-fl: qnn/*.so, modules/*.psm1, job.psd1, context binary, inputs and oracle (.f32).
$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$receiptPath = [IO.Path]::Combine($root, 'receipt.txt')
$lines = [Collections.Generic.List[string]]::new()
$lines.Add("Pid=$([Environment]::ProcessId)")
try {
    $job = [scriptblock]::Create([IO.File]::ReadAllText([IO.Path]::Combine($root, 'job.ps1'))).InvokeReturnAsIs()
    $lines.Add("Job=$($job.Name)")
    $qnn = [IO.Path]::Combine($root, 'qnn')
    # DSP search path: runtime dir plus platform defaults (local-dream BackendService.kt).
    $dsp = (@($qnn, '/vendor/lib/rfsa/adsp', '/vendor/dsp/cdsp', '/dsp') -join ';')
    foreach ($v in 'ADSP_LIBRARY_PATH', 'DSP_LIBRARY_PATH') { [Environment]::SetEnvironmentVariable($v, $dsp); [Android.Systems.Os]::Setenv($v, $dsp, $true) }
    foreach ($so in 'libQnnHtpV73Stub.so', 'libQnnHtp.so') { [void][Runtime.InteropServices.NativeLibrary]::Load([IO.Path]::Combine($qnn, $so)) }   # sonames resident for by-name dlopen
    $load = { param([string]$n, [object[]]$a) [scriptblock]::Create([IO.File]::ReadAllText([IO.Path]::Combine($root, 'modules', $n))).InvokeReturnAsIs($a) }
    $abi = & $load 'Qnn.Abi.psm1' @()
    $native = & $load 'Qnn.Native.psm1' @($abi)
    $graph = & $load 'Qnn.Graph.psm1' @($abi, $native)
    $ctx = & $load 'Qnn.Context.psm1' @($abi, $native, $graph)
    [void](& $native.Initialize ([pscustomobject]@{ DataRoot = $qnn; NativeLibraryDirectory = $dsp }))
    $lines.Add("BackendRc=$($native.State.BackendCreateRc) DeviceRc=$($native.State.DeviceCreateRc)")
    if ($native.State.DeviceCreateRc -ne 0) { throw "deviceCreate rc=$($native.State.DeviceCreateRc)" }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $trial = & $ctx.LoadContext ([IO.Path]::Combine($root, $job.Context)) $job.GraphName
    $lines.Add("LoadMs=$($sw.ElapsedMilliseconds) ContextBytes=$($trial.ContextBytes)")
    $arena = & $graph.NewArena
    try {
        $ins = foreach ($t in $job.Inputs) {
            [byte[]]$b = [IO.File]::ReadAllBytes([IO.Path]::Combine($root, $t.File))
            $d = & $ctx.BindTensor $arena $t.Id $t.Name ([int]$abi.Enum.AppWrite) ([int]$abi.Enum.Float32) $t.Shape
            & $graph.NewExecTensor $arena $d $b
        }
        $outs = @(if ($null -ne $job.Outputs) { $job.Outputs } else { $job.Output })
        $eos = foreach ($o in $outs) {
            $od = & $ctx.BindTensor $arena $o.Id $o.Name ([int]$abi.Enum.AppRead) ([int]$abi.Enum.Float32) $o.Shape
            & $graph.NewExecTensor $arena $od ([byte[]]::new($o.Bytes))
        }
        $times = foreach ($i in 1..3) {
            $sw.Restart()
            [uint64]$rc = & $graph.Execute $trial $arena ([object[]]@($ins)) ([object[]]@($eos))
            if ($rc -ne 0) { throw "graphExecute rc=$rc" }
            $sw.Elapsed.TotalMilliseconds
        }
        [string[]]$ts = foreach ($t in $times) { ([double]$t).ToString('F1') }; $lines.Add("ExecuteMs=$([string]::Join(',', $ts))")
        [bool]$allPass = $true
        for ($k = 0; $k -lt $outs.Count; $k++) {
            $o = $outs[$k]; $eo = $eos[$k]
            [byte[]]$outBytes = [byte[]]::new($o.Bytes)
            [Runtime.InteropServices.Marshal]::Copy($eo.DataPtr, $outBytes, 0, $outBytes.Length)
            [IO.File]::WriteAllBytes([IO.Path]::Combine($root, $o.File), $outBytes)
            $n = $outBytes.Length / 4
            [float[]]$y = [float[]]::new($n); [Buffer]::BlockCopy($outBytes, 0, $y, 0, $outBytes.Length)
            [float[]]$ref = [float[]]::new($n); [Buffer]::BlockCopy([IO.File]::ReadAllBytes([IO.Path]::Combine($root, $o.Oracle)), 0, $ref, 0, $outBytes.Length)
            [double]$max = 0; [double]$se = 0; [double]$sr = 0; [double]$sy = 0; [int]$bad = 0
            for ($i = 0; $i -lt $n; $i++) {
                if (-not [float]::IsFinite($y[$i])) { $bad++; continue }
                $e = [double]$y[$i] - $ref[$i]; $se += $e * $e; $sr += [double]$ref[$i] * $ref[$i]; $sy += [Math]::Abs([double]$y[$i])
                if ([Math]::Abs($e) -gt $max) { $max = [Math]::Abs($e) }
            }
            $snr = if ($se -gt 0) { 10 * [Math]::Log10($sr / $se) } else { [double]::PositiveInfinity }
            $lines.Add("Out[$($o.Name)] NonFinite=$bad MaxAbs=$($max.ToString('G5')) SnrDb=$($snr.ToString('F2')) MeanAbs=$(($sy / $n).ToString('G5'))")
            if ($bad -ne 0 -or $snr -lt $job.MinSnrDb) { $allPass = $false }
        }
        $lines.Add("Passed=$allPass")
    }
    finally {
        $lines.Add("CloseRc=$(& $native.CloseTrial $trial)")
        & $graph.FreeArena $arena
    }
}
catch { $lines.Add("Passed=False"); $lines.Add("Error=$($_.Exception.Message)"); $lines.Add("At=$($_.InvocationInfo.PositionMessage -replace '\s+', ' ')") }
[IO.File]::WriteAllLines($receiptPath, $lines)
[void][Android.Util.Log]::Info('KokoroFL', ($lines -join ' | '))
