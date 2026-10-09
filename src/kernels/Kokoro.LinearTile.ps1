# PowerShell-authored Hexagon V73 FP32 affine tile. The DSP, not PowerShell,
# performs every product and accumulation. This is a bounded correctness tile,
# not an HMX throughput claim. Opcode source: pinned 80-N2040-53 Rev. AB.
# FastRPC remote_arg ABI is the same source-defined diagnostic bootstrap used
# by Kokoro.ConvTile.ps1; the product transport is not established here.
function New-KokoroLinearTileSteps {
    param([ValidateRange(1, 512)][int] $Rows = 3,
        [ValidateRange(1, 4096)][int] $InputChannels = 768,
        [ValidateRange(1, 4096)][int] $OutputChannels = 512,
        [switch] $VectorOutputTiles)
    [long]$inputBytes = 4L * $Rows * $InputChannels
    [long]$weightBytes = 4L * $OutputChannels * ($InputChannels + 1L)
    [long]$outputBytes = 4L * $Rows * $OutputChannels
    if ($inputBytes -gt [uint32]::MaxValue -or $weightBytes -gt [uint32]::MaxValue -or
        $outputBytes -gt [uint32]::MaxValue -or
        [long]$Rows * $InputChannels * $OutputChannels -gt 10000000) {
        throw 'Linear tile exceeds bounded geometry.'
    }
    $steps = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int] $Register, [uint32] $Value)
        $steps.Add(@{Op='lo';x=$Register;i=($Value -band 65535)})
        $steps.Add(@{Op='hi';x=$Register;i=($Value -shr 16)})
    }
    foreach ($dispatch in @(@(0x00020001,'open'),@(0x01000010,'success'),
            @(0x02030100,'linear'))) {
        & $imm 4 $dispatch[0]
        $steps.Add(@{Op='eq';d=0;s=2;t=4})
        $steps.Add(@{Op='jump-p';u=0;Label=$dispatch[1]})
    }
    $steps.Add(@{Op='imm';d=0;i=20}); $steps.Add(@{Op='return'})
    $steps.Add(@{Op='label';Name='bad'})
    $steps.Add(@{Op='imm';d=0;i=14}); $steps.Add(@{Op='return'})
    $steps.Add(@{Op='label';Name='open'})
    $steps.Add(@{Op='imm';d=4;i=0})
    $steps.Add(@{Op='eq';d=0;s=3;t=4}); $steps.Add(@{Op='jump-p';u=0;Label='bad'})
    $steps.Add(@{Op='imm';d=4;i=1}); $steps.Add(@{Op='store';s=3;t=4;Offset=16})
    $steps.Add(@{Op='imm';d=4;i=0}); $steps.Add(@{Op='store';s=3;t=4;Offset=20})
    $steps.Add(@{Op='label';Name='success'})
    $steps.Add(@{Op='imm';d=0;i=0}); $steps.Add(@{Op='return'})
    $steps.Add(@{Op='label';Name='linear'})
    $steps.Add(@{Op='imm';d=15;i=0})
    $steps.Add(@{Op='eq';d=0;s=3;t=15}); $steps.Add(@{Op='jump-p';u=0;Label='bad'})
    # remote_arg[0..3] = geometry {rows,in,out}, input, weights+bias, output.
    foreach ($arg in @(@(4,12),@(12,$inputBytes),@(20,$weightBytes),
            @(28,$outputBytes))) {
        $steps.Add(@{Op='load';d=0;s=3;Offset=$arg[0]})
        & $imm 1 ([uint32]($arg[1]-1))
        $steps.Add(@{Op='gtu';d=0;s=0;t=1})
        $steps.Add(@{Op='jump-p';u=0;Label="length_$($arg[0])"})
        $steps.Add(@{Op='imm';d=0;i=14}); $steps.Add(@{Op='return'})
        $steps.Add(@{Op='label';Name="length_$($arg[0])"})
    }
    foreach ($arg in @(@(0,7),@(8,4),@(16,5),@(24,6))) {
        $steps.Add(@{Op='load';d=$arg[1];s=3;Offset=$arg[0]})
        $steps.Add(@{Op='eq';d=0;s=$arg[1];t=15})
        $steps.Add(@{Op='jump-p';u=0;Label='bad'})
    }
    foreach ($dimension in @(@(0,$Rows),@(4,$InputChannels),
            @(8,$OutputChannels))) {
        $steps.Add(@{Op='load';d=0;s=7;Offset=$dimension[0]})
        & $imm 1 ([uint32]$dimension[1])
        $steps.Add(@{Op='eq';d=0;s=0;t=1})
        $steps.Add(@{Op='jump-p';u=0;Label="dimension_$($dimension[0])"})
        $steps.Add(@{Op='imm';d=0;i=14}); $steps.Add(@{Op='return'})
        $steps.Add(@{Op='label';Name="dimension_$($dimension[0])"})
    }
    if ($VectorOutputTiles) {
        if (($OutputChannels % 128) -ne 0) {
            throw 'Vector linear output channels must be divisible by 128.'
        }
        # Vector form consumes weights repacked at build time as [input,output]
        # followed by output bias. Four vectors cover one 128-output tile.
        # Explicit QFloat-to-FP32 conversion after every multiply and add keeps
        # this schedule aligned with the verified complete-block HVX strategy.
        $steps.Add(@{Op='load';d=4;s=3;Offset=8})
        $steps.Add(@{Op='load';d=6;s=3;Offset=24})
        $steps.Add(@{Op='load';d=7;s=3;Offset=16})
        & $imm 14 ([uint32](4L * $InputChannels * $OutputChannels))
        $steps.Add(@{Op='add';d=7;s=7;t=14})
        $steps.Add(@{Op='imm';d=9;i=$Rows})
        $steps.Add(@{Op='label';Name='vector_row'})
        $steps.Add(@{Op='load';d=5;s=3;Offset=16})
        $steps.Add(@{Op='load';d=7;s=3;Offset=16})
        & $imm 14 ([uint32](4L * $InputChannels * $OutputChannels))
        $steps.Add(@{Op='add';d=7;s=7;t=14})
        $steps.Add(@{Op='imm';d=13;i=($OutputChannels/128)})
        $steps.Add(@{Op='label';Name='vector_tile'})
        foreach ($v in 0..3) { $steps.Add(@{Op='vsplat';d=$v;s=15}) }
        $steps.Add(@{Op='addi';d=11;s=4;i=0})
        $steps.Add(@{Op='addi';d=12;s=5;i=0})
        $steps.Add(@{Op='imm';d=10;i=$InputChannels})
        $steps.Add(@{Op='label';Name='vector_reduce'})
        $steps.Add(@{Op='load';d=0;s=11;Offset=0})
        $steps.Add(@{Op='vsplat';d=4;s=0})
        foreach ($v in 0..3) { $steps.Add(@{Op='vload';d=(8+$v);s=12;Offset=(128*$v)}) }
        foreach ($v in 0..3) { $steps.Add(@{Op='vmpy-sf-qf32';d=(8+$v);s=(8+$v);t=4}) }
        foreach ($v in 0..3) { $steps.Add(@{Op='vconv-qf32-sf';d=(8+$v);s=(8+$v)}) }
        foreach ($v in 0..3) { $steps.Add(@{Op='vadd-sf-qf32';d=$v;s=$v;t=(8+$v)}) }
        foreach ($v in 0..3) { $steps.Add(@{Op='vconv-qf32-sf';d=$v;s=$v}) }
        $steps.Add(@{Op='addi';d=11;s=11;i=4})
        & $imm 14 ([uint32](4L*$OutputChannels))
        $steps.Add(@{Op='add';d=12;s=12;t=14})
        $steps.Add(@{Op='addi';d=10;s=10;i=-1})
        $steps.Add(@{Op='gtu';d=0;s=10;t=15})
        $steps.Add(@{Op='jump-p';u=0;Label='vector_reduce'})
        foreach ($v in 0..3) { $steps.Add(@{Op='vload';d=(8+$v);s=7;Offset=(128*$v)}) }
        foreach ($v in 0..3) { $steps.Add(@{Op='vadd-sf-qf32';d=$v;s=$v;t=(8+$v)}) }
        foreach ($v in 0..3) { $steps.Add(@{Op='vconv-qf32-sf';d=$v;s=$v}) }
        foreach ($v in 0..3) { $steps.Add(@{Op='vstore';t=$v;s=6;Offset=(128*$v)}) }
        $steps.Add(@{Op='addi';d=5;s=5;i=512})
        $steps.Add(@{Op='addi';d=6;s=6;i=512})
        $steps.Add(@{Op='addi';d=7;s=7;i=512})
        $steps.Add(@{Op='addi';d=13;s=13;i=-1})
        $steps.Add(@{Op='gtu';d=0;s=13;t=15})
        $steps.Add(@{Op='jump-p';u=0;Label='vector_tile'})
        $steps.Add(@{Op='addi';d=4;s=4;i=(4*$InputChannels)})
        $steps.Add(@{Op='addi';d=9;s=9;i=-1})
        $steps.Add(@{Op='gtu';d=0;s=9;t=15})
        $steps.Add(@{Op='jump-p';u=0;Label='vector_row'})
        $steps.Add(@{Op='imm';d=0;i=0}); $steps.Add(@{Op='return'})
        return $steps.ToArray()
    }
    # r5: current weight row; r7: current bias; r14: output column offset.
    $steps.Add(@{Op='load';d=5;s=3;Offset=16})
    & $imm 7 ([uint32](4L * $OutputChannels * $InputChannels))
    $steps.Add(@{Op='add';d=7;s=5;t=7})
    $steps.Add(@{Op='imm';d=8;i=$OutputChannels})
    $steps.Add(@{Op='imm';d=14;i=0})
    $steps.Add(@{Op='label';Name='output_channel'})
    $steps.Add(@{Op='load';d=4;s=3;Offset=8})
    $steps.Add(@{Op='load';d=6;s=3;Offset=24})
    $steps.Add(@{Op='add';d=6;s=6;t=14})
    $steps.Add(@{Op='imm';d=9;i=$Rows})
    $steps.Add(@{Op='label';Name='row'})
    $steps.Add(@{Op='load';d=2;s=7;Offset=0})
    $steps.Add(@{Op='addi';d=10;s=4;i=0})
    $steps.Add(@{Op='addi';d=11;s=5;i=0})
    $steps.Add(@{Op='imm';d=12;i=$InputChannels})
    $steps.Add(@{Op='label';Name='reduce'})
    $steps.Add(@{Op='load';d=0;s=10;Offset=0})
    $steps.Add(@{Op='load';d=1;s=11;Offset=0})
    $steps.Add(@{Op='sfmpy';d=0;s=0;t=1})
    $steps.Add(@{Op='sfadd';d=2;s=2;t=0})
    $steps.Add(@{Op='addi';d=10;s=10;i=4})
    $steps.Add(@{Op='addi';d=11;s=11;i=4})
    $steps.Add(@{Op='addi';d=12;s=12;i=-1})
    $steps.Add(@{Op='gtu';d=0;s=12;t=15})
    $steps.Add(@{Op='jump-p';u=0;Label='reduce'})
    $steps.Add(@{Op='store';s=6;t=2;Offset=0})
    $steps.Add(@{Op='addi';d=4;s=4;i=(4*$InputChannels)})
    $steps.Add(@{Op='addi';d=6;s=6;i=(4*$OutputChannels)})
    $steps.Add(@{Op='addi';d=9;s=9;i=-1})
    $steps.Add(@{Op='gtu';d=0;s=9;t=15})
    $steps.Add(@{Op='jump-p';u=0;Label='row'})
    $steps.Add(@{Op='addi';d=5;s=5;i=(4*$InputChannels)})
    $steps.Add(@{Op='addi';d=7;s=7;i=4})
    $steps.Add(@{Op='addi';d=14;s=14;i=4})
    $steps.Add(@{Op='addi';d=8;s=8;i=-1})
    $steps.Add(@{Op='gtu';d=0;s=8;t=15})
    $steps.Add(@{Op='jump-p';u=0;Label='output_channel'})
    $steps.Add(@{Op='imm';d=0;i=0}); $steps.Add(@{Op='return'})
    $steps.ToArray()
}
