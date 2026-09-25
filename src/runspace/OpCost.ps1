#requires -Version 7.0
# What does one op cost in a serialized QNN context? Chain N identical elementwise ops over
# small tensors so weights cannot dominate, and read contextGetBinarySize for each N.
$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$receiptPath = [IO.Path]::Combine($root, 'receipt.txt')
$lines = [Collections.Generic.List[string]]::new()
$flush = { [IO.File]::WriteAllLines($receiptPath, $lines) }
$lines.Add("Pid=$([Environment]::ProcessId)"); $lines.Add('Job=opcost')
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

    [int]$C = 64; [int]$T = 64                      # small: 4096 elements, 8 KB at fp16
    $chain = {
        param([int]$Ops)
        $trial = $null
        try {
            $trial = & $native.NewTrial ('OPCOST_' + $Ops)
            $arena = & $graph.NewArena
            $prev = & $graph.NewTensor $arena 'X' ([int]$abi.Enum.AppWrite) ([int]$abi.Enum.Float32) ([int[]]@(1, $C, $T)) $null $null
            $rg = & $graph.RegisterTensor $trial $prev
            if ($rg.Rc -ne 0 -or $rg.Id -eq 0) { throw "register X rc=$($rg.Rc)" }
            [uint64]$worstAdd = 0
            for ([int]$i = 0; $i -lt $Ops; $i++) {
                [bool]$last = ($i -eq $Ops - 1)
                [int]$kind = if ($last) { [int]$abi.Enum.AppRead } else { [int]$abi.Enum.Native }
                $out = & $graph.NewTensor $arena ("T$i") $kind ([int]$abi.Enum.Float32) ([int[]]@(1, $C, $T)) $null $null
                $r2 = & $graph.RegisterTensor $trial $out
                if ($r2.Rc -ne 0 -or $r2.Id -eq 0) { throw "register T$i rc=$($r2.Rc)" }
                $op = & $graph.NewOp $arena ("N$i") 'ElementWiseMultiply' ([object[]]@($prev, $prev)) ([object[]]@($out)) ([IntPtr[]]@())
                [uint64]$rc = & $graph.AddNode $trial $op
                if ($rc -ne 0) { $worstAdd = $rc }
                $prev = $out
            }
            [uint64]$fin = & $graph.Finalize $trial
            [int]$bytes = -1
            if ($fin -eq 0) { $bytes = (& $graph.SerializeContext $trial $arena).Length }
            & $graph.FreeArena $arena
            $lines.Add(('Ops={0,-4} addRcWorst={1} finalizeRc={2} contextBytes={3}' -f $Ops, $worstAdd, $fin, $bytes)); & $flush
        }
        catch { $lines.Add(('Ops={0} threw={1}' -f $Ops, ($_.Exception.Message -replace '\s+', ' '))); & $flush }
        finally { if ($null -ne $trial) { [void](& $native.CloseTrial $trial) } }
    }

    foreach ($n in 1, 2, 4, 8, 16, 32, 64) { & $chain $n }
    $lines.Add('Passed=True'); & $flush
}
catch { $lines.Add('Passed=False'); $lines.Add("Error=$($_.Exception.Message)"); & $flush }
[void][Android.Util.Log]::Info('KokoroRpc', ($lines -join ' | '))
