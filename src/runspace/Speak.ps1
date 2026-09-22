#requires -Version 7.0
# Kokoro decoder on Hexagon HTP from the AndroidSMA runspace: front ctx -> generator ctx -> iSTFT (PowerShell) -> PCM -> speaker.
# Files under files/kokoro-fl: qnn/*.so, modules/*.psm1, speak-job.ps1, front.bin, gen.bin, in_*.f32, oracle_audio.f32.
$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$lines = [Collections.Generic.List[string]]::new()
$lines.Add("Pid=$([Environment]::ProcessId)")
$read = { param([string]$n) [byte[]]$b = [IO.File]::ReadAllBytes([IO.Path]::Combine($root, $n)); $b }
$toF = { param([byte[]]$b) [float[]]$f = [float[]]::new($b.Length / 4); [Buffer]::BlockCopy($b, 0, $f, 0, $b.Length); , $f }
try {
    $job = [scriptblock]::Create([IO.File]::ReadAllText([IO.Path]::Combine($root, 'speak-job.ps1'))).InvokeReturnAsIs()
    $lines.Add("Job=$($job.Name)")
    $qnn = [IO.Path]::Combine($root, 'qnn')
    $dsp = (@($qnn, '/vendor/lib/rfsa/adsp', '/vendor/dsp/cdsp', '/dsp') -join ';')
    foreach ($v in 'ADSP_LIBRARY_PATH', 'DSP_LIBRARY_PATH') { [Environment]::SetEnvironmentVariable($v, $dsp); [Android.Systems.Os]::Setenv($v, $dsp, $true) }
    foreach ($so in 'libQnnHtpV73Stub.so', 'libQnnHtp.so') { [void][Runtime.InteropServices.NativeLibrary]::Load([IO.Path]::Combine($qnn, $so)) }
    $load = { param([string]$n, [object[]]$a) [scriptblock]::Create([IO.File]::ReadAllText([IO.Path]::Combine($root, 'modules', $n))).InvokeReturnAsIs($a) }
    $abi = & $load 'Qnn.Abi.psm1' @()
    $native = & $load 'Qnn.Native.psm1' @($abi)
    $graph = & $load 'Qnn.Graph.psm1' @($abi, $native)
    $ctx = & $load 'Qnn.Context.psm1' @($abi, $native, $graph)
    [void](& $native.Initialize ([pscustomobject]@{ DataRoot = $qnn; NativeLibraryDirectory = $dsp }))
    if ($native.State.DeviceCreateRc -ne 0) { throw "deviceCreate rc=$($native.State.DeviceCreateRc)" }
    $mode = if ($null -ne $job.PerfMode) { $job.PerfMode } else { 'burst' }; $vote = & $ctx.SetPerformance $mode; $lines.Add("Perf=$($vote.Mode) PowerConfigId=$($vote.PowerConfigId) SetRc=$($vote.SetRc)")

    # One stage: bind inputs (bytes by tensor name) and one output, execute, return output bytes and time.
    $runStage = {
        param([object]$Stage, [hashtable]$Bytes)
        $trial = & $ctx.LoadContext ([IO.Path]::Combine($root, $Stage.Context)) $Stage.GraphName
        $arena = & $graph.NewArena
        try {
            $ins = foreach ($t in $Stage.Inputs) {
                if (-not $Bytes.ContainsKey($t.Name)) { throw "missing input stage=$($Stage.Name) name=$($t.Name)" }
                [long]$expected = 4; foreach ($dim in $t.Shape) { $expected *= $dim }
                if ($Bytes[$t.Name].Length -ne $expected) { throw "input byte count stage=$($Stage.Name) name=$($t.Name) actual=$($Bytes[$t.Name].Length) expected=$expected" }
                $d = & $ctx.BindTensor $arena $t.Id $t.Name ([int]$abi.Enum.AppWrite) ([int]$abi.Enum.Float32) $t.Shape
                & $graph.NewExecTensor $arena $d $Bytes[$t.Name]
            }
            $o = $Stage.Output
            $od = & $ctx.BindTensor $arena $o.Id $o.Name ([int]$abi.Enum.AppRead) ([int]$abi.Enum.Float32) $o.Shape
            $eo = & $graph.NewExecTensor $arena $od ([byte[]]::new($o.Bytes))
            $sw = [Diagnostics.Stopwatch]::StartNew()
            [uint64]$rc = & $graph.Execute $trial $arena ([object[]]@($ins)) ([object[]]@($eo))
            $ms = $sw.Elapsed.TotalMilliseconds
            if ($rc -ne 0) { throw "graphExecute rc=$rc stage=$($Stage.Name)" }
            [byte[]]$y = [byte[]]::new($o.Bytes); [Runtime.InteropServices.Marshal]::Copy($eo.DataPtr, $y, 0, $y.Length)
            [pscustomobject]@{ Bytes = $y; Ms = $ms }
        }
        finally { [void](& $native.CloseTrial $trial); & $graph.FreeArena $arena }
    }

    $bytes = @{}
    foreach ($n in $job.Files.Keys) { $bytes[$n] = & $read $job.Files[$n] }
    $total = [Diagnostics.Stopwatch]::StartNew()
    $front = & $runStage $job.Front $bytes
    $bytes[$job.Gen.Inputs[0].Name] = $front.Bytes
    $gen = & $runStage $job.Gen $bytes
    $lines.Add("FrontMs=$($front.Ms.ToString('F1')) GenMs=$($gen.Ms.ToString('F1'))")

    [int]$count = $job.ValidSamples
    if ($job.Gen.Output.Name -eq 'audio') {
        # iSTFT ran on HTP: the generator already emits the centre-cropped waveform.
        [float[]]$all = & $toF $gen.Bytes; [float[]]$pcm = [float[]]::new($count); [Array]::Copy($all, $pcm, $count)
    }
    else {
        # iSTFT (CustomSTFT.inverse): n_fft=20, hop=5, periodic Hann, conv_transpose OLA, centre crop n_fft/2.
        [float[]]$post = & $toF $gen.Bytes
        [int]$bins = 11; [int]$nfft = 20; [int]$hop = 5; [int]$frames = $job.ValidFrames; [int]$stride = $job.Gen.Output.Shape[2]
        [double[]]$w = [double[]]::new($nfft); for ($n = 0; $n -lt $nfft; $n++) { $w[$n] = (0.5 - 0.5 * [Math]::Cos(2 * [Math]::PI * $n / $nfft)) / $nfft }
        [double[]]$cs = [double[]]::new($bins * $nfft); [double[]]$sn = [double[]]::new($bins * $nfft)
        for ($k = 0; $k -lt $bins; $k++) { for ($n = 0; $n -lt $nfft; $n++) { $a = 2 * [Math]::PI * $n * $k / $nfft; $cs[$k * $nfft + $n] = [Math]::Cos($a) * $w[$n]; $sn[$k * $nfft + $n] = [Math]::Sin($a) * $w[$n] } }
        [double[]]$ola = [double[]]::new(($frames - 1) * $hop + $nfft)
        [double[]]$re = [double[]]::new($bins); [double[]]$im = [double[]]::new($bins)
        for ($f = 0; $f -lt $frames; $f++) {
            for ($k = 0; $k -lt $bins; $k++) {
                $mag = [Math]::Exp([double]$post[$k * $stride + $f]); $ph = [Math]::Sin([double]$post[($k + $bins) * $stride + $f])
                $re[$k] = $mag * [Math]::Cos($ph); $im[$k] = $mag * [Math]::Sin($ph)
            }
            [int]$base = $f * $hop
            for ($n = 0; $n -lt $nfft; $n++) {
                [double]$acc = 0
                for ($k = 0; $k -lt $bins; $k++) { $acc += $re[$k] * $cs[$k * $nfft + $n] - $im[$k] * $sn[$k * $nfft + $n] }
                $ola[$base + $n] += $acc
            }
        }
        [int]$pad = $nfft / 2; [int]$count = $job.ValidSamples
        [float[]]$pcm = [float[]]::new($count); for ($i = 0; $i -lt $count; $i++) { $pcm[$i] = [float]$ola[$i + $pad] }
    }
    $lines.Add("TotalMs=$($total.Elapsed.TotalMilliseconds.ToString('F1')) Samples=$count Seconds=$(($count / 24000.0).ToString('F2'))")

    # Compare with the PyTorch full-length waveform.
    [float[]]$ref = & $toF (& $read $job.Oracle)
    [double]$se = 0; [double]$sr = 0; [int]$bad = 0
    for ($i = 0; $i -lt $count; $i++) { if (-not [float]::IsFinite($pcm[$i])) { $bad++; continue }; $e = [double]$pcm[$i] - $ref[$i]; $se += $e * $e; $sr += [double]$ref[$i] * $ref[$i] }
    $snr = 10 * [Math]::Log10($sr / [Math]::Max($se, 1e-30))
    $lines.Add("NonFinite=$bad AudioSnrDb=$($snr.ToString('F2'))")

    # 16-bit PCM: WAV file and the phone speaker.
    [short[]]$s16 = [short[]]::new($count)
    for ($i = 0; $i -lt $count; $i++) { $v = [Math]::Max(-1.0, [Math]::Min(1.0, [double]$pcm[$i])); $s16[$i] = [short][Math]::Round($v * 32767) }
    $ms = [IO.MemoryStream]::new(); $bw = [IO.BinaryWriter]::new($ms)
    $bw.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $bw.Write([int](36 + 2 * $count)); $bw.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
    $bw.Write([int]16); $bw.Write([short]1); $bw.Write([short]1); $bw.Write([int]24000); $bw.Write([int]48000); $bw.Write([short]2); $bw.Write([short]16)
    $bw.Write([Text.Encoding]::ASCII.GetBytes('data')); $bw.Write([int](2 * $count)); foreach ($x in $s16) { $bw.Write($x) }; $bw.Flush()
    [IO.File]::WriteAllBytes([IO.Path]::Combine($root, 'kokoro_htp.wav'), $ms.ToArray())
    $track = [Android.Media.AudioTrack]::new([Android.Media.Stream]::Music, 24000, [Android.Media.ChannelOut]::Mono, [Android.Media.Encoding]::Pcm16bit, 2 * $count, [Android.Media.AudioTrackMode]::Static)
    try {
        [int]$written = $track.Write($s16, 0, $count)
        if ($written -ne $count) { throw "AudioTrack.Write frames=$written expected=$count" }
        $track.Play()
        [Threading.Thread]::Sleep([int](1000 * $count / 24000) + 300)
        [uint32]$playedFrames = $track.PlaybackHeadPosition
        $playbackComplete = $playedFrames -ge [uint32]$count
        $lines.Add("PlayState=$($track.PlayState) WrittenFrames=$written PlaybackFrames=$playedFrames PlaybackComplete=$playbackComplete")
    }
    finally { $track.Release() }

    # Repeated warm timing: context loaded and tensors bound once, one warm-up, then N timed executes.
    $benchStage = {
        param([object]$Stage, [hashtable]$Bytes, [int]$N)
        $trial = & $ctx.LoadContext ([IO.Path]::Combine($root, $Stage.Context)) $Stage.GraphName
        $arena = & $graph.NewArena
        try {
            $ins = foreach ($t in $Stage.Inputs) {
                if (-not $Bytes.ContainsKey($t.Name)) { throw "missing input bench=$($Stage.Name) name=$($t.Name)" }
                [long]$expected = 4; foreach ($dim in $t.Shape) { $expected *= $dim }
                if ($Bytes[$t.Name].Length -ne $expected) { throw "input byte count bench=$($Stage.Name) name=$($t.Name) actual=$($Bytes[$t.Name].Length) expected=$expected" }
                $d = & $ctx.BindTensor $arena $t.Id $t.Name ([int]$abi.Enum.AppWrite) ([int]$abi.Enum.Float32) $t.Shape
                & $graph.NewExecTensor $arena $d $Bytes[$t.Name]
            }
            $o = $Stage.Output
            $od = & $ctx.BindTensor $arena $o.Id $o.Name ([int]$abi.Enum.AppRead) ([int]$abi.Enum.Float32) $o.Shape
            $eo = & $graph.NewExecTensor $arena $od ([byte[]]::new($o.Bytes))
            [uint64]$warmRc = & $graph.Execute $trial $arena ([object[]]@($ins)) ([object[]]@($eo))
            if ($warmRc -ne 0) { throw "graphExecute rc=$warmRc warmup=$($Stage.Name)" }
            [double[]]$ms = [double[]]::new($N)
            for ($i = 0; $i -lt $N; $i++) {
                $sw = [Diagnostics.Stopwatch]::StartNew()
                [uint64]$rc = & $graph.Execute $trial $arena ([object[]]@($ins)) ([object[]]@($eo))
                $ms[$i] = $sw.Elapsed.TotalMilliseconds
                if ($rc -ne 0) { throw "graphExecute rc=$rc bench=$($Stage.Name)" }
            }
            [Array]::Sort($ms)
            [double]$sum = 0; foreach ($v in $ms) { $sum += $v }
            [pscustomobject]@{ N = $N; Mean = $sum / $N; P50 = $ms[[int][Math]::Floor(0.50 * ($N - 1))]; P95 = $ms[[int][Math]::Floor(0.95 * ($N - 1))]; Max = $ms[$N - 1]; Min = $ms[0] }
        }
        finally { [void](& $native.CloseTrial $trial); & $graph.FreeArena $arena }
    }
    if ($job.Repeat -gt 0) {
        foreach ($pair in @(@('Front', $job.Front), @('Gen', $job.Gen))) {
            $b = & $benchStage $pair[1] $bytes ([int]$job.Repeat)
            $lines.Add(('Bench{0} N={1} MeanMs={2:F1} P50Ms={3:F1} P95Ms={4:F1} MinMs={5:F1} MaxMs={6:F1}' -f $pair[0], $b.N, $b.Mean, $b.P50, $b.P95, $b.Min, $b.Max))
        }
    }
    $lines.Add("Passed=$($bad -eq 0 -and $snr -ge $job.MinSnrDb -and $playbackComplete)")
}
catch { $lines.Add('Passed=False'); $lines.Add("Error=$($_.Exception.Message)"); $lines.Add("At=$($_.InvocationInfo.PositionMessage -replace '\s+', ' ')") }
[IO.File]::WriteAllLines([IO.Path]::Combine($root, 'receipt.txt'), $lines)
[void][Android.Util.Log]::Info('KokoroSpeak', ($lines -join ' | '))
