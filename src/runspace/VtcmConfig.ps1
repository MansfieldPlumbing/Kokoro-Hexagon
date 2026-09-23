#requires -Version 7.0
# Do graph configs take effect? The emitted context records the compiler's settings as plain
# text, so ask for a VTCM size and read it straight back out of the binary.
$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$receiptPath = [IO.Path]::Combine($root, 'receipt.txt')
$lines = [Collections.Generic.List[string]]::new()
$flush = { [IO.File]::WriteAllLines($receiptPath, $lines) }
$lines.Add("Pid=$([Environment]::ProcessId)"); $lines.Add('Job=vtcmconfig')
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

    # Read a setting back out of the config string the context carries.
    $settingOf = {
        param([byte[]]$Ctx, [string]$Key)
        [byte[]]$pat = [Text.Encoding]::ASCII.GetBytes($Key)
        for ([int]$i = 0; $i -lt $Ctx.Length - $pat.Length - 24; $i++) {
            [bool]$hit = $true
            for ([int]$j = 0; $j -lt $pat.Length; $j++) { if ($Ctx[$i + $j] -ne $pat[$j]) { $hit = $false; break } }
            if ($hit) {
                $sb = [Text.StringBuilder]::new()
                for ([int]$k = $i + $pat.Length; $k -lt $i + $pat.Length + 20; $k++) {
                    [byte]$c = $Ctx[$k]
                    if ($c -eq 59 -or $c -lt 32 -or $c -ge 127) { break }
                    [void]$sb.Append([char]$c)
                }
                return $sb.ToString()
            }
        }
        return '<not found>'
    }

    [int]$C = 64; [int]$T = 64
    $case = {
        param([string]$Tag, [object[]]$Configs)
        $trial = $null
        try {
            $trial = & $native.NewTrial 'VC_GRAPH' $Configs
            $arena = & $graph.NewArena
            $x = & $graph.NewTensor $arena 'X' ([int]$abi.Enum.AppWrite) ([int]$abi.Enum.Float32) ([int[]]@(1, $C, $T)) $null $null
            [void](& $graph.RegisterTensor $trial $x)
            $y = & $graph.NewTensor $arena 'Y' ([int]$abi.Enum.AppRead) ([int]$abi.Enum.Float32) ([int[]]@(1, $C, $T)) $null $null
            [void](& $graph.RegisterTensor $trial $y)
            $op = & $graph.NewOp $arena 'N' 'ElementWiseMultiply' ([object[]]@($x, $x)) ([object[]]@($y)) ([IntPtr[]]@())
            [void](& $graph.AddNode $trial $op)
            [uint64]$fin = & $graph.Finalize $trial
            [string]$vt = '-'; [string]$vs = '-'; [string]$hv = '-'; [int]$bytes = -1
            if ($fin -eq 0) {
                [byte[]]$ctx = & $graph.SerializeContext $trial $arena
                $bytes = $ctx.Length
                $vt = & $settingOf $ctx 'vtcm_mb='
                $vs = & $settingOf $ctx 'vtcm_size='
                $hv = & $settingOf $ctx 'hvx_threads='
            }
            & $graph.FreeArena $arena
            $lines.Add(('Case={0,-14} finalizeRc={1} bytes={2,-8} vtcm_mb={3,-6} vtcm_size={4,-10} hvx_threads={5}' -f $Tag, $fin, $bytes, $vt, $vs, $hv)); & $flush
        }
        catch { $lines.Add(('Case={0} threw={1}' -f $Tag, ($_.Exception.Message -replace '\s+', ' '))); & $flush }
        finally { if ($null -ne $trial) { [void](& $native.CloseTrial $trial) } }
    }

    & $case 'default'   @()
    & $case 'vtcm8'     @(@{ Option = [int]$abi.Enum.HtpVtcmSizeMb; Value = 8 })
    & $case 'vtcm2'     @(@{ Option = [int]$abi.Enum.HtpVtcmSizeMb; Value = 2 })
    & $case 'vtcm8+hvx2' @(@{ Option = [int]$abi.Enum.HtpVtcmSizeMb; Value = 8 }, @{ Option = [int]$abi.Enum.HtpNumHvxThreads; Value = 2 })
    $lines.Add('Passed=True'); & $flush
}
catch { $lines.Add('Passed=False'); $lines.Add("Error=$($_.Exception.Message)"); & $flush }
[void][Android.Util.Log]::Info('KokoroRpc', ($lines -join ' | '))
