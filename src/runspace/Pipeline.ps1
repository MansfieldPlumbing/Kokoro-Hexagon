#requires -Version 7.0
# Capacity-bucketed phrase pipeline: contexts load once; HTP prepares the next phrase while the current phrase plays.
$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$lines = [Collections.Generic.List[string]]::new()
$lines.Add("Pid=$([Environment]::ProcessId)")
$lines.Add('Job=kokoro-pipeline')
$loaded = [Collections.Generic.List[object]]::new()
$tracks = [Collections.Generic.List[object]]::new()
$read = { param([string]$n) [IO.File]::ReadAllBytes([IO.Path]::Combine($root, $n)) }
$toF = { param([byte[]]$b) [float[]]$f = [float[]]::new($b.Length / 4); [Buffer]::BlockCopy($b, 0, $f, 0, $b.Length); ,$f }
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

    $pipeline = [Diagnostics.Stopwatch]::StartNew()
    [double]$playingUntilMs = 0
    $previousTrack = $null
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
        [short[]]$s16 = [short[]]::new($count)
        for ($i=0; $i -lt $count; $i++) {
            if (-not [float]::IsFinite($pcm[$i])) { $bad++; continue }
            $e=[double]$pcm[$i]-$reference[$i]; $se += $e*$e; $sr += [double]$reference[$i]*$reference[$i]
            $v=[Math]::Max(-1.0,[Math]::Min(1.0,[double]$pcm[$i])); $s16[$i]=[short][Math]::Round($v*32767)
        }
        $snr=10*[Math]::Log10($sr/[Math]::Max($se,1e-30))
        $readyMs=$pipeline.Elapsed.TotalMilliseconds
        [double]$headroomMs = if ($index -eq 0) { 0 } else { $playingUntilMs - $readyMs }
        if ($index -gt 0 -and $headroomMs -gt 0) { [Threading.Thread]::Sleep([int][Math]::Floor($headroomMs)) }
        if ($null -ne $previousTrack) { $previousTrack.Release() }
        $track = [Android.Media.AudioTrack]::new([Android.Media.Stream]::Music,24000,[Android.Media.ChannelOut]::Mono,[Android.Media.Encoding]::Pcm16bit,2*$count,[Android.Media.AudioTrackMode]::Static)
        [void]$track.Write($s16,0,$count); $track.Play(); $tracks.Add($track); $previousTrack=$track
        $submitMs=$pipeline.Elapsed.TotalMilliseconds
        if ($index -eq 0) { $lines.Add("FirstAudioSubmitMs=$($submitMs.ToString('F1'))") }
        $playingUntilMs=$submitMs + 1000.0*$count/24000.0
        $gapMs=[Math]::Max(0.0,-$headroomMs)
        $lines.Add("Phrase=$($phrase.Id) Capacity=$($phrase.Capacity) Samples=$count FrontMs=$($front.Ms.ToString('F1')) GenMs=$($gen.Ms.ToString('F1')) ReadyMs=$($readyMs.ToString('F1')) SubmitMs=$($submitMs.ToString('F1')) HeadroomMs=$($headroomMs.ToString('F1')) GapMs=$($gapMs.ToString('F1')) SnrDb=$($snr.ToString('F2')) NonFinite=$bad")
        if ($bad -ne 0 -or $snr -lt $job.MinSnrDb) { throw "quality gate failed for $($phrase.Id): snr=$snr nonfinite=$bad" }
    }
    $remaining=$playingUntilMs-$pipeline.Elapsed.TotalMilliseconds
    if ($remaining -gt 0) { [Threading.Thread]::Sleep([int][Math]::Ceiling($remaining)+100) }
    $lines.Add("PipelineMs=$($pipeline.Elapsed.TotalMilliseconds.ToString('F1')) Passed=True")
}
catch { $lines.Add('Passed=False'); $lines.Add("Error=$($_.Exception.Message)"); $lines.Add("At=$($_.InvocationInfo.PositionMessage -replace '\s+',' ')") }
finally {
    foreach ($track in $tracks) { try { $track.Release() } catch {} }
    foreach ($trial in $loaded) { try { [void](& $native.CloseTrial $trial) } catch {} }
}
[IO.File]::WriteAllLines([IO.Path]::Combine($root, 'receipt.txt'), $lines)
[void][Android.Util.Log]::Info('KokoroPipeline', ($lines -join ' | '))
