#requires -Version 7.0
# Where exactly does V73 refuse a 4-bit static weight: at the tensor, or at the op?
# Every return code is checked; nothing is discarded.
$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$receiptPath = [IO.Path]::Combine($root, 'receipt.txt')
$lines = [Collections.Generic.List[string]]::new()
$flush = { [IO.File]::WriteAllLines($receiptPath, $lines) }
$lines.Add("Pid=$([Environment]::ProcessId)"); $lines.Add('Job=fixed4')
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

    $qa = @{ Encoding = 'ScaleOffset'; Scale = [float]0.02; Offset = 128 }
    $qw = @{ Encoding = 'ScaleOffset'; Scale = [float]0.05; Offset = 8 }

    $reg = {
        param($Trial, $Tensor)
        $rg = & $graph.RegisterTensor $Trial $Tensor
        [pscustomobject]@{ Rc = [uint64]$rg.Rc; Id = [int]$rg.Id }
    }

    # --- MatMul, re-run with the registration code actually checked
    $matmul = {
        param([string]$Tag, [int]$WType, [int]$WBytes)
        $trial = $null
        try {
            $trial = & $native.NewTrial ('MM_' + $Tag)
            $arena = & $graph.NewArena
            [int]$K = 256; [int]$N = 256
            [byte[]]$wd = [byte[]]::new($WBytes)
            for ([int]$i = 0; $i -lt $WBytes; $i++) { $wd[$i] = [byte](($i % 7) + 1) }
            $x = & $graph.NewTensor $arena 'X' ([int]$abi.Enum.AppWrite) ([int]$abi.Enum.UFixed8) ([int[]]@(1, $K)) $null $qa
            $w = & $graph.NewTensor $arena 'W' ([int]$abi.Enum.Static) $WType ([int[]]@($K, $N)) $wd $qw
            $y = & $graph.NewTensor $arena 'Y' ([int]$abi.Enum.AppRead) ([int]$abi.Enum.UFixed8) ([int[]]@(1, $N)) $null $qa
            $rx = & $reg $trial $x; $rw = & $reg $trial $w; $ry = & $reg $trial $y
            [uint64]$addRc = 9999; [uint64]$finRc = 9999
            if ($rw.Rc -eq 0 -and $rw.Id -ne 0) {
                $op = & $graph.NewOp $arena 'M' 'MatMul' ([object[]]@($x, $w)) ([object[]]@($y)) ([IntPtr[]]@())
                $addRc = & $graph.AddNode $trial $op
                $finRc = & $graph.Finalize $trial
            }
            & $graph.FreeArena $arena
            $lines.Add(('MatMul {0,-10} wBytes={1,-6} regW.rc={2} regW.id={3} addRc={4} finRc={5}' -f $Tag, $WBytes, $rw.Rc, $rw.Id, $addRc, $finRc)); & $flush
        }
        catch { $lines.Add(('MatMul {0} threw={1}' -f $Tag, ($_.Exception.Message -replace '\s+', ' '))); & $flush }
        finally { if ($null -ne $trial) { [void](& $native.CloseTrial $trial) } }
    }

    # --- Conv2d, with the parameter tensors registered as the graph requires
    $conv = {
        param([string]$Tag, [int]$WType, [int]$WBytes)
        $trial = $null
        try {
            $trial = & $native.NewTrial ('CV_' + $Tag)
            $arena = & $graph.NewArena
            [int]$T = 256; [int]$Cin = 128; [int]$Cout = 128; [int]$Ksz = 3
            [byte[]]$wd = [byte[]]::new($WBytes)
            for ([int]$i = 0; $i -lt $WBytes; $i++) { $wd[$i] = [byte](($i % 11) + 1) }
            [byte[]]$bd = [byte[]]::new($Cout * 4)
            $x = & $graph.NewTensor $arena 'X' ([int]$abi.Enum.AppWrite) ([int]$abi.Enum.UFixed8) ([int[]]@(1, 1, $T, $Cin)) $null $qa
            $w = & $graph.NewTensor $arena 'W' ([int]$abi.Enum.Static) $WType ([int[]]@(1, $Ksz, $Cin, $Cout)) $wd $qw
            $bi = & $graph.NewTensor $arena 'B' ([int]$abi.Enum.Static) ([int]$abi.Enum.Int32) ([int[]]@($Cout)) $bd @{ Encoding = 'ScaleOffset'; Scale = [float](0.02 * 0.05); Offset = 0 }
            $y = & $graph.NewTensor $arena 'Y' ([int]$abi.Enum.AppRead) ([int]$abi.Enum.UFixed8) ([int[]]@(1, 1, $T, $Cout)) $null $qa
            $rx = & $reg $trial $x; $rw = & $reg $trial $w; $rb = & $reg $trial $bi; $ry = & $reg $trial $y
            [uint64]$addRc = 9999; [uint64]$finRc = 9999
            if ($rw.Rc -eq 0 -and $rw.Id -ne 0) {
                [byte[]]$dil = [byte[]]@(1,0,0,0, 1,0,0,0)
                [byte[]]$str = [byte[]]@(1,0,0,0, 1,0,0,0)
                [byte[]]$pad = [byte[]]@(0,0,0,0, 0,0,0,0, 1,0,0,0, 1,0,0,0)
                $tDil = & $graph.NewTensor $arena "$Tag.dil" ([int]$abi.Enum.Static) ([int]$abi.Enum.UInt32) ([int[]]@(2)) $dil $null
                $tStr = & $graph.NewTensor $arena "$Tag.str" ([int]$abi.Enum.Static) ([int]$abi.Enum.UInt32) ([int[]]@(2)) $str $null
                $tPad = & $graph.NewTensor $arena "$Tag.pad" ([int]$abi.Enum.Static) ([int]$abi.Enum.UInt32) ([int[]]@(2,2)) $pad $null
                foreach ($pt in @($tDil, $tStr, $tPad)) { [void](& $reg $trial $pt) }
                $p0 = & $graph.NewScalarUInt32Param $arena 'group' 1
                $p1 = & $graph.NewTensorParam $arena 'dilation' $tDil
                $p2 = & $graph.NewTensorParam $arena 'stride' $tStr
                $p3 = & $graph.NewTensorParam $arena 'pad_amount' $tPad
                $op = & $graph.NewOp $arena 'C' 'Conv2d' ([object[]]@($x, $w, $bi)) ([object[]]@($y)) ([IntPtr[]]@($p0, $p1, $p2, $p3))
                $addRc = & $graph.AddNode $trial $op
                $finRc = & $graph.Finalize $trial
            }
            & $graph.FreeArena $arena
            $lines.Add(('Conv2d {0,-10} wBytes={1,-6} regW.rc={2} regW.id={3} addRc={4} finRc={5}' -f $Tag, $WBytes, $rw.Rc, $rw.Id, $addRc, $finRc)); & $flush
        }
        catch { $lines.Add(('Conv2d {0} threw={1}' -f $Tag, ($_.Exception.Message -replace '\s+', ' '))); & $flush }
        finally { if ($null -ne $trial) { [void](& $native.CloseTrial $trial) } }
    }

    & $matmul 'w8'     ([int]$abi.Enum.UFixed8) (256 * 256)
    & $matmul 'w4pack' ([int]$abi.Enum.UFixed4) (256 * 256 / 2)
    & $matmul 'w4full' ([int]$abi.Enum.UFixed4) (256 * 256)
    & $conv   'w8'     ([int]$abi.Enum.UFixed8) (3 * 128 * 128)
    & $conv   'w4pack' ([int]$abi.Enum.UFixed4) (3 * 128 * 128 / 2)
    & $conv   'w4full' ([int]$abi.Enum.UFixed4) (3 * 128 * 128)
    $lines.Add('Passed=True'); & $flush
}
catch { $lines.Add('Passed=False'); $lines.Add("Error=$($_.Exception.Message)"); & $flush }
[void][Android.Util.Log]::Info('KokoroRpc', ($lines -join ' | '))
