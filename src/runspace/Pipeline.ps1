#requires -Version 7.0
# Capacity-bucketed phrase pipeline: contexts load once; a bounded AAudio writer
# plays the current phrase while HTP prepares the next phrase.
$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$lines = [Collections.Generic.List[string]]::new()
$lines.Add("Pid=$([Environment]::ProcessId)")
$lines.Add('Job=kokoro-pipeline')
$loaded = [Collections.Generic.List[object]]::new()
$read = { param([string]$n) [IO.File]::ReadAllBytes([IO.Path]::Combine($root, $n)) }
$toF = { param([byte[]]$b) [float[]]$f = [float[]]::new($b.Length / 4); [Buffer]::BlockCopy($b, 0, $f, 0, $b.Length); ,$f }
$audioQueue = $null
$audioReady = $null
$audioState = $null
$audioPowerShell = $null
$audioRunspace = $null
$audioAsync = $null
$audioEnded = $false
try {
    $job = [scriptblock]::Create([IO.File]::ReadAllText([IO.Path]::Combine($root, 'pipeline-job.ps1'))).InvokeReturnAsIs()
    $qnn = [IO.Path]::Combine($root, 'qnn')
    $dsp = (@($qnn, '/vendor/lib/rfsa/adsp', '/vendor/dsp/cdsp', '/dsp') -join ';')
    foreach ($v in 'ADSP_LIBRARY_PATH', 'DSP_LIBRARY_PATH') { [Environment]::SetEnvironmentVariable($v, $dsp); [Android.Systems.Os]::Setenv($v, $dsp, $true) }
    foreach ($so in 'libQnnHtpV73Stub.so', 'libQnnHtp.so') { [void][Runtime.InteropServices.NativeLibrary]::Load([IO.Path]::Combine($qnn, $so)) }
    $load = { param([string]$n, [object[]]$a) [scriptblock]::Create([IO.File]::ReadAllText([IO.Path]::Combine($root, 'modules', $n))).InvokeReturnAsIs($a) }
    $abi = & $load 'Qnn.Abi.psm1' @(); $native = & $load 'Qnn.Native.psm1' @($abi); $graph = & $load 'Qnn.Graph.psm1' @($abi, $native); $ctx = & $load 'Qnn.Context.psm1' @($abi, $native, $graph)
    [void](& $native.Initialize ([pscustomobject]@{ DataRoot = $qnn; NativeLibraryDirectory = $dsp }))
    if ($native.State.DeviceCreateRc -ne 0) { throw "deviceCreate rc=$($native.State.DeviceCreateRc)" }
    $vote = & $ctx.SetPerformance 'burst'; $lines.Add("Perf=burst SetRc=$($vote.SetRc)")

    $loadTimer = [Diagnostics.Stopwatch]::StartNew()
    $bucketMap = @{}
    foreach ($bucket in $job.Buckets) {
        $frontTrial = & $ctx.LoadContext ([IO.Path]::Combine($root, $bucket.Front.Context)) $bucket.Front.GraphName
        $genTrial = & $ctx.LoadContext ([IO.Path]::Combine($root, $bucket.Gen.Context)) $bucket.Gen.GraphName
        $loaded.Add($frontTrial); $loaded.Add($genTrial)
        $bucketMap[[string]$bucket.Capacity] = [pscustomobject]@{ Definition=$bucket; FrontTrial=$frontTrial; GenTrial=$genTrial }
    }
    $lines.Add("ContextLoadMs=$($loadTimer.Elapsed.TotalMilliseconds.ToString('F1')) Buckets=$($job.Buckets.Count)")
    $pipeline = [Diagnostics.Stopwatch]::StartNew()
    $statusText = [IO.File]::ReadAllText('/proc/self/status')
    $hwmMatch = [Text.RegularExpressions.Regex]::Match($statusText, '(?m)^VmHWM:\s+(\d+)\s+kB$')
    if (-not $hwmMatch.Success) { throw 'Process high-water memory is unavailable.' }
    $lines.Add("ContextVmHwmKiB=$($hwmMatch.Groups[1].Value)")

    # A second in-process runspace owns the blocking AAudio writer. The queue is
    # deliberately bounded to one pending chunk: synthesis may overlap playback,
    # but a long passage cannot accumulate all of its PCM in unified memory.
    $audioQueue = [Collections.Concurrent.BlockingCollection[float[]]]::new(1)
    $audioReady = [Threading.ManualResetEventSlim]::new($false)
    $audioState = [Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
    $writer = {
        param([string]$Root, [object]$Queue, [object]$Ready, [object]$State, [object]$Clock)
        $stream = $null
        try {
            $loadModule = {
                param([string]$Name, [object[]]$Arguments)
                [scriptblock]::Create([IO.File]::ReadAllText([IO.Path]::Combine($Root, 'modules', $Name))).InvokeReturnAsIs($Arguments)
            }
            $writerAbi = & $loadModule 'Qnn.Abi.psm1' @()
            $writerAudio = & $loadModule 'Audio.AAudio.psm1' @($writerAbi)
            $stream = & $writerAudio.Open 24000 1
            $State['SampleRate'] = $stream.SampleRate
            $State['Channels'] = $stream.Channels
            $State['Format'] = $stream.Format
            $State['CapacityFrames'] = $stream.CapacityFrames
            $State['BurstFrames'] = $stream.FramesPerBurst
            $State['Chunks'] = 0
            $Ready.Set()
            foreach ($samples in $Queue.GetConsumingEnumerable()) {
                $written = & $writerAudio.Write $stream $samples $Clock
                if ($written -ne $samples.Length) { throw "AAudio frames=$written expected=$($samples.Length)" }
                $State['Chunks'] = [int]$State['Chunks'] + 1
            }
            $drain = & $writerAudio.Drain $stream 30000
            $State['PlaybackStartMs'] = $stream.PlaybackStartMs
            $State['FramesWritten'] = $drain.FramesWritten
            $State['FramesRead'] = $drain.FramesRead
            $State['XRunCount'] = $drain.XRunCount
            $State['Complete'] = $drain.Complete
            if (-not $drain.Complete) { throw "AAudio drain incomplete written=$($drain.FramesWritten) read=$($drain.FramesRead)" }
        }
        catch {
            $State['Error'] = $_.Exception.Message
            $Ready.Set()
            throw
        }
        finally {
            if ($null -ne $stream) {
                try { $State['CloseRc'] = & $writerAudio.Close $stream }
                catch { $State['CloseError'] = $_.Exception.Message }
            }
        }
    }
    $initialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::Create()
    $initialSessionState.LanguageMode = [System.Management.Automation.PSLanguageMode]::FullLanguage
    $audioRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($initialSessionState)
    $audioRunspace.Open()
    $audioPowerShell = [PowerShell]::Create()
    $audioPowerShell.Runspace = $audioRunspace
    [void]$audioPowerShell.AddScript($writer.ToString()).AddArgument($root).AddArgument($audioQueue).AddArgument($audioReady).AddArgument($audioState).AddArgument($pipeline)
    $audioAsync = $audioPowerShell.BeginInvoke()
    if (-not $audioReady.Wait(30000)) {
        $invokeState = $audioPowerShell.InvocationStateInfo.State
        $invokeReason = $audioPowerShell.InvocationStateInfo.Reason
        $streamError = if ($audioPowerShell.Streams.Error.Count) { $audioPowerShell.Streams.Error[0].Exception.Message } else { '' }
        throw "AAudio writer did not become ready state=$invokeState reason=$invokeReason error=$streamError"
    }
    if ($audioState.ContainsKey('Error')) { throw "AAudio writer startup failed: $($audioState['Error'])" }
    $lines.Add("AAudioReady Rate=$($audioState['SampleRate']) Channels=$($audioState['Channels']) Format=$($audioState['Format']) CapacityFrames=$($audioState['CapacityFrames']) BurstFrames=$($audioState['BurstFrames']) QueueCapacity=1")

    $runStage = {
        param([object]$Definition, [object]$Trial, [hashtable]$Bytes)
        $arena = & $graph.NewArena
        try {
            $ins = foreach ($t in $Definition.Inputs) {
                if (-not $Bytes.ContainsKey($t.Name)) { throw "missing input $($t.Name)" }
                [long]$expected = 4; foreach ($d in $t.Shape) { $expected *= $d }
                if ($Bytes[$t.Name].Length -ne $expected) { throw "input $($t.Name) bytes=$($Bytes[$t.Name].Length) expected=$expected" }
                $desc = & $ctx.BindTensor $arena $t.Id $t.Name ([int]$abi.Enum.AppWrite) ([int]$abi.Enum.Float32) $t.Shape
                & $graph.NewExecTensor $arena $desc $Bytes[$t.Name]
            }
            $o = $Definition.Output
            $od = & $ctx.BindTensor $arena $o.Id $o.Name ([int]$abi.Enum.AppRead) ([int]$abi.Enum.Float32) $o.Shape
            $eo = & $graph.NewExecTensor $arena $od ([byte[]]::new($o.Bytes))
            $timer = [Diagnostics.Stopwatch]::StartNew()
            [uint64]$rc = & $graph.Execute $Trial $arena ([object[]]@($ins)) ([object[]]@($eo))
            $ms = $timer.Elapsed.TotalMilliseconds
            if ($rc -ne 0) { throw "graphExecute rc=$rc stage=$($Definition.Name)" }
            [byte[]]$output = [byte[]]::new($o.Bytes); [Runtime.InteropServices.Marshal]::Copy($eo.DataPtr, $output, 0, $output.Length)
            [pscustomobject]@{ Bytes=$output; Ms=$ms }
        }
        finally { & $graph.FreeArena $arena }
    }

    for ($index = 0; $index -lt $job.Phrases.Count; $index++) {
        $phrase = $job.Phrases[$index]
        $bucket = $bucketMap[[string]$phrase.Capacity]
        if ($null -eq $bucket) { throw "no capacity bucket $($phrase.Capacity) for phrase $($phrase.Id)" }
        $bytes = @{}
        foreach ($entry in $phrase.Files.GetEnumerator()) { $bytes[$entry.Key] = & $read $entry.Value }
        $front = & $runStage $bucket.Definition.Front $bucket.FrontTrial $bytes
        $bytes[$bucket.Definition.Gen.Inputs[0].Name] = $front.Bytes
        $gen = & $runStage $bucket.Definition.Gen $bucket.GenTrial $bytes
        [float[]]$all = & $toF $gen.Bytes
        [int]$count = $phrase.ValidSamples
        [float[]]$pcm = [float[]]::new($count); [Array]::Copy($all, $pcm, $count)

        [float[]]$reference = & $toF (& $read $phrase.Oracle)
        if ($reference.Length -lt $count) { throw "oracle for $($phrase.Id) has $($reference.Length) samples; expected $count" }
        [double]$se=0; [double]$sr=0; [int]$bad=0
        for ($i=0; $i -lt $count; $i++) {
            if (-not [float]::IsFinite($pcm[$i])) { $bad++; continue }
            $e=[double]$pcm[$i]-$reference[$i]; $se += $e*$e; $sr += [double]$reference[$i]*$reference[$i]
            if ($pcm[$i] -lt -1.0 -or $pcm[$i] -gt 1.0) { $pcm[$i]=[float][Math]::Max(-1.0,[Math]::Min(1.0,[double]$pcm[$i])) }
        }
        $snr=10*[Math]::Log10($sr/[Math]::Max($se,1e-30))
        $readyMs=$pipeline.Elapsed.TotalMilliseconds
        if ($bad -ne 0 -or $snr -lt $job.MinSnrDb) { throw "quality gate failed for $($phrase.Id): snr=$snr nonfinite=$bad" }
        $enqueue = [Diagnostics.Stopwatch]::StartNew()
        $audioQueue.Add($pcm)
        $enqueueMs = $enqueue.Elapsed.TotalMilliseconds
        $queuedMs=$pipeline.Elapsed.TotalMilliseconds
        if ($index -eq 0) { $lines.Add("FirstAudioQueuedMs=$($queuedMs.ToString('F1'))") }
        $lines.Add("Phrase=$($phrase.Id) Capacity=$($phrase.Capacity) Samples=$count FrontMs=$($front.Ms.ToString('F1')) GenMs=$($gen.Ms.ToString('F1')) ReadyMs=$($readyMs.ToString('F1')) QueuedMs=$($queuedMs.ToString('F1')) EnqueueWaitMs=$($enqueueMs.ToString('F1')) SnrDb=$($snr.ToString('F2')) NonFinite=$bad")
    }
    $audioQueue.CompleteAdding()
    [void]$audioPowerShell.EndInvoke($audioAsync)
    $audioEnded = $true
    if ($audioPowerShell.Streams.Error.Count) { throw "AAudio writer failed: $($audioPowerShell.Streams.Error[0].Exception.Message)" }
    if ($audioState.ContainsKey('Error')) { throw "AAudio writer failed: $($audioState['Error'])" }
    if ($audioState.ContainsKey('CloseError')) { throw "AAudio close failed: $($audioState['CloseError'])" }
    $lines.Add("AAudioPlaybackStartMs=$(([double]$audioState['PlaybackStartMs']).ToString('F1')) Chunks=$($audioState['Chunks']) WrittenFrames=$($audioState['FramesWritten']) PlaybackFrames=$($audioState['FramesRead']) XRunCount=$($audioState['XRunCount']) PlaybackComplete=$($audioState['Complete']) CloseRc=$($audioState['CloseRc'])")
    if ([int]$audioState['XRunCount'] -ne 0 -or -not [bool]$audioState['Complete'] -or [int]$audioState['CloseRc'] -ne 0) { throw 'AAudio completion gate failed.' }
    $statusText = [IO.File]::ReadAllText('/proc/self/status')
    $hwmMatch = [Text.RegularExpressions.Regex]::Match($statusText, '(?m)^VmHWM:\s+(\d+)\s+kB$')
    if (-not $hwmMatch.Success) { throw 'Final process high-water memory is unavailable.' }
    $lines.Add("FinalVmHwmKiB=$($hwmMatch.Groups[1].Value) ManagedBytes=$([GC]::GetTotalMemory($false))")
    $lines.Add("PipelineMs=$($pipeline.Elapsed.TotalMilliseconds.ToString('F1')) Passed=True")
}
catch { $lines.Add('Passed=False'); $lines.Add("Error=$($_.Exception.Message)"); $lines.Add("At=$($_.InvocationInfo.PositionMessage -replace '\s+',' ')") }
finally {
    if ($null -ne $audioQueue -and -not $audioQueue.IsAddingCompleted) { try { $audioQueue.CompleteAdding() } catch {} }
    if ($null -ne $audioPowerShell -and $null -ne $audioAsync -and -not $audioEnded) { try { [void]$audioPowerShell.EndInvoke($audioAsync) } catch {} }
    if ($null -ne $audioPowerShell) { $audioPowerShell.Dispose() }
    if ($null -ne $audioRunspace) { try { $audioRunspace.Close() } catch {}; $audioRunspace.Dispose() }
    if ($null -ne $audioQueue) { $audioQueue.Dispose() }
    if ($null -ne $audioReady) { $audioReady.Dispose() }
    foreach ($trial in $loaded) { try { [void](& $native.CloseTrial $trial) } catch {} }
}
[IO.File]::WriteAllLines([IO.Path]::Combine($root, 'receipt.txt'), $lines)
[void][Android.Util.Log]::Info('KokoroPipeline', ($lines -join ' | '))
