#requires -Version 7.4
# Static issue bound for the inner loops of emitted HVX bodies. For every backward branch
# (one loop iteration) it reports the packets the body takes today (one instruction per
# packet), an estimate of HVX interlock stalls in that schedule, and two lower bounds for a
# packed schedule: resources and dependence chain. This is a bound, not a measurement; the
# phone PMU run measures the real packets and stalls.
#
# Resource and latency model: Hexagon V75 HVX PRM (SDK 6.4.0.2, tools/HEXAGON_Tools/19.0.04/
# Documents/v75 HVX Programmer Reference Manual.html), sections "VLIW packing rules",
# "HVX execution resource usage", "HVX instruction to Hexagon slots mapping" and
# "HVX slot/resource/latency summary". The V73 manual (80-N2040-54 Rev. AB) is the target
# reference and has not been compared line by line.
#   Pipes: two multiply, shift, permute. Load and store are separate resources.
#   Single-vector ALU: any one pipe, input latency 1.
#   Shift: shift pipe, latency 2. Cross-lane permute: permute pipe, latency 2.
#   Halfword (16-bit) multiply and double-vector multiply: both multiply pipes, latency 2.
#   Double-vector cross-lane (vshuff, vlut16 pair output): permute and shift, latency 2.
#   Aligned vector load or store: its own resource plus one of shift, permute or multiply.
#   Instructions that read a full scalar Rt use core slots 2 and 3; so do multiplies.
#   At most four instructions per packet; one vector load and one vector store.
[CmdletBinding()]
param(
    [ValidateSet('AdaInSnakeInteger','AdaInSnakeTurns','AdaInStatisticsAccumulate','ResidualInteger','BranchAverageInteger','AdaInMoments16','PlaneCombineConv','PlaneCombineResidual')]
    [string[]] $Body = @('AdaInSnakeInteger','AdaInSnakeTurns','AdaInStatisticsAccumulate','ResidualInteger','BranchAverageInteger','AdaInMoments16','PlaneCombineConv','PlaneCombineResidual')
)
$ErrorActionPreference='Stop'
$emit=Join-Path $PSScriptRoot '..\src\emit'
. (Join-Path $emit 'Hexagon.ps1')
foreach($f in 'Kokoro.AdaInSnakeInteger.ps1','Kokoro.AdaInSnakeTurns.ps1','Kokoro.AdaInStatisticsAccumulate.ps1','Kokoro.ResidualInteger.ps1','Kokoro.BranchAverageInteger.ps1','Kokoro.AdaInMoments16.ps1','Kokoro.PlaneCombine.ps1'){ . (Join-Path $emit $f) }

# Op -> class. Fields that hold vector registers are listed per class below.
$class=@{}
foreach($o in 'vadd-w','vsub-w','vand','vor','vxor','vmin-w','vmax-w','vmin-h','vmax-h','vadd-h','vadd-h-sat','vsub-h','vabs-h-sat'){ $class[$o]='alu' }
foreach($o in 'vsplat','vsplat-h'){ $class[$o]='alu-rt' }
foreach($o in 'vlsr-uw','vasr-w','vasl-w','vasr-h','vasl-h'){ $class[$o]='shift-rt' }
foreach($o in 'vmpyie-w-uh','vmpye-w-uh','vmpy-h-rnd-sat'){ $class[$o]='mpy2' }
foreach($o in 'vmpyo-acc-w-h-rnd-sat-shift'){ $class[$o]='mpy2-acc' }
foreach($o in 'vmpy-acc-ww-h-h'){ $class[$o]='mpy2-acc-pair' }
foreach($o in 'vmpy-acc-ww-h-r'){ $class[$o]='mpy2-acc-pair-rt' }
foreach($o in 'valign','valign-imm'){ $class[$o]='perm' }
foreach($o in 'vshuff'){ $class[$o]='perm2' }
foreach($o in 'vlut16'){ $class[$o]='lut' }
foreach($o in 'vlut16-or'){ $class[$o]='lut-acc' }
foreach($o in 'vload','vload-post'){ $class[$o]='vload' }
foreach($o in 'vstore','vstore-post'){ $class[$o]='vstore' }

function Get-Use {
    # Vector registers read and written, input latency of the result, resources.
    param([hashtable]$x)
    $c=$class[$x.Op]
    $r=@{Read=@();Write=@();Latency=1;Pipe=$null;Load=0;Store=0;Rt=$false;Vector=$true}
    switch($c){
        'alu'      { $r.Read=@($x.s,$x.t); $r.Write=@($x.d); $r.Pipe='any' }
        'alu-rt'   { $r.Write=@($x.d); $r.Pipe='any'; $r.Rt=$true }
        'shift-rt' { $r.Read=@($x.s); $r.Write=@($x.d); $r.Pipe='shift'; $r.Latency=2; $r.Rt=$true }
        'mpy2'     { $r.Read=@($x.s,$x.t); $r.Write=@($x.d); $r.Pipe='mpy2'; $r.Latency=2; $r.Rt=$true }
        'mpy2-acc' { $r.Read=@($x.s,$x.t,$x.d); $r.Write=@($x.d); $r.Pipe='mpy2'; $r.Latency=2; $r.Rt=$true }
        'mpy2-acc-pair'    { $r.Read=@($x.s,$x.t,$x.d,($x.d+1)); $r.Write=@($x.d,($x.d+1)); $r.Pipe='mpy2'; $r.Latency=2; $r.Rt=$true }
        'mpy2-acc-pair-rt' { $r.Read=@($x.s,$x.d,($x.d+1)); $r.Write=@($x.d,($x.d+1)); $r.Pipe='mpy2'; $r.Latency=2; $r.Rt=$true }
        'perm'     { $r.Read=@($x.s,$x.t); $r.Write=@($x.d); $r.Pipe='perm'; $r.Latency=2 }
        'perm2'    { $r.Read=@($x.s,$x.t); $r.Write=@($x.d,($x.d+1)); $r.Pipe='perm2'; $r.Latency=2; $r.Rt=$true }
        'lut'      { $r.Read=@($x.s,$x.v); $r.Write=@($x.d,($x.d+1)); $r.Pipe='perm2'; $r.Latency=2; $r.Rt=$true }
        'lut-acc'  { $r.Read=@($x.s,$x.v,$x.d,($x.d+1)); $r.Write=@($x.d,($x.d+1)); $r.Pipe='perm2'; $r.Latency=2; $r.Rt=$true }
        'vload'    { $r.Write=@($x.d); $r.Pipe='mem'; $r.Load=1; $r.Latency=1 }
        'vstore'   { $r.Read=@($x.t); $r.Pipe='mem'; $r.Store=1 }
        default    { $r.Vector=$false }
    }
    $r
}

function Get-Bodies {
    $b=[ordered]@{}
    foreach($n in $Body){
        $b[$n]=switch($n){
            'AdaInSnakeInteger'         { @(New-KokoroAdaInSnakeIntegerSteps) }
            'AdaInSnakeTurns'           { @(New-KokoroAdaInSnakeTurnsSteps) }
            'AdaInStatisticsAccumulate' { @(New-KokoroAdaInStatisticsAccumulateSteps) }
            'ResidualInteger'           { @(New-KokoroResidualIntegerSteps) }
            'BranchAverageInteger'      { @(New-KokoroBranchAverageIntegerSteps) }
            'AdaInMoments16'            { @(New-KokoroAdaInMoments16Steps -Channels 128) }
            'PlaneCombineConv'          { @(New-KokoroPlaneCombineSteps -Mode Conv -Channels 128 -Groups 3 -PlaneStride 24576) }
            'PlaneCombineResidual'      { @(New-KokoroPlaneCombineSteps -Mode Residual -Channels 128 -Groups 3 -PlaneStride 24576) }
        }
    }
    $b
}

$rows=foreach($e in (Get-Bodies).GetEnumerator()){
    $st=$e.Value; $lab=@{}
    for($i=0;$i -lt $st.Count;$i++){ if($st[$i].Op -eq 'label'){ $lab[$st[$i].Name]=$i } }
    for($i=0;$i -lt $st.Count;$i++){
        $j=$st[$i]; if($j.Op -ne 'jump-p' -or -not $lab.ContainsKey($j.Label) -or $lab[$j.Label] -ge $i){ continue }
        $loop=@($st[($lab[$j.Label]+1)..$i] | Where-Object { $_.Op -ne 'label' })
        # Innermost loops only: skip a loop that contains another backward branch.
        if(@($loop | Where-Object { $_.Op -eq 'jump-p' }).Count -gt 1){ continue }
        $n=$loop.Count; $vec=0; $any=0; $shift=0; $perm=0; $mpy2=0; $perm2=0; $mem=0; $ld=0; $sto=0; $rt=0; $scalar=0
        $ready=@{}; $chain=0; $stall=0; $cycle=0
        foreach($x in $loop){
            $u=Get-Use $x
            if(-not $u.Vector){ $scalar++; $cycle++; continue }
            $vec++
            switch($u.Pipe){ 'any'{$any++} 'shift'{$shift++} 'perm'{$perm++} 'mpy2'{$mpy2++} 'perm2'{$perm2++} 'mem'{$mem++} }
            $ld+=$u.Load; $sto+=$u.Store
            if($u.Rt -or $u.Pipe -eq 'mpy2'){ $rt++ }
            # Dependence: earliest packet this op can issue in a packed schedule (chain), and
            # the stall it sees in today's one-instruction-per-packet schedule.
            $start=0; $need=$cycle
            foreach($v in $u.Read){ if($ready.ContainsKey("c$v")){ $start=[math]::Max($start,$ready["c$v"]) ; $need=[math]::Max($need,$ready["s$v"]) } }
            if($need -gt $cycle){ $stall+=$need-$cycle; $cycle=$need }
            foreach($v in $u.Write){ $ready["c$v"]=$start+$u.Latency; $ready["s$v"]=$cycle+$u.Latency }
            $chain=[math]::Max($chain,$start+1); $cycle++
        }
        $pipeSlots=$any+$shift+$perm+2*$mpy2+2*$perm2+$mem
        $resource=[math]::Max([math]::Ceiling($n/4),[math]::Max([math]::Ceiling($pipeSlots/4),[math]::Max($ld,[math]::Max($sto,[math]::Max($mpy2,[math]::Max($shift+$perm2,[math]::Max($perm+$perm2,[math]::Ceiling($rt/2))))))))
        [pscustomobject]@{
            Body=$e.Key; Loop="$($lab[$j.Label])-$i"; Instructions=$n; Hvx=$vec; Scalar=$scalar
            Any=$any; Shift=$shift; Perm=$perm; Mpy2=$mpy2; Perm2=$perm2; Load=$ld; Store=$sto
            Today=$n+$stall; Stalls=$stall; ResourceBound=$resource; ChainBound=$chain
            Headroom=[math]::Round(($n+$stall)/[math]::Max($resource,1),2)
        }
    }
}
$rows | Sort-Object Body,Loop -Unique | Format-Table Body,Loop,Instructions,Hvx,Scalar,Any,Shift,Perm,Mpy2,Perm2,Load,Store,Stalls,Today,ResourceBound,ChainBound,Headroom -AutoSize | Out-String -Width 220
