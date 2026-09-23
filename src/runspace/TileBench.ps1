#requires -Version 7.0
# Does channel tiling actually buy time at the generator's real tensor size?
# AdaIN (per-channel statistics over time, per-channel affine) over [1,128,19200], built
# whole and built as four 32-channel chains. Same arithmetic, same total work.
$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$receiptPath = [IO.Path]::Combine($root, 'receipt.txt')
$lines = [Collections.Generic.List[string]]::new()
$flush = { [IO.File]::WriteAllLines($receiptPath, $lines) }
$lines.Add("Pid=$([Environment]::ProcessId)"); $lines.Add('Job=tilebench')
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

    [int]$Tlen = 19200
    [int]$Ctot = 128
    [int]$Reps = 12

    $u32 = { param([uint32[]]$v) [byte[]]$b = [byte[]]::new(4 * $v.Length); [Buffer]::BlockCopy($v, 0, $b, 0, $b.Length); , $b }
    $f32 = { param([int]$n, [float]$val) [float[]]$a = [float[]]::new($n); for ([int]$i = 0; $i -lt $n; $i++) { $a[$i] = $val }
             [byte[]]$b = [byte[]]::new(4 * $n); [Buffer]::BlockCopy($a, 0, $b, 0, $b.Length); , $b }

    $run = {
        param([string]$Tag, [int]$Ctile)
        $trial = $null
        try {
            [int]$chains = $Ctot / $Ctile
            $trial = & $native.NewTrial ('TB_' + $Tag) @(@{ Option = [int]$abi.Enum.HtpVtcmSizeMb; Value = 8 })
            $arena = & $graph.NewArena
            $reg = { param($t) $r = & $graph.RegisterTensor $trial $t; if ($r.Rc -ne 0 -or $r.Id -eq 0) { throw "reg $($t.Name) rc=$($r.Rc)" }; $t }
            $axes = & $reg (& $graph.NewTensor $arena 'axes' ([int]$abi.Enum.Static) ([int]$abi.Enum.UInt32) ([int[]]@(1)) (& $u32 ([uint32[]]@(2))) $null)
            $eps  = & $reg (& $graph.NewTensor $arena 'eps' ([int]$abi.Enum.Static) ([int]$abi.Enum.Float32) ([int[]]@(1, 1, 1)) (& $f32 1 1e-5) $null)
            $ins = [Collections.Generic.List[object]]::new()
            $outs = [Collections.Generic.List[object]]::new()
            for ([int]$c = 0; $c -lt $chains; $c++) {
                $x  = & $reg (& $graph.NewTensor $arena "X$c" ([int]$abi.Enum.AppWrite) ([int]$abi.Enum.Float32) ([int[]]@(1, $Ctile, $Tlen)) $null $null)
                $g  = & $reg (& $graph.NewTensor $arena "g$c" ([int]$abi.Enum.Static) ([int]$abi.Enum.Float32) ([int[]]@(1, $Ctile, 1)) (& $f32 $Ctile 1.25) $null)
                $sh = & $reg (& $graph.NewTensor $arena "s$c" ([int]$abi.Enum.Static) ([int]$abi.Enum.Float32) ([int[]]@(1, $Ctile, 1)) (& $f32 $Ctile -0.5) $null)
                $mk = { param([string]$n, [int[]]$shape, [bool]$isOut)
                        $kind = if ($isOut) { [int]$abi.Enum.AppRead } else { [int]$abi.Enum.Native }
                        & $reg (& $graph.NewTensor $arena $n $kind ([int]$abi.Enum.Float32) $shape $null $null) }
                $op = { param([string]$n, [string]$type, [object[]]$i, [object[]]$o, [IntPtr[]]$p)
                        $node = & $graph.NewOp $arena $n $type $i $o $p
                        [uint64]$rc = & $graph.AddNode $trial $node
                        if ($rc -ne 0) { throw "$n rc=$rc" } }
                $pAx = & $graph.NewTensorParam $arena 'axes' $axes
                $pKd = & $graph.NewScalarBoolParam $arena 'keep_dims' $true
                $mean = & $mk "mean$c" ([int[]]@(1, $Ctile, 1)) $false
                & $op "rm1$c" 'ReduceMean' @($x) @($mean) ([IntPtr[]]@($pAx, $pKd))
                $cen = & $mk "cen$c" ([int[]]@(1, $Ctile, $Tlen)) $false
                & $op "sub$c" 'ElementWiseSubtract' @($x, $mean) @($cen) ([IntPtr[]]@())
                $sq = & $mk "sq$c" ([int[]]@(1, $Ctile, $Tlen)) $false
                & $op "mul$c" 'ElementWiseMultiply' @($cen, $cen) @($sq) ([IntPtr[]]@())
                $pAx2 = & $graph.NewTensorParam $arena 'axes' $axes
                $pKd2 = & $graph.NewScalarBoolParam $arena 'keep_dims' $true
                $var = & $mk "var$c" ([int[]]@(1, $Ctile, 1)) $false
                & $op "rm2$c" 'ReduceMean' @($sq) @($var) ([IntPtr[]]@($pAx2, $pKd2))
                $ve = & $mk "ve$c" ([int[]]@(1, $Ctile, 1)) $false
                & $op "add1$c" 'ElementWiseAdd' @($var, $eps) @($ve) ([IntPtr[]]@())
                $sd = & $mk "sd$c" ([int[]]@(1, $Ctile, 1)) $false
                & $op "sqrt$c" 'ElementWiseSquareRoot' @($ve) @($sd) ([IntPtr[]]@())
                $nm = & $mk "nm$c" ([int[]]@(1, $Ctile, $Tlen)) $false
                & $op "div$c" 'ElementWiseDivide' @($cen, $sd) @($nm) ([IntPtr[]]@())
                $sc = & $mk "sc$c" ([int[]]@(1, $Ctile, $Tlen)) $false
                & $op "mul2$c" 'ElementWiseMultiply' @($nm, $g) @($sc) ([IntPtr[]]@())
                $y = & $mk "Y$c" ([int[]]@(1, $Ctile, $Tlen)) $true
                & $op "add2$c" 'ElementWiseAdd' @($sc, $sh) @($y) ([IntPtr[]]@())
                [void]$ins.Add($x); [void]$outs.Add($y)
            }
            [uint64]$fin = & $graph.Finalize $trial
            if ($fin -ne 0) { throw "finalize rc=$fin" }
            [int]$ctxBytes = (& $graph.SerializeContext $trial $arena).Length

            [int]$tileBytes = $Ctile * $Tlen * 4
            $execIn = [Collections.Generic.List[object]]::new()
            $execOut = [Collections.Generic.List[object]]::new()
            for ([int]$c = 0; $c -lt $chains; $c++) {
                [byte[]]$xb = [byte[]]::new($tileBytes)
                for ([int]$i = 0; $i -lt $tileBytes; $i += 4) { $xb[$i + 3] = 60 }   # ~1.0 fp32-ish pattern
                [void]$execIn.Add((& $graph.NewExecTensor $arena $ins[$c] $xb))
                [void]$execOut.Add((& $graph.NewExecTensor $arena $outs[$c] ([byte[]]::new($tileBytes))))
            }
            [double[]]$ms = [double[]]::new($Reps)
            for ([int]$r = 0; $r -lt $Reps; $r++) {
                $sw = [Diagnostics.Stopwatch]::StartNew()
                [uint64]$erc = & $graph.Execute $trial $arena $execIn.ToArray() $execOut.ToArray()
                $ms[$r] = $sw.Elapsed.TotalMilliseconds
                if ($erc -ne 0) { throw "execute rc=$erc" }
            }
            [double[]]$warm = $ms[2..($Reps - 1)]; [Array]::Sort($warm)
            [double]$sum = 0; foreach ($v in $warm) { $sum += $v }
            & $graph.FreeArena $arena
            $lines.Add(('Tile={0,-4} chains={1,-3} ctxBytes={2,-9} meanMs={3:F1} p50Ms={4:F1} minMs={5:F1}' -f $Ctile, $chains, $ctxBytes, ($sum / $warm.Length), $warm[[int]($warm.Length / 2)], $warm[0])); & $flush
        }
        catch { $lines.Add(('Tile={0} threw={1}' -f $Ctile, ($_.Exception.Message -replace '\s+', ' '))); & $flush }
        finally { if ($null -ne $trial) { [void](& $native.CloseTrial $trial) } }
    }

    & $run 'c128' 128
    & $run 'c64'  64
    & $run 'c32'  32
    & $run 'c16'  16
    $lines.Add('Passed=True'); & $flush
}
catch { $lines.Add('Passed=False'); $lines.Add("Error=$($_.Exception.Message)"); & $flush }
[void][Android.Util.Log]::Info('KokoroRpc', ($lines -join ' | '))
