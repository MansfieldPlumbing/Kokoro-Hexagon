#requires -Version 7.0
# Which op names does the V73 backend accept? Snake needs a sine; the rest of the resblock
# needs transpose and dilated convolution. One tiny graph per candidate name.
$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$receiptPath = [IO.Path]::Combine($root, 'receipt.txt')
$lines = [Collections.Generic.List[string]]::new()
$flush = { [IO.File]::WriteAllLines($receiptPath, $lines) }
$lines.Add("Pid=$([Environment]::ProcessId)"); $lines.Add('Job=opnames')
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

    [int]$C = 32; [int]$T = 256
    $try = {
        param([string]$OpType)
        $trial = $null
        try {
            $trial = & $native.NewTrial ('ON_' + ($OpType -replace '[^A-Za-z0-9]', ''))
            $arena = & $graph.NewArena
            $x = & $graph.NewTensor $arena 'X' ([int]$abi.Enum.AppWrite) ([int]$abi.Enum.Float32) ([int[]]@(1, $C, $T)) $null $null
            $rx = & $graph.RegisterTensor $trial $x
            $y = & $graph.NewTensor $arena 'Y' ([int]$abi.Enum.AppRead) ([int]$abi.Enum.Float32) ([int[]]@(1, $C, $T)) $null $null
            $ry = & $graph.RegisterTensor $trial $y
            $op = & $graph.NewOp $arena 'N' $OpType ([object[]]@($x)) ([object[]]@($y)) ([IntPtr[]]@())
            [uint64]$addRc = & $graph.AddNode $trial $op
            [uint64]$fin = 9999
            if ($addRc -eq 0) { $fin = & $graph.Finalize $trial }
            & $graph.FreeArena $arena
            $lines.Add(('Op={0,-24} addRc={1,-6} finalizeRc={2}' -f $OpType, $addRc, $fin)); & $flush
        }
        catch { $lines.Add(('Op={0,-24} threw={1}' -f $OpType, ($_.Exception.Message -replace '\s+', ' '))); & $flush }
        finally { if ($null -ne $trial) { [void](& $native.CloseTrial $trial) } }
    }

    foreach ($n in 'ElementWiseSin', 'Sin', 'ElementWiseSine', 'ElementWiseCos', 'ElementWiseNeuron',
                   'ElementWiseSquaredDifference', 'ElementWiseAbs', 'ElementWiseExp', 'ElementWiseLog',
                   'ElementWiseRsqrt', 'ElementWiseSquareRoot', 'Tanh', 'Sigmoid') { & $try $n }
    $lines.Add('Passed=True'); & $flush
}
catch { $lines.Add('Passed=False'); $lines.Add("Error=$($_.Exception.Message)"); & $flush }
[void][Android.Util.Log]::Info('KokoroRpc', ($lines -join ' | '))
