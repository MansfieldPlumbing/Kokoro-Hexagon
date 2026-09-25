param(
    [Parameter(Mandatory)]
    [object]$NativeBinding
)

# Blocking AAudio output for the persistent PowerShell runspace. The signatures
# and constants are pinned to AOSP frameworks/av commit
# 9e7dd63dfff0cc967f025ea9e27a299aaa99fd69, AAudio.h blob
# 25ad5f8ef976c33b8670e4217d3f984c13096829 (API level 26 surface).
$lib = [Runtime.InteropServices.NativeLibrary]::Load('libaaudio.so')
$delegates = [Collections.Generic.Dictionary[string, object]]::new()

$bind = {
    param([string]$Name, [Type]$ReturnType, [Type[]]$ParameterTypes)
    if ($delegates.ContainsKey($Name)) { return $delegates[$Name] }
    $call = & $NativeBinding.BindExport $lib $Name $ReturnType $ParameterTypes
    $delegates.Add($Name, $call)
    $call
}.GetNewClosure()

$i32 = [int]; $i64 = [long]; $ptr = [IntPtr]; $void = [void]
$fn = [pscustomobject]@{
    CreateBuilder = & $bind 'AAudio_createStreamBuilder' $i32 ([Type[]]@($ptr))
    SetSampleRate = & $bind 'AAudioStreamBuilder_setSampleRate' $void ([Type[]]@($ptr, $i32))
    SetChannels = & $bind 'AAudioStreamBuilder_setSamplesPerFrame' $void ([Type[]]@($ptr, $i32))
    SetFormat = & $bind 'AAudioStreamBuilder_setFormat' $void ([Type[]]@($ptr, $i32))
    SetPerformance = & $bind 'AAudioStreamBuilder_setPerformanceMode' $void ([Type[]]@($ptr, $i32))
    OpenStream = & $bind 'AAudioStreamBuilder_openStream' $i32 ([Type[]]@($ptr, $ptr))
    DeleteBuilder = & $bind 'AAudioStreamBuilder_delete' $i32 ([Type[]]@($ptr))
    RequestStart = & $bind 'AAudioStream_requestStart' $i32 ([Type[]]@($ptr))
    RequestStop = & $bind 'AAudioStream_requestStop' $i32 ([Type[]]@($ptr))
    Write = & $bind 'AAudioStream_write' $i32 ([Type[]]@($ptr, $ptr, $i32, $i64))
    Close = & $bind 'AAudioStream_close' $i32 ([Type[]]@($ptr))
    GetRate = & $bind 'AAudioStream_getSampleRate' $i32 ([Type[]]@($ptr))
    GetChannels = & $bind 'AAudioStream_getSamplesPerFrame' $i32 ([Type[]]@($ptr))
    GetFormat = & $bind 'AAudioStream_getFormat' $i32 ([Type[]]@($ptr))
    GetCapacity = & $bind 'AAudioStream_getBufferCapacityInFrames' $i32 ([Type[]]@($ptr))
    GetBurst = & $bind 'AAudioStream_getFramesPerBurst' $i32 ([Type[]]@($ptr))
    GetFramesRead = & $bind 'AAudioStream_getFramesRead' $i64 ([Type[]]@($ptr))
    GetXRun = & $bind 'AAudioStream_getXRunCount' $i32 ([Type[]]@($ptr))
}

$open = {
    param([int]$SampleRate = 24000, [int]$Channels = 1)
    if ($SampleRate -lt 8000 -or $SampleRate -gt 192000) { throw 'AAudio sample rate is outside the accepted range.' }
    if ($Channels -ne 1) { throw 'The Kokoro AAudio path currently accepts mono only.' }

    $builderOut = [Runtime.InteropServices.Marshal]::AllocHGlobal([IntPtr]::Size)
    $streamOut = [Runtime.InteropServices.Marshal]::AllocHGlobal([IntPtr]::Size)
    [Runtime.InteropServices.Marshal]::WriteIntPtr($builderOut, [IntPtr]::Zero)
    [Runtime.InteropServices.Marshal]::WriteIntPtr($streamOut, [IntPtr]::Zero)
    $builder = [IntPtr]::Zero
    $stream = [IntPtr]::Zero
    try {
        $rc = $fn.CreateBuilder.Invoke($builderOut)
        if ($rc -ne 0) { throw "AAudio_createStreamBuilder rc=$rc" }
        $builder = [Runtime.InteropServices.Marshal]::ReadIntPtr($builderOut)
        if ($builder -eq [IntPtr]::Zero) { throw 'AAudio returned a null stream builder.' }

        $fn.SetSampleRate.Invoke($builder, $SampleRate)
        $fn.SetChannels.Invoke($builder, $Channels)
        $fn.SetFormat.Invoke($builder, 2)       # AAUDIO_FORMAT_PCM_FLOAT
        $fn.SetPerformance.Invoke($builder, 12) # AAUDIO_PERFORMANCE_MODE_LOW_LATENCY
        $rc = $fn.OpenStream.Invoke($builder, $streamOut)
        if ($rc -ne 0) { throw "AAudioStreamBuilder_openStream rc=$rc" }
        $stream = [Runtime.InteropServices.Marshal]::ReadIntPtr($streamOut)
        if ($stream -eq [IntPtr]::Zero) { throw 'AAudio returned a null stream.' }

        $actualRate = $fn.GetRate.Invoke($stream)
        $actualChannels = $fn.GetChannels.Invoke($stream)
        $actualFormat = $fn.GetFormat.Invoke($stream)
        if ($actualRate -ne $SampleRate -or $actualChannels -ne $Channels -or $actualFormat -ne 2) {
            [void]$fn.Close.Invoke($stream)
            $stream = [IntPtr]::Zero
            throw "AAudio format mismatch rate=$actualRate channels=$actualChannels format=$actualFormat"
        }
        [pscustomobject]@{
            Stream = $stream
            SampleRate = $actualRate
            Channels = $actualChannels
            Format = $actualFormat
            CapacityFrames = $fn.GetCapacity.Invoke($stream)
            FramesPerBurst = $fn.GetBurst.Invoke($stream)
            Started = $false
            PlaybackStartMs = [double]::NaN
            FramesWritten = [long]0
            Closed = $false
        }
    }
    catch {
        if ($stream -ne [IntPtr]::Zero) { [void]$fn.Close.Invoke($stream) }
        throw
    }
    finally {
        if ($builder -ne [IntPtr]::Zero) { [void]$fn.DeleteBuilder.Invoke($builder) }
        [Runtime.InteropServices.Marshal]::FreeHGlobal($builderOut)
        [Runtime.InteropServices.Marshal]::FreeHGlobal($streamOut)
    }
}.GetNewClosure()

$write = {
    param([object]$State, [float[]]$Samples, [object]$Clock)
    if ($State.Closed -or $State.Stream -eq [IntPtr]::Zero) { throw 'AAudio stream is closed.' }
    if (-not $Samples -or $Samples.Length -eq 0) { throw 'AAudio write requires at least one frame.' }
    if (($Samples.Length % $State.Channels) -ne 0) { throw 'AAudio sample count is not frame aligned.' }

    $handle = [Runtime.InteropServices.GCHandle]::Alloc($Samples, [Runtime.InteropServices.GCHandleType]::Pinned)
    try {
        [int]$frames = $Samples.Length / $State.Channels
        [int]$offset = 0
        if (-not $State.Started) {
            [int]$primeRequest = [Math]::Min($frames, [Math]::Max(1, $State.CapacityFrames))
            $prime = $fn.Write.Invoke($State.Stream, $handle.AddrOfPinnedObject(), $primeRequest, [long]0)
            if ($prime -lt 0) { throw "AAudioStream_write prime rc=$prime" }
            $offset = $prime
            $rc = $fn.RequestStart.Invoke($State.Stream)
            if ($rc -ne 0) { throw "AAudioStream_requestStart rc=$rc" }
            $State.Started = $true
            if ($Clock) { $State.PlaybackStartMs = $Clock.Elapsed.TotalMilliseconds }
        }

        while ($offset -lt $frames) {
            $address = [IntPtr]::Add($handle.AddrOfPinnedObject(), 4 * $offset * $State.Channels)
            $written = $fn.Write.Invoke($State.Stream, $address, $frames - $offset, [long]1000000000)
            if ($written -lt 0) { throw "AAudioStream_write rc=$written" }
            if ($written -eq 0) { throw 'AAudioStream_write made no progress.' }
            $offset += $written
        }
        $State.FramesWritten += $frames
        $frames
    }
    finally { $handle.Free() }
}.GetNewClosure()

$drain = {
    param([object]$State, [int]$TimeoutMs = 10000)
    if ($State.Closed) { throw 'AAudio stream is closed.' }
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($fn.GetFramesRead.Invoke($State.Stream) -lt $State.FramesWritten -and $deadline.ElapsedMilliseconds -lt $TimeoutMs) {
        [Threading.Thread]::Sleep(5)
    }
    $read = $fn.GetFramesRead.Invoke($State.Stream)
    [pscustomobject]@{
        Complete = $read -ge $State.FramesWritten
        FramesWritten = $State.FramesWritten
        FramesRead = $read
        XRunCount = $fn.GetXRun.Invoke($State.Stream)
        WaitMs = $deadline.Elapsed.TotalMilliseconds
    }
}.GetNewClosure()

$close = {
    param([object]$State)
    if ($State.Closed) { return 0 }
    $stopRc = if ($State.Started) { $fn.RequestStop.Invoke($State.Stream) } else { 0 }
    $closeRc = $fn.Close.Invoke($State.Stream)
    $State.Stream = [IntPtr]::Zero
    $State.Closed = $true
    if ($stopRc -ne 0) { return $stopRc }
    $closeRc
}.GetNewClosure()

[pscustomobject]@{
    PSTypeName = 'Kokoro.Audio.AAudio'
    Open = $open
    Write = $write
    Drain = $drain
    Close = $close
}
