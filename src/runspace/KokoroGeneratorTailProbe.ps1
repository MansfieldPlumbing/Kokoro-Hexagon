#requires -Version 7.0
# Device harness for the emitted generator tail job (src/emit/Kokoro.GeneratorTailRun.ps1).
# One unsigned-PD session, one handle; Runs invocations of method 2 (sc 0x02040100). Run 0's
# whole output buffer is saved for host verification; every run's PCM must be identical.
# The PCM is then played once through AAudio at 24 kHz mono.
$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$dir = [IO.Path]::Combine($root, 'generator-tail')
$receipt = [IO.Path]::Combine($dir, 'receipt.txt')
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('Job=kokoro-generator-tail')
$inv = [Globalization.CultureInfo]::InvariantCulture
$Marshal = [Runtime.InteropServices.Marshal]; $native = [IntPtr]::Zero; $opened = $false; $handle = [uint64]0
$pins = [Collections.Generic.List[object]]::new(); $allocations = [Collections.Generic.List[object]]::new()
$passed = $false; $stream = $null; $audio = $null
try {
    $kv = @{}; foreach ($l in [IO.File]::ReadAllLines([IO.Path]::Combine($dir, 'spec.txt'))) { $p = $l.Split('=', 2); if ($p.Count -eq 2) { $kv[$p[0]] = $p[1] } }
    $tiles = [int]$kv.Tiles; $runs = [int]$kv.Runs; $outputBytes = [int]$kv.OutputBytes; $pcmOffset = [int]$kv.PcmOffset; $samples = [int]$kv.Samples
    if ($tiles -lt 1 -or $tiles -gt 1024 -or $runs -lt 1 -or $runs -gt 20 -or $samples -lt 1 -or $pcmOffset + 2 * $samples -gt $outputBytes) { throw 'Spec out of range' }
    $lines.Add("Tiles=$tiles Runs=$runs Samples=$samples")
    $load = { param([string]$Name, [object[]]$Arguments)
        $ast = [Management.Automation.Language.Parser]::ParseFile([IO.Path]::Combine($root, $Name), [ref]$null, [ref]$null)
        $ast.GetScriptBlock().InvokeReturnAsIs($Arguments) }
    $abi = & $load 'Native.Binding.psm1' @()
    $so = [IO.Path]::Combine($root, 'qnn', 'libkokoro_generator_tail_skel.so')
    $lines.Add('LibrarySHA256=' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($so))))
    $search = [IO.Path]::Combine($root, 'qnn') + ';/vendor/lib/rfsa/adsp;/vendor/dsp/cdsp;/dsp'
    foreach ($name in 'ADSP_LIBRARY_PATH', 'DSP_LIBRARY_PATH') { [Environment]::SetEnvironmentVariable($name, $search); [Android.Systems.Os]::Setenv($name, $search, $true) }
    $native = [Runtime.InteropServices.NativeLibrary]::Load('libcdsprpc.so')
    $fn = { param($Name, $ReturnType, $Parameters)
        $Marshal::GetDelegateForFunctionPointer([Runtime.InteropServices.NativeLibrary]::GetExport($native, $Name), (& $abi.NewDelegateType ('GeneratorTail_' + $Name) $ReturnType $Parameters)) }
    $control = & $fn 'remote_session_control' ([int]) ([Type[]]@([uint32], [IntPtr], [uint32]))
    $open    = & $fn 'remote_handle64_open'    ([int]) ([Type[]]@([IntPtr], ([uint64]).MakeByRefType()))
    $invoke  = & $fn 'remote_handle64_invoke'  ([int]) ([Type[]]@([uint64], [uint32], [IntPtr]))
    $close   = & $fn 'remote_handle64_close'   ([int]) ([Type[]]@([uint64]))
    $pin = { param([byte[]]$Bytes) $g = [Runtime.InteropServices.GCHandle]::Alloc($Bytes, [Runtime.InteropServices.GCHandleType]::Pinned); $pins.Add($g); $g.AddrOfPinnedObject() }
    $cfg = $Marshal::AllocHGlobal(8); $allocations.Add($cfg)
    $Marshal::WriteInt32($cfg, 0, 3); $Marshal::WriteInt32($cfg, 4, 1)
    $rc = [int]$control.DynamicInvoke([object[]]@([uint32]2, $cfg, [uint32]8))
    $lines.Add("UnsignedPdRc=$rc"); if ($rc -ne 0) { throw 'Unsigned PD configuration failed' }
    $uri = [Text.Encoding]::UTF8.GetBytes('file:///libkokoro_generator_tail_skel.so?kokoro_generator_tail_skel_handle_invoke&_modver=1.0&_dom=cdsp' + [char]0)
    $oa = [object[]]@((& $pin $uri), [uint64]0)
    $rc = [int]$open.DynamicInvoke($oa)
    $lines.Add("OpenRc=$rc"); if ($rc -ne 0) { throw 'Kernel library open failed' }
    $handle = [uint64]$oa[1]; $opened = $true

    $act = [IO.File]::ReadAllBytes([IO.Path]::Combine($dir, 'activations.bin'))
    $wts = [IO.File]::ReadAllBytes([IO.Path]::Combine($dir, 'weights.bin'))
    $tbl = [IO.File]::ReadAllBytes([IO.Path]::Combine($dir, 'tables.bin'))
    $inputBytes = if ($kv.InputBytes) { [long]$kv.InputBytes } else { $tiles * 8192L }
    if ($act.Length -ne $inputBytes) { throw 'Input length' }
    $config = [BitConverter]::GetBytes([uint32]$tiles)
    $ticks = [Collections.Generic.List[long]]::new(); $pcmHash = $null; $allOk = $true; $pcm = $null
    for ($run = 0; $run -lt $runs; $run++) {
        $out = [byte[]]::new($outputBytes)
        $bufs = @($config, $act, $wts, $tbl, $out)
        $argBlock = $Marshal::AllocHGlobal(16 * $bufs.Count); $allocations.Add($argBlock)
        for ($i = 0; $i -lt $bufs.Count; $i++) { $Marshal::WriteIntPtr($argBlock, 16 * $i, (& $pin $bufs[$i])); $Marshal::WriteInt64($argBlock, 16 * $i + 8, [long]$bufs[$i].Length) }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $rc = [int]$invoke.DynamicInvoke([object[]]@($handle, [uint32]0x02040100, $argBlock))
        $sw.Stop()
        $stage = [BitConverter]::ToInt32($out, 36); $done = [BitConverter]::ToInt32($out, 44)
        $t0 = [BitConverter]::ToUInt64($out, 0); $t1 = [BitConverter]::ToUInt64($out, 8); $dt = [long]($t1 - $t0)
        $pcmBytes = [byte[]]::new(2 * $samples); [Buffer]::BlockCopy($out, $pcmOffset, $pcmBytes, 0, $pcmBytes.Length)
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($pcmBytes))
        if ($run -eq 0) {
            $pcmHash = $hash
            [IO.File]::WriteAllBytes([IO.Path]::Combine($dir, 'tail-output.bin'), $out)
            $lines.Add('OutputSHA256=' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($out)))
            $pcm = [int16[]]::new($samples); [Buffer]::BlockCopy($pcmBytes, 0, $pcm, 0, $pcmBytes.Length)
        }
        if ($rc -ne 0 -or $stage -ne 7 -or $done -ne 1 -or $hash -ne $pcmHash) { $allOk = $false }
        if ($rc -eq 0 -and $done -eq 1) { $ticks.Add($dt) }
        $lines.Add("Run=$run InvokeRc=$rc Stage=$stage Done=$done RegionTicks=$dt InvokeMs=$($sw.Elapsed.TotalMilliseconds.ToString('F3', $inv)) PcmSHA256=$hash")
        [IO.File]::WriteAllLines($receipt, $lines)
        if ($rc -ne 0) { break }
    }
    if ($ticks.Count) { $sorted = $ticks.ToArray(); [Array]::Sort($sorted); $median = $sorted[[int][math]::Floor($sorted.Count / 2)]
        $lines.Add("MedianRegionTicks=$median MedianRegionMs=$(($median / 19200.0).ToString('F3', $inv)) AudioSeconds=$(($samples / 24000.0).ToString('F3', $inv))") }
    # Diagnostic jobs without PCM declare Samples=1: nothing to play.
    if ($allOk -and $null -ne $pcm -and $samples -gt 1) {
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
catch { $lines.Add('Error=' + $_.Exception.Message.Replace("`r", ' ').Replace("`n", ' ')) }
finally {
    if ($null -ne $stream -and $null -ne $audio) { try { $null = & $audio.Close $stream } catch { $lines.Add('CloseError=' + $_.Exception.Message) } }
    if ($opened) { $null = $close.DynamicInvoke([object[]]@($handle)) }
    foreach ($g in $pins) { $g.Free() }
    foreach ($a in $allocations) { $Marshal::FreeHGlobal($a) }
    if ($native -ne [IntPtr]::Zero) { [Runtime.InteropServices.NativeLibrary]::Free($native) }
    $lines.Add("Passed=$passed")
    [IO.File]::WriteAllLines($receipt, $lines)
}
