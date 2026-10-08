#requires -Version 7.4
# VLIW packet scheduling for straight-line Hexagon V73 code produced by our emitters.
#
# Packing rules, Hexagon V75 PRM and V75 HVX PRM as shipped in SDK 6.4.0.2
# (tools/HEXAGON_Tools/19.0.04/Documents); the V73 manuals 80-N2040-53/54 Rev. AB are the target
# references and have not been compared line by line:
#   - at most four instructions per packet; one vector load and one vector store;
#   - instructions are encoded in strictly decreasing slot order (slot 3 at the lowest address),
#     an instruction moves to a higher free slot it can use, and a single load or store goes in
#     slot 0 ("Ordering constraints");
#   - slots: ALU32 any; XTYPE (shift-immediate, 64-bit add/sub) 2-3; loads 0-1; stores 0-1;
#     J 2-3; HVX aligned load 0-1, aligned store 0; HVX instructions that read a full scalar Rt
#     (lookup, splat) and HVX multiplies 2-3; other HVX any, shifts by Rt included ("HVX instruction to Hexagon slots mapping");
#   - HVX pipes: two multiply, shift, permute. Single-vector ALU any one; shift the shift pipe;
#     cross-lane permute the permute pipe; double-vector cross-lane permute shift and permute;
#     halfword multiplies both multiply pipes; aligned vector load or store one of shift,
#     permute or multiply ("HVX execution resource usage").
#   - registers are read at the start of a packet and written at its end, so an instruction
#     cannot use a result produced in the same packet (no .new forms are emitted), and two
#     instructions of a packet never write the same register.
# Scheduling: list scheduling within a region (labels, branches and calls bound regions);
# memory operations keep program order, and a load after a store goes in a later packet.
# Priority is the longest latency-weighted path to the region end (HVX multiply, shift and
# permute results have input latency 2, the rest 1).
#
# The result is a step list in packet order; every step but the last of a packet carries
# Packed = $true, which the encoder writes as parse bits 01 (not end of packet).

$script:HexagonPacketInfo = @{}
function Set-HexagonPacketInfo { param([string[]]$Ops,[hashtable]$Info) foreach($o in $Ops){ $script:HexagonPacketInfo[$o]=$Info } }
# Kind: alu32 | xtype | load | store | jump | hvx. Slots as a bit mask (bit n = slot n).
Set-HexagonPacketInfo @('add','addi','sub','and','or','xor','imm','lo','hi','eq','gtu') @{Kind='alu32';Slots=0xF}
Set-HexagonPacketInfo @('lsr-i','asl-i','asr-i','add-d','sub-d','max','min') @{Kind='xtype';Slots=0xC}
Set-HexagonPacketInfo @('load','load-ub','load-d') @{Kind='load';Slots=0x3}
Set-HexagonPacketInfo @('store','store-h','store-d') @{Kind='store';Slots=0x3}
Set-HexagonPacketInfo @('jump-p') @{Kind='jump';Slots=0xC}
Set-HexagonPacketInfo @('vadd-w','vsub-w','vand','vor','vxor','vmin-w','vmax-w','vadd-h','vadd-h-sat','vsub-h','vabs-h-sat') @{Kind='hvx';Slots=0xF;Pipe='any';Latency=1}
Set-HexagonPacketInfo @('vsplat','vsplat-h') @{Kind='hvx';Slots=0xC;Pipe='any';Latency=1}
# Shifts by Rt use its low bits only and are not in the full-Rt subset: any slot (SDK 6.4.0.2
# hexagon-llvm-mc places v9.uw = vlsr(v8.uw,r9) in slot 1).
Set-HexagonPacketInfo @('vlsr-uw','vasr-w','vasl-w','vasr-h','vasl-h') @{Kind='hvx';Slots=0xF;Pipe='shift';Latency=2}
Set-HexagonPacketInfo @('vmpyie-w-uh','vmpye-w-uh','vmpy-h-rnd-sat','vmpyo-acc-w-h-rnd-sat-shift','vmpy-acc-ww-h-h','vmpy-acc-ww-h-r') @{Kind='hvx';Slots=0xC;Pipe='mpy2';Latency=2}
Set-HexagonPacketInfo @('valign-imm') @{Kind='hvx';Slots=0xF;Pipe='perm';Latency=2}
Set-HexagonPacketInfo @('vlut16','vlut16-or') @{Kind='hvx';Slots=0xC;Pipe='perm2';Latency=2}
Set-HexagonPacketInfo @('vload') @{Kind='hvx';Slots=0x3;Pipe='mem';Latency=1;VLoad=$true}
Set-HexagonPacketInfo @('vstore') @{Kind='hvx';Slots=0x1;Pipe='mem';Latency=1;VStore=$true}

function Get-HexagonStepUse {
    # Registers read and written: 'r<n>', 'v<n>', 'p<n>'.
    param([hashtable]$x)
    $r=[Collections.Generic.List[string]]::new(); $w=[Collections.Generic.List[string]]::new()
    switch($x.Op){
        { $_ -in 'add','sub','and','or','xor','gtu','eq','max','min' } { $r.Add("r$($x.s)"); $r.Add("r$($x.t)"); if($x.Op -in 'eq','gtu'){ $w.Add("p$($x.d)") } else { $w.Add("r$($x.d)") } }
        { $_ -in 'addi','lsr-i','asl-i','asr-i' } { $r.Add("r$($x.s)"); $w.Add("r$($x.d)") }
        'imm' { $w.Add("r$($x.d)") }
        { $_ -in 'lo','hi' } { $r.Add("r$($x.x)"); $w.Add("r$($x.x)") }
        { $_ -in 'add-d','sub-d' } { foreach($q in $x.s,($x.s+1),$x.t,($x.t+1)){ $r.Add("r$q") }; $w.Add("r$($x.d)"); $w.Add("r$($x.d+1)") }
        { $_ -in 'load','load-ub' } { $r.Add("r$($x.s)"); $w.Add("r$($x.d)") }
        'load-d' { $r.Add("r$($x.s)"); $w.Add("r$($x.d)"); $w.Add("r$($x.d+1)") }
        { $_ -in 'store','store-h' } { $r.Add("r$($x.s)"); $r.Add("r$($x.t)") }
        'store-d' { $r.Add("r$($x.s)"); $r.Add("r$($x.t)"); $r.Add("r$($x.t+1)") }
        'jump-p' { $r.Add("p$($x.u)") }
        { $_ -in 'vadd-w','vsub-w','vand','vor','vxor','vmin-w','vmax-w','vadd-h','vadd-h-sat','vsub-h','vmpyie-w-uh','vmpye-w-uh','vmpy-h-rnd-sat','valign-imm' } { $r.Add("v$($x.s)"); $r.Add("v$($x.t)"); $w.Add("v$($x.d)") }
        'vabs-h-sat' { $r.Add("v$($x.s)"); $w.Add("v$($x.d)") }
        { $_ -in 'vsplat','vsplat-h' } { $r.Add("r$($x.s)"); $w.Add("v$($x.d)") }
        { $_ -in 'vlsr-uw','vasr-w','vasl-w','vasr-h','vasl-h' } { $r.Add("v$($x.s)"); $r.Add("r$($x.t)"); $w.Add("v$($x.d)") }
        'vmpyo-acc-w-h-rnd-sat-shift' { $r.Add("v$($x.s)"); $r.Add("v$($x.t)"); $r.Add("v$($x.d)"); $w.Add("v$($x.d)") }
        'vmpy-acc-ww-h-h' { $r.Add("v$($x.s)"); $r.Add("v$($x.t)"); foreach($q in $x.d,($x.d+1)){ $r.Add("v$q"); $w.Add("v$q") } }
        'vmpy-acc-ww-h-r' { $r.Add("v$($x.s)"); $r.Add("r$($x.t)"); foreach($q in $x.d,($x.d+1)){ $r.Add("v$q"); $w.Add("v$q") } }
        { $_ -in 'vlut16','vlut16-or' } { $r.Add("v$($x.s)"); $r.Add("v$($x.v)"); $r.Add("r$($x.x)"); if($x.Op -eq 'vlut16-or'){ $r.Add("v$($x.d)"); $r.Add("v$($x.d+1)") }; $w.Add("v$($x.d)"); $w.Add("v$($x.d+1)") }
        'vload' { $r.Add("r$($x.s)"); $w.Add("v$($x.d)") }
        'vstore' { $r.Add("r$($x.s)"); $r.Add("v$($x.t)") }
        default { throw "No packet model for $($x.Op)" }
    }
    [pscustomobject]@{Read=$r;Write=$w}
}

function Test-HexagonPacketResources {
    # True when the HVX pipes can serve the packet: two multiply, shift, permute.
    param([object[]]$Info)
    $mpy=0;$shift=0;$perm=0;$any=0
    foreach($i in $Info){ switch($i.Pipe){ 'mpy2'{$mpy+=2} 'shift'{$shift++} 'perm'{$perm++} 'perm2'{$shift++;$perm++} { $_ -in 'any','mem' }{$any++} } }
    if($mpy -gt 2 -or $shift -gt 1 -or $perm -gt 1){ return $false }
    ($mpy+$shift+$perm+$any) -le 4
}

function Get-HexagonSlotOrder {
    # Slot assignment for one packet, or $null. Instructions take the highest free slot they
    # can use, in order of fewest allowed slots, then scalar before vector, then program
    # order; a single load or store takes slot 0. Returns indexes in encoding order.
    param([object[]]$Info)
    $n=$Info.Count; $mem=@($Info | Where-Object { $_.Kind -in 'load','store' -or $_.VLoad -or $_.VStore }).Count
    $order=0..($n-1) | Sort-Object @{Expression={ $m=$Info[$_].Slots; if($mem -eq 1 -and ($Info[$_].Kind -in 'load','store' -or $Info[$_].VLoad -or $Info[$_].VStore)){$m=0x1}; [Numerics.BitOperations]::PopCount([uint32]$m) }}, @{Expression={ if($Info[$_].Kind -eq 'hvx'){1}else{0} }}, @{Expression={$_}}
    $slotOf=@{}; $used=0
    $assign={ param([int]$at)
        if($at -ge $n){ return $true }
        $k=$order[$at]; $m=$Info[$k].Slots
        if($mem -eq 1 -and ($Info[$k].Kind -in 'load','store' -or $Info[$k].VLoad -or $Info[$k].VStore)){ $m=0x1 }
        for($slot=3;$slot -ge 0;$slot--){
            if(($m -band (1 -shl $slot)) -and -not ($script:usedSlots -band (1 -shl $slot))){
                $script:usedSlots=$script:usedSlots -bor (1 -shl $slot); $slotOf[$k]=$slot
                if(& $assign ($at+1)){ return $true }
                $script:usedSlots=$script:usedSlots -band -bnot (1 -shl $slot)
            }
        }
        $false
    }
    $script:usedSlots=0
    if(-not (& $assign 0)){ return $null }
    @(0..($n-1) | Sort-Object { -$slotOf[$_] })
}

function Test-HexagonPacket {
    param([object[]]$Info)
    if($Info.Count -gt 4){ return $false }
    if(@($Info | Where-Object VLoad).Count -gt 1 -or @($Info | Where-Object VStore).Count -gt 1){ return $false }
    if(@($Info | Where-Object { $_.Kind -in 'load','store' -or $_.VLoad -or $_.VStore }).Count -gt 1){ return $false }
    if(@($Info | Where-Object { $_.Kind -eq 'jump' }).Count -gt 1){ return $false }
    if(-not (Test-HexagonPacketResources @($Info | Where-Object { $_.Kind -eq 'hvx' }))){ return $false }
    $null -ne (Get-HexagonSlotOrder $Info)
}

function Optimize-HexagonPackets {
    # Packs every straight-line region of Steps; labels, branches (which close their region)
    # and any operation without a packet model stay where they are.
    param([Parameter(Mandatory)][object[]]$Steps)
    $out=[Collections.Generic.List[hashtable]]::new()
    $region=[Collections.Generic.List[hashtable]]::new()
    $flush={
        if($region.Count -eq 0){ return }
        $packs=Get-HexagonRegionPackets $region.ToArray()
        foreach($p in $packs){ for($i=0;$i -lt $p.Count;$i++){ $c=$p[$i].Clone(); if($i -lt $p.Count-1){ $c.Packed=$true }; $out.Add($c) } }
        $region.Clear()
    }
    foreach($x in $Steps){
        if($x.Op -eq 'label' -or -not $script:HexagonPacketInfo.ContainsKey($x.Op)){ & $flush; $out.Add($x); continue }
        $region.Add($x)
        if($x.Op -eq 'jump-p'){ & $flush }
    }
    & $flush
    $out.ToArray()
}

function Get-HexagonRegionPackets {
    param([hashtable[]]$Region)
    $n=$Region.Count
    $info=@(foreach($x in $Region){ $script:HexagonPacketInfo[$x.Op] })
    $use=@(foreach($x in $Region){ Get-HexagonStepUse $x })
    # Dependence edges j -> i (j before i): kind 'after' (later packet, with latency) or 'same'
    # (same packet or later: a write after a read).
    $preds=[object[]]::new($n); for($i=0;$i -lt $n;$i++){ $preds[$i]=[Collections.Generic.List[object]]::new() }
    $lastWrite=@{}; $readsSince=@{}; $lastMem=-1
    for($i=0;$i -lt $n;$i++){
        foreach($reg in $use[$i].Read){ if($lastWrite.ContainsKey($reg)){ $j=$lastWrite[$reg]; $preds[$i].Add(@{From=$j;Gap=$(if($info[$j].Latency){$info[$j].Latency}else{1})}) } }
        foreach($reg in $use[$i].Write){
            if($lastWrite.ContainsKey($reg)){ $preds[$i].Add(@{From=$lastWrite[$reg];Gap=1}) }
            if($readsSince.ContainsKey($reg)){ foreach($j in $readsSince[$reg]){ if($j -ne $i){ $preds[$i].Add(@{From=$j;Gap=0}) } } }
        }
        $isMem=$info[$i].Kind -in 'load','store' -or $info[$i].VLoad -or $info[$i].VStore
        if($isMem){
            if($lastMem -ge 0){ $preds[$i].Add(@{From=$lastMem;Gap=1}) }
            $lastMem=$i
        }
        if($Region[$i].Op -eq 'jump-p'){ for($j=0;$j -lt $i;$j++){ $preds[$i].Add(@{From=$j;Gap=0}) } }
        foreach($reg in $use[$i].Read){ if(-not $readsSince.ContainsKey($reg)){ $readsSince[$reg]=[Collections.Generic.List[int]]::new() }; $readsSince[$reg].Add($i) }
        foreach($reg in $use[$i].Write){ $lastWrite[$reg]=$i; $readsSince[$reg]=[Collections.Generic.List[int]]::new() }
    }
    # Priority: longest latency path to the end.
    $height=[int[]]::new($n)
    $succ=[object[]]::new($n); for($i=0;$i -lt $n;$i++){ $succ[$i]=[Collections.Generic.List[object]]::new() }
    for($i=0;$i -lt $n;$i++){ foreach($e in $preds[$i]){ $succ[$e.From].Add(@{To=$i;Gap=$e.Gap}) } }
    for($i=$n-1;$i -ge 0;$i--){ $h=1; foreach($e in $succ[$i]){ $h=[math]::Max($h,$height[$e.To]+[math]::Max($e.Gap,0)) }; $height[$i]=$h }
    $packetOf=[int[]]::new($n); for($i=0;$i -lt $n;$i++){ $packetOf[$i]=-1 }
    $packets=[Collections.Generic.List[object]]::new(); $placed=0; $cycle=0
    while($placed -lt $n){
        $members=[Collections.Generic.List[int]]::new()
        $ready={ param([int]$i)
            if($packetOf[$i] -ge 0 -or $members.Contains($i)){ return $false }
            foreach($e in $preds[$i]){
                $j=$e.From
                if($members.Contains($j)){ if($e.Gap -gt 0){ return $false }; continue }
                if($packetOf[$j] -lt 0){ return $false }
                if($e.Gap -gt 0 -and $packetOf[$j] -ge $cycle){ return $false }
            }
            $true
        }
        $progress=$true
        while($progress -and $members.Count -lt 4){
            $progress=$false
            $cands=@(0..($n-1) | Where-Object { & $ready $_ } | Sort-Object @{Expression={$height[$_]};Descending=$true}, @{Expression={$_}})
            foreach($c in $cands){
                $trial=@($members)+$c
                if(Test-HexagonPacket @($trial | ForEach-Object { $info[$_] })){ $members.Add($c); $progress=$true; break }
            }
        }
        if($members.Count -eq 0){ throw 'Packet scheduler made no progress' }
        foreach($m in $members){ $packetOf[$m]=$cycle }
        $placed+=$members.Count
        $infos=@($members | ForEach-Object { $info[$_] })
        $slotOrder=Get-HexagonSlotOrder $infos
        $packets.Add([hashtable[]]@($slotOrder | ForEach-Object { $Region[$members[$_]] }))
        $cycle++
    }
    ,$packets.ToArray()
}
