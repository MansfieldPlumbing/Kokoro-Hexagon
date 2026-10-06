#requires -Version 7.0
# Per-op HTP profile of the generator context (speak-job.ps1 Gen stage): warm-up execute, then one DETAILED profiled execute.
$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$lines = [Collections.Generic.List[string]]::new(); $lines.Add("Pid=$([Environment]::ProcessId)"); $lines.Add('Job=kokoro-profile')
try {
    $job = [scriptblock]::Create([IO.File]::ReadAllText([IO.Path]::Combine($root, 'speak-job.ps1'))).InvokeReturnAsIs()
    $qnn = [IO.Path]::Combine($root, 'qnn')
    $dsp = (@($qnn, '/vendor/lib/rfsa/adsp', '/vendor/dsp/cdsp', '/dsp') -join ';')
    foreach ($v in 'ADSP_LIBRARY_PATH', 'DSP_LIBRARY_PATH') { [Environment]::SetEnvironmentVariable($v, $dsp); [Android.Systems.Os]::Setenv($v, $dsp, $true) }
    foreach ($so in 'libQnnHtpV73Stub.so', 'libQnnHtp.so') { [void][Runtime.InteropServices.NativeLibrary]::Load([IO.Path]::Combine($qnn, $so)) }
    $load = { param([string]$n, [object[]]$a) [scriptblock]::Create([IO.File]::ReadAllText([IO.Path]::Combine($root, 'modules', $n))).InvokeReturnAsIs($a) }
    $binding = & $load 'Native.Binding.psm1' @(); $abi = & $load 'Qnn.Abi.psm1' @($binding); $native = & $load 'Qnn.Native.psm1' @($abi); $graph = & $load 'Qnn.Graph.psm1' @($abi, $native); $ctx = & $load 'Qnn.Context.psm1' @($abi, $native, $graph)
    [void](& $native.Initialize ([pscustomobject]@{ DataRoot = $qnn; NativeLibraryDirectory = $dsp }))
    [void](& $ctx.SetPerformance 'burst')
    $st = $job.Gen
    $prof = & $ctx.NewProfile 7001
    $trial = & $ctx.LoadContext ([IO.Path]::Combine($root, $st.Context)) $st.GraphName $prof
    $arena = & $graph.NewArena
    try {
        $ins = @(foreach ($t in $st.Inputs) {
            $name = $t.Name; $file = if ($job.Files.Contains($name)) { $job.Files[$name] } else { 'in_x0.f32' }
            $d = & $ctx.BindTensor $arena $t.Id $name ([int]$abi.Enum.AppWrite) ([int]$abi.Enum.Float32) $t.Shape
            & $graph.NewExecTensor $arena $d ([IO.File]::ReadAllBytes([IO.Path]::Combine($root, $file)))
        })
        $o = $st.Output
        $od = & $ctx.BindTensor $arena $o.Id $o.Name ([int]$abi.Enum.AppRead) ([int]$abi.Enum.Float32) $o.Shape
        $eo = & $graph.NewExecTensor $arena $od ([byte[]]::new($o.Bytes))
        [void](& $graph.Execute $trial $arena ([object[]]$ins) ([object[]]@($eo)))                       # warm-up
        $p = & $ctx.ExecuteProfiled $trial ([object[]]$ins) ([object[]]@($eo)) 7001 $prof
        $lines.Add("WallMs=$($p.WallMs.ToString('F1')) TopEvents=$($p.Events.Count)")
        $flat = [Collections.Generic.List[object]]::new()
        $walk = { param($n, [string]$path) $flat.Add([pscustomobject]@{ Path = $path; Name = $n.Name; Type = $n.Type; Unit = $n.Unit; Value = $n.Value; Kids = $n.Children.Count }); foreach ($c in $n.Children) { & $walk $c ($path + '/' + $n.Name) } }
        foreach ($ev in $p.Events) { & $walk $ev '' }
        $csv = [Collections.Generic.List[string]]::new(); $csv.Add('path,name,type,unit,value,children')
        foreach ($r in $flat) { $csv.Add(('"{0}","{1}",{2},{3},{4},{5}' -f $r.Path, $r.Name, $r.Type, $r.Unit, $r.Value, $r.Kids)) }
        [IO.File]::WriteAllLines([IO.Path]::Combine($root, 'profile.csv'), $csv)
        $lines.Add("Events=$($flat.Count)")
        $lines.Add('Passed=True')
    }
    finally { [void](& $native.CloseTrial $trial); & $graph.FreeArena $arena }
}
catch { $lines.Add('Passed=False'); $lines.Add("Error=$($_.Exception.Message)"); $lines.Add("At=$($_.InvocationInfo.PositionMessage -replace '\s+', ' ')") }
[IO.File]::WriteAllLines([IO.Path]::Combine($root, 'receipt.txt'), $lines)
