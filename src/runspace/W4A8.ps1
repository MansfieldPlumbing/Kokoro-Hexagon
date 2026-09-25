#requires -Version 7.0
# Does V73 finalize a 4-bit static weight, and if so does it actually store 4 bits?
# Same MatMul three ways; the answer is two integers per case: finalize rc and context size.
$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$lines = [Collections.Generic.List[string]]::new()
$lines.Add("Pid=$([Environment]::ProcessId)"); $lines.Add('Job=w4a8')
try {
    $qnn = [IO.Path]::Combine($root, 'qnn')
    $dsp = (@($qnn, '/vendor/lib/rfsa/adsp', '/vendor/dsp/cdsp', '/dsp') -join ';')
    foreach ($v in 'ADSP_LIBRARY_PATH', 'DSP_LIBRARY_PATH') { [Environment]::SetEnvironmentVariable($v, $dsp); [Android.Systems.Os]::Setenv($v, $dsp, $true) }
    foreach ($so in 'libQnnHtpV73Stub.so', 'libQnnHtp.so') { [void][Runtime.InteropServices.NativeLibrary]::Load([IO.Path]::Combine($qnn, $so)) }

    $mr = [IO.Path]::Combine($root, 'r009-modules')
    $load = { param([string]$n, [object[]]$a) [scriptblock]::Create([IO.File]::ReadAllText([IO.Path]::Combine($mr, $n))).InvokeReturnAsIs($a) }
    $binding = & $load 'Native.Binding.psm1' ([object[]]@())
    $abi = & $load 'Qnn.Abi.psm1' ([object[]]@($binding))
    $native = & $load 'Qnn.Native.psm1' ([object[]]@($abi))
    $graph = & $load 'Qnn.Graph.psm1' ([object[]]@($abi, $native))
    [void](& $native.Initialize ([pscustomobject]@{ DataRoot = $qnn; NativeLibraryDirectory = $qnn }))
    $lines.Add('Init=ok')

    [int]$K = 256; [int]$N = 256
    $q8 = @{ Encoding = 'ScaleOffset'; Scale = [float]0.01; Offset = 0 }
    $qw = @{ Encoding = 'ScaleOffset'; Scale = [float]0.05; Offset = 8 }

    $case = {
        param([string]$Tag, [int]$WeightType, [int]$WeightBytes)
        $trial = $null
        try {
            $trial = & $native.NewTrial ('W4A8_' + $Tag)
            $arena = & $graph.NewArena
            [byte[]]$w = [byte[]]::new($WeightBytes)
            for ([int]$i = 0; $i -lt $WeightBytes; $i++) { $w[$i] = [byte](($i % 7) + 1) }
            $x = & $graph.NewTensor $arena 'X' ([int]$abi.Enum.AppWrite) ([int]$abi.Enum.UFixed8) ([int[]]@(1, $K)) $null $q8
            $wt = & $graph.NewTensor $arena 'W' ([int]$abi.Enum.Static) $WeightType ([int[]]@($K, $N)) $w $qw
            $y = & $graph.NewTensor $arena 'Y' ([int]$abi.Enum.AppRead) ([int]$abi.Enum.UFixed8) ([int[]]@(1, $N)) $null $q8
            foreach ($t in $x, $wt, $y) { [void](& $graph.RegisterTensor $trial $t) }
            $op = & $graph.NewOp $arena 'MM' 'MatMul' ([object[]]@($x, $wt)) ([object[]]@($y)) ([IntPtr[]]@())
            [uint64]$addRc = & $graph.AddNode $trial $op
            [uint64]$finRc = & $graph.Finalize $trial
            [int]$ctxBytes = -1
            if ($finRc -eq 0) { $ctxBytes = (& $graph.SerializeContext $trial $arena).Length }
            & $graph.FreeArena $arena
            $lines.Add(('Case={0} weightBytes={1} addRc={2} finalizeRc={3} contextBytes={4}' -f $Tag, $WeightBytes, $addRc, $finRc, $ctxBytes))
        }
        catch { $lines.Add(('Case={0} weightBytes={1} threw={2}' -f $Tag, $WeightBytes, ($_.Exception.Message -replace '\s+', ' '))) }
        finally { if ($null -ne $trial) { [void](& $native.CloseTrial $trial) } }
    }

    & $case 'w8'          ([int]$abi.Enum.UFixed8) ($K * $N)
    & $case 'w4packed'    ([int]$abi.Enum.UFixed4) ([int]($K * $N / 2))
    & $case 'w4unpacked'  ([int]$abi.Enum.UFixed4) ($K * $N)
    $lines.Add('Passed=True')
}
catch { $lines.Add('Passed=False'); $lines.Add("Error=$($_.Exception.Message)"); $lines.Add("At=$($_.InvocationInfo.PositionMessage -replace '\s+', ' ')") }
[IO.File]::WriteAllLines([IO.Path]::Combine($root, 'receipt.txt'), $lines)
[void][Android.Util.Log]::Info('KokoroRpc', ($lines -join ' | '))
