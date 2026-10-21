#requires -Version 7.0
# Device harness for the emitted generator tail job (src/jobs/Kokoro.GeneratorTailRun.ps1).
# One unsigned-PD session, one handle; Runs invocations of method 2 (sc 0x02040100). Run 0's
# whole output buffer is saved for host verification; every run's PCM must be identical.
# The PCM is then played once through AAudio at 24 kHz mono.
$activityHost = Get-Variable -Name Activity -ValueOnly -ErrorAction Ignore
$hostFiles = if ($null -ne $activityHost) { $activityHost.FilesDir.AbsolutePath } else { $PSScriptRoot }
$root = [IO.Path]::Combine($hostFiles, 'kokoro')
$dir = [IO.Path]::Combine($root, 'generator-tail')
$receipt = [IO.Path]::Combine($dir, 'receipt.txt')
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('Job=kokoro-generator-tail')
$inv = [Globalization.CultureInfo]::InvariantCulture
# Written before any loading: an empty receipt means initialization did not reach this point.
[IO.File]::WriteAllLines($receipt, @('Job=kokoro-generator-tail', "Started=$([DateTime]::UtcNow.ToString('o', $inv))"))
function Write-KokoroProbeStage {
    param([string] $Stage)
    [IO.File]::AppendAllText($receipt, "ProbeStage=$Stage`n")
}
$Marshal = [Runtime.InteropServices.Marshal]; $native = [IntPtr]::Zero; $opened = $false; $handle = [uint64]0
$pins = [Collections.Generic.List[object]]::new(); $allocations = [Collections.Generic.List[object]]::new()
$passed = $false; $stream = $null; $audio = $null
$sharedPayloads = [Collections.Generic.List[object]]::new()
$mappedWeights = $null
try {
    $kv = @{}; foreach ($l in [IO.File]::ReadAllLines([IO.Path]::Combine($dir, 'spec.txt'))) { $p = $l.Split('=', 2); if ($p.Count -eq 2) { $kv[$p[0]] = $p[1] } }
    $tiles = [int]$kv.Tiles; $runs = [int]$kv.Runs; $outputBytes = [int]$kv.OutputBytes; $pcmOffset = [int]$kv.PcmOffset; $samples = [int]$kv.Samples
    # Serve=True: the resident job listener below instead of one job; each request carries its own job fields.
    $serve = $kv.ContainsKey('Serve')
    if (-not $serve -and ($tiles -lt 1 -or $tiles -gt 1024 -or $runs -lt 1 -or $runs -gt 121 -or $samples -lt 1 -or $pcmOffset + 2 * $samples -gt $outputBytes)) { throw 'Spec out of range' }
    $lines.Add("Tiles=$tiles Runs=$runs Samples=$samples")
    $load = { param([string]$Name, [object[]]$Arguments)
        $ast = [Management.Automation.Language.Parser]::ParseFile([IO.Path]::Combine($root, $Name), [ref]$null, [ref]$null)
        $ast.GetScriptBlock().InvokeReturnAsIs($Arguments) }
    Write-KokoroProbeStage 'BindingsBegin'
    $abi = & $load 'Native.Binding.psm1' @()
    Write-KokoroProbeStage 'BindingsReady'
    $so = [IO.Path]::Combine($root, 'dsp', 'libkokoro_generator_tail_skel.so')
    $lines.Add('LibrarySHA256=' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($so))))
    $search = [IO.Path]::Combine($root, 'dsp') + ';/vendor/lib/rfsa/adsp;/vendor/dsp/cdsp;/dsp'
    # Bionic stdlib.h: int setenv(const char*, const char*, int). UTF-8 buffers
    # live through each call; the native binding also works in the NativeActivity host.
    # https://android.googlesource.com/platform/bionic/+/3a5441c3474f2f4f5893504293aa33746f8847cb/libc/include/stdlib.h
    Write-KokoroProbeStage 'SearchPathBegin'
    $libc = [Runtime.InteropServices.NativeLibrary]::Load('libc.so')
    $valuePtr = [IntPtr]::Zero
    try {
        $setenv = & $abi.BindExport $libc 'setenv' ([int]) ([Type[]]@([IntPtr], [IntPtr], [int]))
        Write-KokoroProbeStage 'SetenvBound'
        $valuePtr = $Marshal::StringToCoTaskMemUTF8($search)
        foreach ($name in 'ADSP_LIBRARY_PATH', 'DSP_LIBRARY_PATH') {
            [Environment]::SetEnvironmentVariable($name, $search)
            $namePtr = $Marshal::StringToCoTaskMemUTF8($name)
            try {
                if ($setenv.Invoke($namePtr, $valuePtr, 1) -ne 0) { throw 'DSP search path configuration failed' }
            }
            finally { $Marshal::FreeCoTaskMem($namePtr) }
        }
    }
    finally {
        if ($valuePtr -ne [IntPtr]::Zero) { $Marshal::FreeCoTaskMem($valuePtr) }
        [Runtime.InteropServices.NativeLibrary]::Free($libc)
    }
    Write-KokoroProbeStage 'SearchPathReady'
    $native = [Runtime.InteropServices.NativeLibrary]::Load('libcdsprpc.so')
    Write-KokoroProbeStage 'RpcLibraryReady'
    $fn = { param($Name, $ReturnType, $Parameters)
        $Marshal::GetDelegateForFunctionPointer([Runtime.InteropServices.NativeLibrary]::GetExport($native, $Name), (& $abi.NewDelegateType ('GeneratorTail_' + $Name) $ReturnType $Parameters)) }
    $control = & $fn 'remote_session_control' ([int]) ([Type[]]@([uint32], [IntPtr], [uint32]))
    $open    = & $fn 'remote_handle64_open'    ([int]) ([Type[]]@([IntPtr], ([uint64]).MakeByRefType()))
    $invoke  = & $fn 'remote_handle64_invoke'  ([int]) ([Type[]]@([uint64], [uint32], [IntPtr]))
    $close   = & $fn 'remote_handle64_close'   ([int]) ([Type[]]@([uint64]))
    $pin = { param([byte[]]$Bytes) $g = [Runtime.InteropServices.GCHandle]::Alloc($Bytes, [Runtime.InteropServices.GCHandleType]::Pinned); $pins.Add($g); $g.AddrOfPinnedObject() }
    $cfg = $Marshal::AllocHGlobal(8); $allocations.Add($cfg)
    $Marshal::WriteInt32($cfg, 0, 3); $Marshal::WriteInt32($cfg, 4, 1)
    Write-KokoroProbeStage 'SessionControlBegin'
    $rc = [int]$control.DynamicInvoke([object[]]@([uint32]2, $cfg, [uint32]8))
    $lines.Add("UnsignedPdRc=$rc"); if ($rc -ne 0) { throw 'Unsigned PD configuration failed' }
    $uri = [Text.Encoding]::UTF8.GetBytes('file:///libkokoro_generator_tail_skel.so?kokoro_generator_tail_skel_handle_invoke&_modver=1.0&_dom=cdsp' + [char]0)
    $oa = [object[]]@((& $pin $uri), [uint64]0)
    $rc = [int]$open.DynamicInvoke($oa)
    $lines.Add("OpenRc=$rc"); if ($rc -ne 0) { throw 'Kernel library open failed' }
    $handle = [uint64]$oa[1]; $opened = $true

    if ($serve) {
        # Resident job listener: this session and handle stay open; requests arrive on the abstract socket kokoro-jobs.
        # Frames: int32 header length, UTF-8 JSON header, then the header's blobs. Inputs are cached by SHA-256, so
        # unchanged weights, tables and skel never cross again. A random token in app-private storage must open every
        # request: any process on the phone can reach an abstract socket, and only the app and run-as can read the token.
        $token = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
        $tokenPath = [IO.Path]::Combine($dir, 'listener-token.txt')
        [IO.File]::WriteAllText($tokenPath, $token)
        $skelHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($so)))
        $cache = [Collections.Generic.Dictionary[string,byte[]]]::new([StringComparer]::Ordinal)
        $listener = [Net.Sockets.Socket]::new([Net.Sockets.AddressFamily]::Unix, [Net.Sockets.SocketType]::Stream, [Net.Sockets.ProtocolType]::Unspecified)
        $respond = { param($Writer, [hashtable]$Header, [byte[]]$Payload)
            $headerBytes = [Text.Encoding]::UTF8.GetBytes(($Header | ConvertTo-Json -Compress -Depth 4))
            $Writer.Write([int]$headerBytes.Length); $Writer.Write($headerBytes); if ($null -ne $Payload) { $Writer.Write($Payload) }; $Writer.Flush() }
        try {
            $listener.Bind([Net.Sockets.UnixDomainSocketEndPoint]::new([string][char]0 + 'kokoro-jobs')); $listener.Listen(1)
            $lines.Add('Listening=kokoro-jobs'); [IO.File]::WriteAllLines($receipt, $lines)
            $serving = $true; $jobs = 0
            while ($serving) {
                $client = $listener.Accept()
                $network = [Net.Sockets.NetworkStream]::new($client, $true)
                $reader = [IO.BinaryReader]::new($network); $writer = [IO.BinaryWriter]::new($network)
                try {
                    while ($serving) {
                        # Wait for this client's next request or a new connection. A new connection replaces an idle
                        # one, so a client that went away without closing can never block the listener.
                        $ready = [Collections.Generic.List[Net.Sockets.Socket]]::new(); $ready.Add($client); $ready.Add($listener)
                        [Net.Sockets.Socket]::Select($ready, $null, $null, -1)
                        if ($ready.Contains($listener)) { break }
                        $length = $reader.ReadInt32()
                        if ($length -lt 2 -or $length -gt 1048576) { throw 'Request header length out of range.' }
                        $request = [Text.Encoding]::UTF8.GetString($reader.ReadBytes($length)) | ConvertFrom-Json -AsHashtable
                        if ([string]$request.Token -cne $token) { & $respond $writer @{ Ok = $false; Error = 'Token mismatch.' } $null; break }
                        foreach ($blob in @($request.Blobs)) {
                            $bytes = $reader.ReadBytes([int]$blob.Bytes)
                            if ($bytes.Length -ne [int]$blob.Bytes -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -cne [string]$blob.Sha256) { throw 'Request blob integrity mismatch.' }
                            $cache[[string]$blob.Sha256] = $bytes
                        }
                        if ($request.Op -ceq 'stop') { & $respond $writer @{ Ok = $true; Jobs = $jobs } $null; $serving = $false; break }
                        if ($request.Op -ceq 'ping') { & $respond $writer @{ Ok = $true; Jobs = $jobs; Skel = $skelHash; Held = @($cache.Keys) } $null; continue }
                        if ($request.Op -cne 'job') { & $respond $writer @{ Ok = $false; Error = 'Unknown operation.' } $null; continue }
                        $keys = @([string]$request.Skel, [string]$request.Activations, [string]$request.Weights, [string]$request.Tables)
                        $missing = @($keys | Where-Object { -not $cache.ContainsKey($_) })
                        if ($missing.Count) { & $respond $writer @{ Ok = $false; Missing = $missing } $null; continue }
                        if ($keys[0] -cne $skelHash) {
                            # A different kernel: close the handle, replace the skel and open it again.
                            if ($opened) { $null = $close.DynamicInvoke([object[]]@($handle)); $opened = $false }
                            [IO.File]::WriteAllBytes($so, $cache[$keys[0]])
                            $oa = [object[]]@((& $pin $uri), [uint64]0); $rc = [int]$open.DynamicInvoke($oa)
                            if ($rc -ne 0) { throw "Kernel library open failed: $rc" }
                            $handle = [uint64]$oa[1]; $opened = $true; $skelHash = $keys[0]
                        }
                        $jobTiles = [int]$request.Tiles; $jobRuns = [int]$request.Runs; $jobOutputBytes = [int]$request.OutputBytes; $jobPcmOffset = [int]$request.PcmOffset; $jobSamples = [int]$request.Samples
                        $act = $cache[$keys[1]]; $wts = $cache[$keys[2]]; $tbl = $cache[$keys[3]]
                        if ($jobTiles -lt 1 -or $jobTiles -gt 1024 -or $jobRuns -lt 1 -or $jobRuns -gt 121 -or $jobSamples -lt 1 -or $jobPcmOffset + 2 * $jobSamples -gt $jobOutputBytes -or $act.Length -ne [long]$request.InputBytes) { throw 'Job fields out of range.' }
                        $out = [byte[]]::new($jobOutputBytes)
                        $bufs = @(([BitConverter]::GetBytes([uint32]$jobTiles)), $act, $wts, $tbl, $out)
                        $jobPins = [Collections.Generic.List[object]]::new(); $jobBlock = $Marshal::AllocHGlobal(16 * $bufs.Count)
                        $jobLines = [Collections.Generic.List[string]]::new(); $jobTicks = [Collections.Generic.List[long]]::new(); $jobOk = $true; $firstHash = $null; $firstOutput = $null
                        try {
                            for ($i = 0; $i -lt $bufs.Count; $i++) {
                                $g = [Runtime.InteropServices.GCHandle]::Alloc($bufs[$i], [Runtime.InteropServices.GCHandleType]::Pinned); $jobPins.Add($g)
                                $Marshal::WriteIntPtr($jobBlock, 16 * $i, $g.AddrOfPinnedObject()); $Marshal::WriteInt64($jobBlock, 16 * $i + 8, [long]$bufs[$i].Length)
                            }
                            for ($run = 0; $run -lt $jobRuns; $run++) {
                                $sw = [Diagnostics.Stopwatch]::StartNew()
                                $rc = [int]$invoke.DynamicInvoke([object[]]@($handle, [uint32]0x02040100, $jobBlock))
                                $sw.Stop()
                                $stage = [BitConverter]::ToInt32($out, 36); $done = [BitConverter]::ToInt32($out, 44)
                                $dt = [long]([BitConverter]::ToUInt64($out, 8) - [BitConverter]::ToUInt64($out, 0))
                                $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$out[$jobPcmOffset..($jobPcmOffset + 2 * $jobSamples - 1)]))
                                if ($run -eq 0) { $firstHash = $hash; $firstOutput = [byte[]]$out.Clone() }
                                if ($rc -ne 0 -or $stage -ne 7 -or $done -ne 1 -or $hash -ne $firstHash) { $jobOk = $false }
                                if ($rc -eq 0 -and $done -eq 1) { $jobTicks.Add($dt) }
                                $jobLines.Add("Run=$run InvokeRc=$rc Stage=$stage Done=$done RegionTicks=$dt InvokeMs=$($sw.Elapsed.TotalMilliseconds.ToString('F3', $inv)) PcmSHA256=$hash")
                                if ($rc -ne 0) { break }
                            }
                        }
                        finally { foreach ($g in $jobPins) { $g.Free() }; $Marshal::FreeHGlobal($jobBlock) }
                        $medianMs = $null
                        if ($jobTicks.Count) { $sorted = $jobTicks.ToArray(); [Array]::Sort($sorted); $medianMs = $sorted[[int][math]::Floor($sorted.Count / 2)] / 19200.0 }
                        $jobs++
                        # Only the requested ranges of run 0's buffer cross back, concatenated in request order.
                        $ranges = @(foreach ($range in @($request.Ranges)) { ,([long[]]@($range[0], $range[1])) })
                        $returned = [IO.MemoryStream]::new()
                        foreach ($range in $ranges) {
                            if ($range[0] -lt 0 -or $range[1] -lt 0 -or $range[0] + $range[1] -gt $firstOutput.Length) { throw 'Output range out of bounds.' }
                            $returned.Write($firstOutput, [int]$range[0], [int]$range[1])
                        }
                        $payload = $returned.ToArray()
                        & $respond $writer @{ Ok = $jobOk; Lines = $jobLines.ToArray(); MedianRegionMs = $medianMs; OutputBytes = $payload.Length; BufferBytes = $firstOutput.Length
                            OutputSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($payload)) } $payload
                        # Keep this job's skel, weights and tables; activations change with every job.
                        foreach ($key in @($cache.Keys)) { if ($key -cne $keys[0] -and $key -cne $keys[2] -and $key -cne $keys[3]) { [void]$cache.Remove($key) } }
                    }
                }
                catch [IO.EndOfStreamException] { }
                catch { try { & $respond $writer @{ Ok = $false; Error = $_.Exception.Message } $null } catch { } }
                finally { $client.Dispose() }
            }
            $lines.Add("Served=$jobs")
        }
        finally { $listener.Dispose(); if ([IO.File]::Exists($tokenPath)) { [IO.File]::Delete($tokenPath) } }
        $passed = $true
    }
    if (-not $serve) {
    $act = [IO.File]::ReadAllBytes([IO.Path]::Combine($dir, 'activations.bin'))
    if ($kv.ContainsKey('WeightAssembly')) {
        if (-not $kv.ContainsKey('ResidentPayloads')) { throw 'Mapped weight assembly requires resident payload transport.' }
        $weightLoader = [Reflection.Assembly]::LoadFile([IO.Path]::Combine($dir, 'Kokoro.MappedPayload.dll'))
        $weightType = $weightLoader.GetType('KokoroMappedPayload', $true)
        $weightIdentity = [Guid]$kv.WeightIdentity
        $mapClock = [Diagnostics.Stopwatch]::StartNew()
        $mappedWeights = $weightType::new([IO.Path]::Combine($dir, 'Kokoro.Generator.Weights.dll'), [long]$kv.WeightOffset, [long]$kv.WeightBytes, [long]$kv.WeightAssemblyBytes, [long]$kv.WeightIdentityOffset, ($weightIdentity.ToByteArray()))
        $mapClock.Stop()
        $weightBytes = [int]$mappedWeights.Bytes
        $wts = $null
        $lines.Add("WeightAssembly=True LaunchMapMs=$($mapClock.Elapsed.TotalMilliseconds.ToString('F3',$inv)) LaunchHashPasses=0")
    } else {
        $wts = [IO.File]::ReadAllBytes([IO.Path]::Combine($dir, 'weights.bin'))
        $weightBytes = $wts.Length
    }
    $tbl = [IO.File]::ReadAllBytes([IO.Path]::Combine($dir, 'tables.bin'))
    $inputBytes = if ($kv.InputBytes) { [long]$kv.InputBytes } else { $tiles * 8192L }
    if ($act.Length -ne $inputBytes) { throw 'Input length' }
    $config = [BitConverter]::GetBytes([uint32]$tiles)
    $resident = $kv.ContainsKey('ResidentPayloads')
    $mappingMs = 0.0
    if ($resident) {
        $mappingClock = [Diagnostics.Stopwatch]::StartNew()
        $sharedWeights = if ($null -ne $mappedWeights) { & $abi.NewSharedPayload $native $null ($mappedWeights.GetPointer()) $weightBytes } else { & $abi.NewSharedPayload $native $wts }
        $sharedPayloads.Add($sharedWeights)
        $sharedTables = & $abi.NewSharedPayload $native $tbl; $sharedPayloads.Add($sharedTables)
        $config = [byte[]]::new(20)
        $fields = [uint32[]]@($tiles,$sharedWeights.RemoteAddress,$weightBytes,$sharedTables.RemoteAddress,$tbl.Length)
        [Buffer]::BlockCopy($fields,0,$config,0,20)
        $mappingClock.Stop(); $mappingMs = $mappingClock.Elapsed.TotalMilliseconds
        $lines.Add("ResidentPayloads=True MappingMs=$($mappingMs.ToString('F3',$inv)) WeightsBytes=$weightBytes TablesBytes=$($tbl.Length) Allocation=RpcmemSystemUncached Mapping=RemoteMemMapStatic OncePerSession=True")
    }
    $ticks = [Collections.Generic.List[long]]::new(); $pcmHash = $null; $allOk = $true; $pcm = $null
    $requestLifetime = $kv.ContainsKey('RequestLifetime')
    $requestClock = [Diagnostics.Stopwatch]::StartNew()
    $requestProcess = [Environment]::ProcessId
    $requestThread = [Environment]::CurrentManagedThreadId
    $requestFloats = $null
    if ($requestLifetime) { $lines.Add('RequestLifetime=True ProcessCount=1 FastRpcOpenCount=1 PayloadMapCount=2 Warmups=1 Requests=30') }
    for ($run = 0; $run -lt $runs; $run++) {
        $idleSeconds = if ($requestLifetime -and $run -gt 0) { @(0,1,5)[($run-1)%3] } else { 0 }
        if ($idleSeconds) { [Threading.Thread]::Sleep(1000*$idleSeconds) }
        if ([Environment]::ProcessId -ne $requestProcess -or [Environment]::CurrentManagedThreadId -ne $requestThread) { throw 'Measurement process or runspace thread changed.' }
        if ($requestLifetime) { $lines.Add("Request=$run GapSeconds=$idleSeconds ElapsedMs=$($requestClock.Elapsed.TotalMilliseconds.ToString('F3',$inv)) SameProcess=True SameSession=True") }
        $phaseClock = [Diagnostics.Stopwatch]::StartNew()
        $setupEntry = $phaseClock.ElapsedTicks
        if (-not $requestLifetime -or $run -eq 0) {
            $out = [byte[]]::new($outputBytes)
            $bufs = if ($resident) { @($config,$act,$out) } else { @($config, $act, $wts, $tbl, $out) }
            $argBlock = $Marshal::AllocHGlobal(16 * $bufs.Count); $allocations.Add($argBlock)
            for ($i = 0; $i -lt $bufs.Count; $i++) { $Marshal::WriteIntPtr($argBlock, 16 * $i, (& $pin $bufs[$i])); $Marshal::WriteInt64($argBlock, 16 * $i + 8, [long]$bufs[$i].Length) }
        }
        $scalars = if ($resident) { [uint32]0x03020100 } else { [uint32]0x02040100 }
        $invokeArguments = [object[]]@($handle, $scalars, $argBlock)
        $invokeEntry = $phaseClock.ElapsedTicks
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $rc = [int]$invoke.DynamicInvoke($invokeArguments)
        $sw.Stop()
        $invokeExit = $phaseClock.ElapsedTicks
        $stage = [BitConverter]::ToInt32($out, 36); $done = [BitConverter]::ToInt32($out, 44)
        $t0 = [BitConverter]::ToUInt64($out, 0); $t1 = [BitConverter]::ToUInt64($out, 8); $dt = [long]($t1 - $t0)
        if ($resident) {
            $entryTick = [BitConverter]::ToUInt64($out,64); $returnTick = [BitConverter]::ToUInt64($out,72)
            if ($entryTick -gt $t0 -or $returnTick -lt $t1) { throw 'Skel timing order is invalid.' }
            $lines.Add("Run=$run SkelEntryTicks=$entryTick RegionStartTicks=$t0 RegionEndTicks=$t1 SkelReturnTicks=$returnTick EntryToRegionMs=$((($t0-$entryTick)/19200.0).ToString('F3',$inv)) RegionToReturnMs=$((($returnTick-$t1)/19200.0).ToString('F3',$inv))")
            if ($run -eq 0) { $lines.Add("FirstCallIncludingMappingMs=$(($mappingMs+$sw.Elapsed.TotalMilliseconds+($invokeEntry-$setupEntry)*1000.0/[Diagnostics.Stopwatch]::Frequency).ToString('F3',$inv))") }
        }
        $pcmBytes = [byte[]]::new(2 * $samples); [Buffer]::BlockCopy($out, $pcmOffset, $pcmBytes, 0, $pcmBytes.Length)
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($pcmBytes))
        if ($kv.ContainsKey('ExpectedPcmSHA256') -and $hash -cne $kv.ExpectedPcmSHA256) {
            throw 'Baseline PCM mismatch; stopping before playback.'
        }
        if ($run -eq 0) {
            $pcmHash = $hash
            [IO.File]::WriteAllBytes([IO.Path]::Combine($dir, 'tail-output.bin'), $out)
            $lines.Add('OutputSHA256=' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($out)))
            $pcm = [int16[]]::new($samples); [Buffer]::BlockCopy($pcmBytes, 0, $pcm, 0, $pcmBytes.Length)
        }
        if ($rc -ne 0 -or $stage -ne 7 -or $done -ne 1 -or $hash -ne $pcmHash) { $allOk = $false }
        if ($rc -eq 0 -and $done -eq 1) { $ticks.Add($dt) }
        $outputExit = $phaseClock.ElapsedTicks
        $tickMs = 1000.0 / [Diagnostics.Stopwatch]::Frequency
        $lines.Add("Run=$run SetupEntryTicks=$setupEntry InvokeEntryTicks=$invokeEntry InvokeExitTicks=$invokeExit OutputExitTicks=$outputExit StopwatchFrequency=$([Diagnostics.Stopwatch]::Frequency) SetupMs=$((($invokeEntry - $setupEntry) * $tickMs).ToString('F3', $inv)) OutputMs=$((($outputExit - $invokeExit) * $tickMs).ToString('F3', $inv))")
        for ($i = 0; $i -lt $bufs.Count; $i++) { $lines.Add("Run=$run Buffer=$i Bytes=$($bufs[$i].Length) Allocation=PinnedManagedArray") }
        # Preserve the job-defined timer slots on every invocation. Their meaning
        # belongs to the emitted job; template 1 uses these for convolution only.
        $timer48 = if ($out.Length -ge 64) { [BitConverter]::ToUInt64($out, 48) } else { [uint64]0 }
        $timer56 = if ($out.Length -ge 64) { [BitConverter]::ToUInt64($out, 56) } else { [uint64]0 }
        $timer64 = if ($out.Length -ge 80) { [BitConverter]::ToUInt64($out, 64) } else { [uint64]0 }
        $timer72 = if ($out.Length -ge 80) { [BitConverter]::ToUInt64($out, 72) } else { [uint64]0 }
        $layerTimers = ''
        if ($out.Length -ge 1024 -and [BitConverter]::ToUInt32($out,80) -eq 0x314e4547L) {
            $layerTicks = [long[]]::new(36)
            for ($layer = 0; $layer -lt 36; $layer++) {
                $at = 96 + 16*$layer
                $layerTicks[$layer] = [long][BitConverter]::ToUInt64($out,$at+8) - [long][BitConverter]::ToUInt64($out,$at)
            }
            $layerTimers = ' HmxLayerTicks=' + ($layerTicks -join ',')
        }
        $lines.Add("Run=$run InvokeRc=$rc Stage=$stage Done=$done RegionTicks=$dt Timer48=$timer48 Timer56=$timer56 Timer64=$timer64 Timer72=$timer72 InvokeMs=$($sw.Elapsed.TotalMilliseconds.ToString('F3', $inv)) PcmSHA256=$hash$layerTimers")
        [IO.File]::WriteAllLines($receipt, $lines)
        if (-not $allOk) { throw 'Invocation or PCM parity failed; stopping before playback.' }
        if ($requestLifetime) {
            if ($null -eq $audio) {
                $audio = & $load 'Audio.AAudio.psm1' @($abi)
                $requestFloats = [float[]]::new($samples)
                for ($j=0;$j -lt $samples;$j++) { $requestFloats[$j]=[float]($pcm[$j]/32768.0) }
            }
            $stream = & $audio.Open 24000 1
            $playClock = [Diagnostics.Stopwatch]::StartNew()
            $written = & $audio.Write $stream $requestFloats $playClock
            $drain = & $audio.Drain $stream 10000
            $lines.Add("Request=$run Played=True WrittenFrames=$written DrainComplete=$($drain.Complete) XRunCount=$($drain.XRunCount) DrainAtMs=$($requestClock.Elapsed.TotalMilliseconds.ToString('F3',$inv))")
            $closeRc = & $audio.Close $stream; $stream=$null
            if (-not $drain.Complete -or $drain.XRunCount -ne 0 -or $closeRc -ne 0) { throw 'Request audio drain, xrun or close gate failed.' }
            [IO.File]::WriteAllLines($receipt,$lines)
        }
        if ($rc -ne 0) { break }
    }
    if ($requestLifetime) {
        $lines.Add("RequestsComplete=30 RequestSpanMs=$($requestClock.Elapsed.TotalMilliseconds.ToString('F3',$inv))")
        if ($requestClock.Elapsed.TotalSeconds -lt 120) { throw 'Request measurement was shorter than two minutes.' }
    }
    if ($allOk -and $kv.ContainsKey('AttributeBuffers')) {
        # The existing HmxConvRun dispatch returns AEE_EUNSUPPORTED (20) before
        # reading buffers for method 127. Keep its four-input/one-output ABI.
        # These calls produce no PCM and never replace the synthesis output.
        $cases = @(
            [pscustomobject]@{Name='Full'; Lengths=[long[]]@(4,$act.Length,$wts.Length,$tbl.Length,$out.Length)},
            [pscustomobject]@{Name='Small'; Lengths=[long[]]@(4,4,4,4,4)},
            [pscustomobject]@{Name='WithoutWeights'; Lengths=[long[]]@(4,$act.Length,4,$tbl.Length,$out.Length)})
        for ($probeRun = 0; $probeRun -lt 6; $probeRun++) {
            foreach ($case in $cases) {
                for ($i = 0; $i -lt 5; $i++) { $Marshal::WriteInt64($argBlock, 16 * $i + 8, $case.Lengths[$i]) }
                $probeArguments = [object[]]@($handle, [uint32]0x7F040100, $argBlock)
                $probeClock = [Diagnostics.Stopwatch]::StartNew()
                $probeRc = [int]$invoke.DynamicInvoke($probeArguments)
                $probeClock.Stop()
                $lines.Add("BufferProbe=$($case.Name) Run=$probeRun InvokeRc=$probeRc InvokeMs=$($probeClock.Elapsed.TotalMilliseconds.ToString('F3', $inv))")
                if ($probeRc -ne 20) { throw 'Buffer attribution dispatch did not return AEE_EUNSUPPORTED.' }
            }
        }
    }
    if ($ticks.Count) { $sorted = $ticks.ToArray(); [Array]::Sort($sorted); $median = $sorted[[int][math]::Floor($sorted.Count / 2)]
        $lines.Add("MedianRegionTicks=$median MedianRegionMs=$(($median / 19200.0).ToString('F3', $inv)) AudioSeconds=$(($samples / 24000.0).ToString('F3', $inv))") }
    # Diagnostic jobs without PCM declare Samples=1: nothing to play.
    if (-not $requestLifetime -and $allOk -and $null -ne $pcm -and $samples -gt 1) {
        $audio = & $load 'Audio.AAudio.psm1' @($abi)
        $stream = & $audio.Open 24000 1
        $floats = [float[]]::new($samples); for ($j = 0; $j -lt $samples; $j++) { $floats[$j] = [float]($pcm[$j] / 32768.0) }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $written = & $audio.Write $stream $floats $clock
        $drain = & $audio.Drain $stream 10000
        $lines.Add("Played=True WrittenFrames=$written DrainResult=$drain PlaybackMs=$($clock.Elapsed.TotalMilliseconds.ToString('F1', $inv))")
    }
    $passed = $allOk
    }
}
catch { $lines.Add('Error=' + $_.Exception.Message.Replace("`r", ' ').Replace("`n", ' ')) }
finally {
    if ($null -ne $stream -and $null -ne $audio) { try { $null = & $audio.Close $stream } catch { $lines.Add('CloseError=' + $_.Exception.Message) } }
    foreach ($payload in $sharedPayloads) {
        try {
            $unmapRc = $payload.Unmap.Invoke(3,[uint64]$payload.RemoteAddress,[UIntPtr]::new([uint64]$payload.MappedBytes))
            $lines.Add("PayloadUnmapRc=$unmapRc")
            if ($unmapRc -eq 0) { $payload.Free.Invoke($payload.Pointer) } else { $passed=$false }
        }
        catch { $passed=$false; $lines.Add('PayloadCleanupError=' + $_.Exception.Message) }
    }
    if ($null -ne $mappedWeights) { $mappedWeights.Close() }
    if ($opened) { $null = $close.DynamicInvoke([object[]]@($handle)) }
    foreach ($g in $pins) { $g.Free() }
    foreach ($a in $allocations) { $Marshal::FreeHGlobal($a) }
    if ($native -ne [IntPtr]::Zero) { [Runtime.InteropServices.NativeLibrary]::Free($native) }
    $lines.Add("Passed=$passed")
    [IO.File]::WriteAllLines($receipt, $lines)
}
