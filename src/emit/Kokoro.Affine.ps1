# V73 backend for the two-node AdaIN affine DAG. Method 2 fuses both nodes;
# methods 3 and 4 provide identical-arithmetic separate passes for comparison.
# All registers are caller-saved r0-r15/p0; no frame, imports or relocations.
function New-KokoroAffineSteps {
    param([Parameter(Mandatory)] $Nodes, [int] $Frames=7681, [int] $Channels=128,
        [int] $GainOffset=1182720, [int] $ShiftOffset=1183232, [int] $WeightBytes=1195008)
    if($Frames -le 0 -or $Frames -gt 19201 -or $Channels -ne 128 -or
        $GainOffset -lt 0 -or $ShiftOffset -lt 0 -or $GainOffset%4 -or $ShiftOffset%4 -or
        [long]$GainOffset+4*$Channels -gt $WeightBytes -or [long]$ShiftOffset+4*$Channels -gt $WeightBytes) { throw 'Invalid affine specialization' }
    if($Nodes.Count -ne 2 -or $Nodes[0].Op -cne 'Mul' -or $Nodes[1].Op -cne 'Add' -or
        ($Nodes[0].Inputs -join ',') -cne '@normalized,@gain' -or
        ($Nodes[1].Inputs -join ',') -cne '%0,@shift' -or $Nodes[0].Attrs.Count -or $Nodes[1].Attrs.Count) {
        throw 'This backend accepts only normalized * gain + shift; unsupported DAG'
    }
    $steps=[Collections.Generic.List[hashtable]]::new()
    $imm={param([int]$Register,[uint32]$Value)
        $steps.Add(@{Op='lo';x=$Register;i=($Value -band 65535)})
        $steps.Add(@{Op='hi';x=$Register;i=($Value -shr 16)})
    }
    foreach($dispatch in @(@(0x00020001,'open'),@(0x01000010,'success'),
        @(0x02030100,'fused'),@(0x03030100,'multiply'),@(0x04030100,'shift'),@(0x05030100,'lengths'))) {
        & $imm 4 $dispatch[0]
        $steps.Add(@{Op='eq';d=0;s=2;t=4}); $steps.Add(@{Op='jump-p';u=0;Label=$dispatch[1]})
    }
    $steps.Add(@{Op='imm';d=0;i=20}); $steps.Add(@{Op='return'})
    $steps.Add(@{Op='label';Name='open'})
    $steps.Add(@{Op='imm';d=4;i=0})
    $steps.Add(@{Op='eq';d=0;s=3;t=4}); $steps.Add(@{Op='jump-p';u=0;Label='bad'})
    $steps.Add(@{Op='imm';d=4;i=1}); $steps.Add(@{Op='store';s=3;t=4;Offset=16})
    $steps.Add(@{Op='imm';d=4;i=0}); $steps.Add(@{Op='store';s=3;t=4;Offset=20})
    $steps.Add(@{Op='label';Name='success'})
    $steps.Add(@{Op='imm';d=0;i=0}); $steps.Add(@{Op='return'})
    $steps.Add(@{Op='label';Name='bad'})
    $steps.Add(@{Op='imm';d=0;i=14}); $steps.Add(@{Op='return'})
    $steps.Add(@{Op='label';Name='lengths'})
    $steps.Add(@{Op='imm';d=15;i=0})
    $steps.Add(@{Op='eq';d=0;s=3;t=15}); $steps.Add(@{Op='jump-p';u=0;Label='bad'})
    $steps.Add(@{Op='load';d=4;s=3;Offset=28})
    $steps.Add(@{Op='imm';d=5;i=15})
    $steps.Add(@{Op='gtu';d=0;s=4;t=5}); $steps.Add(@{Op='jump-p';u=0;Label='lengths_valid'})
    $steps.Add(@{Op='imm';d=0;i=14}); $steps.Add(@{Op='return'})
    $steps.Add(@{Op='label';Name='lengths_valid'})
    $steps.Add(@{Op='load';d=6;s=3;Offset=24})
    $steps.Add(@{Op='eq';d=0;s=6;t=15}); $steps.Add(@{Op='jump-p';u=0;Label='bad'})
    for($argIndex=0;$argIndex -lt 4;$argIndex++) {
        $steps.Add(@{Op='load';d=4;s=3;Offset=(8*$argIndex+4)})
        $steps.Add(@{Op='store';s=6;t=4;Offset=(4*$argIndex)})
    }
    $steps.Add(@{Op='imm';d=0;i=0}); $steps.Add(@{Op='return'})
    foreach($mode in 'fused','multiply','shift') {
        $steps.Add(@{Op='label';Name=$mode})
        $steps.Add(@{Op='imm';d=15;i=0})
        $steps.Add(@{Op='eq';d=0;s=3;t=15}); $steps.Add(@{Op='jump-p';u=0;Label='bad'})
        # remote_arg[]: geometry {T,C}, normalized tensor, unchanged static weights, output.
        $tensorBytes=4*$Frames*$Channels
        foreach($arg in @(@(4,8),@(12,$tensorBytes),@(20,$WeightBytes),@(28,$tensorBytes))) {
            $steps.Add(@{Op='load';d=4;s=3;Offset=$arg[0]})
            & $imm 5 ([uint32]($arg[1]-1))
            $steps.Add(@{Op='gtu';d=0;s=4;t=5})
            $label="${mode}_length_$($arg[0])"
            $steps.Add(@{Op='jump-p';u=0;Label=$label})
            $steps.Add(@{Op='imm';d=0;i=14}); $steps.Add(@{Op='return'})
            $steps.Add(@{Op='label';Name=$label})
        }
        foreach($arg in @(@(0,7),@(8,4),@(16,5),@(24,6))) {
            $steps.Add(@{Op='load';d=$arg[1];s=3;Offset=$arg[0]})
            $steps.Add(@{Op='eq';d=0;s=$arg[1];t=15}); $steps.Add(@{Op='jump-p';u=0;Label='bad'})
        }
        foreach($dim in @(@(0,$Frames),@(4,$Channels))) {
            $steps.Add(@{Op='load';d=8;s=7;Offset=$dim[0]}); & $imm 9 $dim[1]
            $steps.Add(@{Op='eq';d=0;s=8;t=9})
            $label="${mode}_dimension_$($dim[0])"
            $steps.Add(@{Op='jump-p';u=0;Label=$label})
            $steps.Add(@{Op='imm';d=0;i=14}); $steps.Add(@{Op='return'})
            $steps.Add(@{Op='label';Name=$label})
        }
        & $imm 9 $GainOffset; $steps.Add(@{Op='add';d=9;s=5;t=9})
        & $imm 10 $ShiftOffset; $steps.Add(@{Op='add';d=10;s=5;t=10})
        $steps.Add(@{Op='imm';d=8;i=$Channels})
        $steps.Add(@{Op='label';Name="${mode}_channel"})
        if($mode -ne 'shift') { $steps.Add(@{Op='load';d=11;s=9;Offset=0}) }
        if($mode -ne 'multiply') { $steps.Add(@{Op='load';d=12;s=10;Offset=0}) }
        $steps.Add(@{Op='imm';d=7;i=$Frames})
        $steps.Add(@{Op='label';Name="${mode}_sample"})
        $steps.Add(@{Op='load';d=13;s=4;Offset=0})
        if($mode -ne 'shift') { $steps.Add(@{Op='sfmpy';d=13;s=13;t=11}) }
        if($mode -ne 'multiply') { $steps.Add(@{Op='sfadd';d=13;s=13;t=12}) }
        $steps.Add(@{Op='store';s=6;t=13;Offset=0})
        $steps.Add(@{Op='addi';d=4;s=4;i=4}); $steps.Add(@{Op='addi';d=6;s=6;i=4})
        $steps.Add(@{Op='addi';d=7;s=7;i=-1})
        $steps.Add(@{Op='gtu';d=0;s=7;t=15}); $steps.Add(@{Op='jump-p';u=0;Label="${mode}_sample"})
        $steps.Add(@{Op='addi';d=9;s=9;i=4}); $steps.Add(@{Op='addi';d=10;s=10;i=4})
        $steps.Add(@{Op='addi';d=8;s=8;i=-1})
        $steps.Add(@{Op='gtu';d=0;s=8;t=15}); $steps.Add(@{Op='jump-p';u=0;Label="${mode}_channel"})
        $steps.Add(@{Op='imm';d=0;i=0}); $steps.Add(@{Op='return'})
    }
    $steps.ToArray()
}
