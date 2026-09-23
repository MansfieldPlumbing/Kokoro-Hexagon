# Scalar V73 convolution baseline. Separate sfmpy/sfadd rounding; tap-major
# accumulation. Uses only caller-saved r0-r15/p0 and the existing ISA encoders.
function New-KokoroConvTileSteps {
    param([Parameter(Mandatory)]$Nodes, [int]$Frames=65, [int]$Channels=128,
        [int]$WeightOffset=0, [int]$BiasOffset=196608, [int]$WeightBytes=1195008)
    if($Frames -lt 1 -or $Frames -gt 256 -or $Channels -ne 128 -or
        $WeightOffset -lt 0 -or $BiasOffset -lt 0 -or $WeightOffset%4 -or $BiasOffset%4 -or
        [long]$WeightOffset+3*128*128*4 -gt $WeightBytes -or [long]$BiasOffset+128*4 -gt $WeightBytes) {
        throw 'Invalid convolution tile specialization'
    }
    if($Nodes.Count -ne 2 -or $Nodes[0].Op -cne 'Conv1D' -or $Nodes[1].Op -cne 'Add' -or
        ($Nodes[0].Inputs -join ',') -cne '@halo,@weight' -or ($Nodes[1].Inputs -join ',') -cne '%0,@bias' -or
        $Nodes[0].Attrs.Count -ne 3 -or $Nodes[0].Attrs.Kernel -cne '3' -or
        $Nodes[0].Attrs.Stride -cne '1' -or $Nodes[0].Attrs.Dilation -cne '1' -or $Nodes[1].Attrs.Count) {
        throw 'Unsupported convolution DAG'
    }
    $s=[Collections.Generic.List[hashtable]]::new()
    $imm={param([int]$r,[uint32]$v) $s.Add(@{Op='lo';x=$r;i=($v -band 65535)}); $s.Add(@{Op='hi';x=$r;i=($v -shr 16)})}
    foreach($d in @(@(0x00020001,'open'),@(0x01000010,'success'),@(0x02030100,'conv'))) {
        & $imm 4 $d[0]; $s.Add(@{Op='eq';d=0;s=2;t=4}); $s.Add(@{Op='jump-p';u=0;Label=$d[1]})
    }
    $s.Add(@{Op='imm';d=0;i=20}); $s.Add(@{Op='return'})
    $s.Add(@{Op='label';Name='bad'}); $s.Add(@{Op='imm';d=0;i=14}); $s.Add(@{Op='return'})
    $s.Add(@{Op='label';Name='open'}); $s.Add(@{Op='imm';d=4;i=0})
    $s.Add(@{Op='eq';d=0;s=3;t=4}); $s.Add(@{Op='jump-p';u=0;Label='bad'})
    $s.Add(@{Op='imm';d=4;i=1}); $s.Add(@{Op='store';s=3;t=4;Offset=16})
    $s.Add(@{Op='imm';d=4;i=0}); $s.Add(@{Op='store';s=3;t=4;Offset=20})
    $s.Add(@{Op='label';Name='success'}); $s.Add(@{Op='imm';d=0;i=0}); $s.Add(@{Op='return'})
    $s.Add(@{Op='label';Name='conv'}); $s.Add(@{Op='imm';d=15;i=0})
    $s.Add(@{Op='eq';d=0;s=3;t=15}); $s.Add(@{Op='jump-p';u=0;Label='bad'})
    $inputBytes=4*($Frames+2)*$Channels; $outputBytes=4*$Frames*$Channels
    foreach($a in @(@(4,8),@(12,$inputBytes),@(20,$WeightBytes),@(28,$outputBytes))) {
        $s.Add(@{Op='load';d=0;s=3;Offset=$a[0]}); & $imm 1 ($a[1]-1)
        $s.Add(@{Op='gtu';d=0;s=0;t=1}); $s.Add(@{Op='jump-p';u=0;Label="length_$($a[0])"})
        $s.Add(@{Op='imm';d=0;i=14}); $s.Add(@{Op='return'}); $s.Add(@{Op='label';Name="length_$($a[0])"})
    }
    foreach($a in @(@(0,7),@(8,4),@(16,5),@(24,6))) {
        $s.Add(@{Op='load';d=$a[1];s=3;Offset=$a[0]})
        $s.Add(@{Op='eq';d=0;s=$a[1];t=15}); $s.Add(@{Op='jump-p';u=0;Label='bad'})
    }
    foreach($d in @(@(0,$Frames),@(4,$Channels))) {
        $s.Add(@{Op='load';d=0;s=7;Offset=$d[0]}); & $imm 1 $d[1]
        $s.Add(@{Op='eq';d=0;s=0;t=1}); $s.Add(@{Op='jump-p';u=0;Label="dim_$($d[0])"})
        $s.Add(@{Op='imm';d=0;i=14}); $s.Add(@{Op='return'}); $s.Add(@{Op='label';Name="dim_$($d[0])"})
    }
    & $imm 7 $BiasOffset; $s.Add(@{Op='add';d=7;s=5;t=7})
    & $imm 0 $WeightOffset; $s.Add(@{Op='add';d=5;s=5;t=0})
    $s.Add(@{Op='imm';d=8;i=$Channels})
    $s.Add(@{Op='label';Name='channel'}); $s.Add(@{Op='imm';d=9;i=$Frames})
    $s.Add(@{Op='label';Name='sample'}); $s.Add(@{Op='imm';d=2;i=0})
    $s.Add(@{Op='addi';d=10;s=5;i=0}); $s.Add(@{Op='addi';d=14;s=4;i=0})
    $s.Add(@{Op='imm';d=13;i=3})
    $s.Add(@{Op='label';Name='tap'}); $s.Add(@{Op='addi';d=11;s=14;i=0})
    $s.Add(@{Op='imm';d=12;i=$Channels})
    $s.Add(@{Op='label';Name='reduce'})
    $s.Add(@{Op='load';d=0;s=11;Offset=0}); $s.Add(@{Op='load';d=1;s=10;Offset=0})
    $s.Add(@{Op='sfmpy';d=0;s=0;t=1}); $s.Add(@{Op='sfadd';d=2;s=2;t=0})
    $s.Add(@{Op='addi';d=11;s=11;i=(4*($Frames+2))}); $s.Add(@{Op='addi';d=10;s=10;i=(4*$Channels)})
    $s.Add(@{Op='addi';d=12;s=12;i=-1}); $s.Add(@{Op='gtu';d=0;s=12;t=15})
    $s.Add(@{Op='jump-p';u=0;Label='reduce'})
    $s.Add(@{Op='addi';d=14;s=14;i=4}); $s.Add(@{Op='addi';d=13;s=13;i=-1})
    $s.Add(@{Op='gtu';d=0;s=13;t=15}); $s.Add(@{Op='jump-p';u=0;Label='tap'})
    $s.Add(@{Op='load';d=1;s=7;Offset=0}); $s.Add(@{Op='sfadd';d=2;s=2;t=1})
    $s.Add(@{Op='store';s=6;t=2;Offset=0})
    $s.Add(@{Op='addi';d=4;s=4;i=4}); $s.Add(@{Op='addi';d=6;s=6;i=4})
    $s.Add(@{Op='addi';d=9;s=9;i=-1}); $s.Add(@{Op='gtu';d=0;s=9;t=15})
    $s.Add(@{Op='jump-p';u=0;Label='sample'})
    $s.Add(@{Op='addi';d=4;s=4;i=(-4*$Frames)}); $s.Add(@{Op='addi';d=5;s=5;i=4})
    $s.Add(@{Op='addi';d=7;s=7;i=4}); $s.Add(@{Op='addi';d=8;s=8;i=-1})
    $s.Add(@{Op='gtu';d=0;s=8;t=15}); $s.Add(@{Op='jump-p';u=0;Label='channel'})
    $s.Add(@{Op='imm';d=0;i=0}); $s.Add(@{Op='return'})
    $s.ToArray()
}
