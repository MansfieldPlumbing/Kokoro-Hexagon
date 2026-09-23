#requires -Version 7.0
# Where does the prepared program live in a context, and does it grow per op?
# Emit the same graph at several op counts and keep the bytes for an off-device diff.
$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$receiptPath = [IO.Path]::Combine($root, 'receipt.txt')
$lines = [Collections.Generic.List[string]]::new()
$flush = { [IO.File]::WriteAllLines($receiptPath, $lines) }
$lines.Add("Pid=$([Environment]::ProcessId)"); $lines.Add('Job=progdiff')
try {
    $qnn = [IO.Path]::Combine($root, 'qnn')
    $dsp = (@($qnn, '/vendor/lib/rfsa/adsp', '/vendor/dsp/cdsp', '/dsp') -join ';')
    foreach ($v in 'ADSP_LIBRARY_PATH', 'DSP_LIBRARY_PATH') { [Environment]::SetEnvironmentVariable($v, $dsp); [Android.Systems.Os]::Setenv($v, $dsp, $true) }
    foreach ($so in 'libQnnHtpV73Stub.so', 'libQnnHtp.so') { [void][Runtime.InteropServices.NativeLibrary]::Load([IO.Path]::Combine($qnn, $so)) }
    $mr = [IO.Path]::Combine($root, 'r009-modules')
    $load = { param([string]$nm, [object[]]$a) [scriptblock]::Create([IO.File]::ReadAllText([IO.Path]::Combine($mr, $nm))).InvokeReturnAsIs($a) }
    $abi = & $load 'Qnn.Abi.psm1' ([object[]]@())
    $native = & $load 'Qnn.Native.psm1' ([object[]]@($abi))
    $graph = & $load 'Qnn.Graph.psm1' ([object[]]@($abi, $native))
    [void](& $native.Initialize ([pscustomobject]@{ DataRoot = $qnn; NativeLibraryDirectory = $qnn }))
    $lines.Add('Init=ok'); & $flush
    $outDir = [IO.Path]::Combine($root, 'progdiff')
    [void][IO.Directory]::CreateDirectory($outDir)

    [int]$C = 64; [int]$T = 64
    $emit = {
        param([string]$Tag, [int]$Ops, [string]$OpType)
        $trial = $null
        try {
            $trial = & $native.NewTrial 'PD_GRAPH'          # identical graph name every time
            $arena = & $graph.NewArena
            $prev = & $graph.NewTensor $arena 'X' ([int]$abi.Enum.AppWrite) ([int]$abi.Enum.Float32) ([int[]]@(1, $C, $T)) $null $null
            [void](& $graph.RegisterTensor $trial $prev)
            for ([int]$i = 0; $i -lt $Ops; $i++) {
                [bool]$last = ($i -eq $Ops - 1)
                [int]$kind = if ($last) { [int]$abi.Enum.AppRead } else { [int]$abi.Enum.Native }
                $out = & $graph.NewTensor $arena ("T$i") $kind ([int]$abi.Enum.Float32) ([int[]]@(1, $C, $T)) $null $null
                [void](& $graph.RegisterTensor $trial $out)
                $op = & $graph.NewOp $arena ("N$i") $OpType ([object[]]@($prev, $prev)) ([object[]]@($out)) ([IntPtr[]]@())
                [void](& $graph.AddNode $trial $op)
                $prev = $out
            }
            [uint64]$fin = & $graph.Finalize $trial
            [int]$bytes = -1
            if ($fin -eq 0) {
                [byte[]]$ctx = & $graph.SerializeContext $trial $arena
                $bytes = $ctx.Length
                [IO.File]::WriteAllBytes([IO.Path]::Combine($outDir, "$Tag.bin"), $ctx)
            }
            & $graph.FreeArena $arena
            $lines.Add(('Emit={0,-10} ops={1,-4} op={2,-22} finalizeRc={3} bytes={4}' -f $Tag, $Ops, $OpType, $fin, $bytes)); & $flush
        }
        catch { $lines.Add(('Emit={0} threw={1}' -f $Tag, ($_.Exception.Message -replace '\s+', ' '))); & $flush }
        finally { if ($null -ne $trial) { [void](& $native.CloseTrial $trial) } }
    }

    & $emit 'mul01'  1  'ElementWiseMultiply'
    & $emit 'mul02'  2  'ElementWiseMultiply'
    & $emit 'mul04'  4  'ElementWiseMultiply'
    & $emit 'mul16' 16  'ElementWiseMultiply'
    & $emit 'add01'  1  'ElementWiseAdd'
    $lines.Add('Passed=True'); & $flush
}
catch { $lines.Add('Passed=False'); $lines.Add("Error=$($_.Exception.Message)"); & $flush }
[void][Android.Util.Log]::Info('KokoroRpc', ($lines -join ' | '))
