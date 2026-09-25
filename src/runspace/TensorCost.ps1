#requires -Version 7.0
# Op count is nearly free in a serialized context. Is it static tensors that cost? Vary the
# number and the size of static weights independently and read contextGetBinarySize.
$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$receiptPath = [IO.Path]::Combine($root, 'receipt.txt')
$lines = [Collections.Generic.List[string]]::new()
$flush = { [IO.File]::WriteAllLines($receiptPath, $lines) }
$lines.Add("Pid=$([Environment]::ProcessId)"); $lines.Add('Job=tensorcost')
try {
    $qnn = [IO.Path]::Combine($root, 'qnn')
    $dsp = (@($qnn, '/vendor/lib/rfsa/adsp', '/vendor/dsp/cdsp', '/dsp') -join ';')
    foreach ($v in 'ADSP_LIBRARY_PATH', 'DSP_LIBRARY_PATH') { [Environment]::SetEnvironmentVariable($v, $dsp); [Android.Systems.Os]::Setenv($v, $dsp, $true) }
    foreach ($so in 'libQnnHtpV73Stub.so', 'libQnnHtp.so') { [void][Runtime.InteropServices.NativeLibrary]::Load([IO.Path]::Combine($qnn, $so)) }
    $mr = [IO.Path]::Combine($root, 'r009-modules')
    $load = { param([string]$nm, [object[]]$a) [scriptblock]::Create([IO.File]::ReadAllText([IO.Path]::Combine($mr, $nm))).InvokeReturnAsIs($a) }
    $binding = & $load 'Native.Binding.psm1' ([object[]]@())
    $abi = & $load 'Qnn.Abi.psm1' ([object[]]@($binding))
    $native = & $load 'Qnn.Native.psm1' ([object[]]@($abi))
    $graph = & $load 'Qnn.Graph.psm1' ([object[]]@($abi, $native))
    [void](& $native.Initialize ([pscustomobject]@{ DataRoot = $qnn; NativeLibraryDirectory = $qnn }))
    $lines.Add('Init=ok'); & $flush

    # Each case: $Count static tensors of $Elems fp32 elements, each consumed by one Add.
    $case = {
        param([int]$Count, [int]$Elems)
        $trial = $null
        try {
            $trial = & $native.NewTrial ('TC_' + $Count + '_' + $Elems)
            $arena = & $graph.NewArena
            $x = & $graph.NewTensor $arena 'X' ([int]$abi.Enum.AppWrite) ([int]$abi.Enum.Float32) ([int[]]@(1, $Elems)) $null $null
            $rg = & $graph.RegisterTensor $trial $x
            if ($rg.Rc -ne 0 -or $rg.Id -eq 0) { throw "register X rc=$($rg.Rc)" }
            [byte[]]$data = [byte[]]::new($Elems * 4)
            for ([int]$i = 0; $i -lt $data.Length; $i++) { $data[$i] = [byte](($i % 251) + 1) }
            $prev = $x
            for ([int]$i = 0; $i -lt $Count; $i++) {
                $w = & $graph.NewTensor $arena ("W$i") ([int]$abi.Enum.Static) ([int]$abi.Enum.Float32) ([int[]]@(1, $Elems)) $data $null
                $rw = & $graph.RegisterTensor $trial $w
                if ($rw.Rc -ne 0 -or $rw.Id -eq 0) { throw "register W$i rc=$($rw.Rc)" }
                [bool]$last = ($i -eq $Count - 1)
                [int]$kind = if ($last) { [int]$abi.Enum.AppRead } else { [int]$abi.Enum.Native }
                $out = & $graph.NewTensor $arena ("T$i") $kind ([int]$abi.Enum.Float32) ([int[]]@(1, $Elems)) $null $null
                $ro = & $graph.RegisterTensor $trial $out
                if ($ro.Rc -ne 0 -or $ro.Id -eq 0) { throw "register T$i rc=$($ro.Rc)" }
                $op = & $graph.NewOp $arena ("N$i") 'ElementWiseAdd' ([object[]]@($prev, $w)) ([object[]]@($out)) ([IntPtr[]]@())
                [void](& $graph.AddNode $trial $op)
                $prev = $out
            }
            [uint64]$fin = & $graph.Finalize $trial
            [int]$bytes = -1
            if ($fin -eq 0) { $bytes = (& $graph.SerializeContext $trial $arena).Length }
            & $graph.FreeArena $arena
            [int]$payload = $Count * $Elems * 2      # statics land as fp16
            $lines.Add(('Count={0,-4} Elems={1,-7} fp16Payload={2,-9} contextBytes={3,-9} overhead={4}' -f $Count, $Elems, $payload, $bytes, ($bytes - $payload))); & $flush
        }
        catch { $lines.Add(('Count={0} Elems={1} threw={2}' -f $Count, $Elems, ($_.Exception.Message -replace '\s+', ' '))); & $flush }
        finally { if ($null -ne $trial) { [void](& $native.CloseTrial $trial) } }
    }

    # fixed payload, spread across more tensors
    & $case 1  32768
    & $case 2  16384
    & $case 4  8192
    & $case 8  4096
    & $case 16 2048
    & $case 32 1024
    # fixed tensor count, growing payload
    & $case 8  16384
    & $case 8  65536
    $lines.Add('Passed=True'); & $flush
}
catch { $lines.Add('Passed=False'); $lines.Add("Error=$($_.Exception.Message)"); & $flush }
[void][Android.Util.Log]::Info('KokoroRpc', ($lines -join ' | '))
