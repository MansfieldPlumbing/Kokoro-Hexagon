#requires -Version 7.4
# Integer channel moments added onto running sums, for use in the epilogue of the conv
# (or residual) that produces each batch of tiles. Same arithmetic and layout as
# New-KokoroAdaInStatisticsSteps (Kokoro.AdaInStatistics.ps1); integer sums are
# order-independent, so accumulating batch by batch equals one full-group pass.
# r0 = native input tile 0; r1 = 1024-byte running moments (read, then written);
# r2 = tile count >= 1. Per 32-channel block: 128 bytes uint32 sums, then 128 bytes
# sums of squares. Rows past the valid frame count MUST hold u8 zero.
# Caller bounds as for the full-group pass: 128 channels, at most 32768 frames.
function New-KokoroAdaInStatisticsAccumulateSteps {
    param([string]$LabelPrefix='adainstatsacc')
    $Channels=128
    $steps=[Collections.Generic.List[hashtable]]::new()
    $steps.Add(@{Op='imm';d=7;i=8})
    $steps.Add(@{Op='imm';d=8;i=24})
    $steps.Add(@{Op='imm';d=9;i=0})
    $steps.Add(@{Op='imm';d=10;i=255})
    $steps.Add(@{Op='vsplat';d=3;s=10})
    for ($block=0; $block -lt ($Channels/32); $block++) {
        $steps.Add(@{Op='addi';d=4;s=0;i=($block*2048)})
        $steps.Add(@{Op='addi';d=5;s=2;i=0})
        $steps.Add(@{Op='addi';d=6;s=1;i=($block*256)})
        $steps.Add(@{Op='vload';d=4;s=6;Offset=0})
        $steps.Add(@{Op='vload';d=5;s=6;Offset=128})
        $label="${LabelPrefix}_b${block}_tile"
        $steps.Add(@{Op='label';Name=$label})
        for ($pair=0; $pair -lt 16; $pair++) {
            $steps.Add(@{Op='vload';d=0;s=4;Offset=0})
            $steps.Add(@{Op='vlsr-uw';d=1;s=0;t=7})
            $steps.Add(@{Op='vand';d=1;s=1;t=3})
            $steps.Add(@{Op='vlsr-uw';d=2;s=0;t=8})
            $steps.Add(@{Op='vadd-w';d=4;s=4;t=1})
            $steps.Add(@{Op='vadd-w';d=4;s=4;t=2})
            $steps.Add(@{Op='vmpyie-w-uh';d=6;s=1;t=1})
            $steps.Add(@{Op='vmpyie-w-uh';d=7;s=2;t=2})
            $steps.Add(@{Op='vadd-w';d=5;s=5;t=6})
            $steps.Add(@{Op='vadd-w';d=5;s=5;t=7})
            $steps.Add(@{Op='addi';d=4;s=4;i=128})
        }
        $steps.Add(@{Op='addi';d=4;s=4;i=($Channels*64-2048)})
        $steps.Add(@{Op='addi';d=5;s=5;i=-1})
        $steps.Add(@{Op='gtu';d=0;s=5;t=9})
        $steps.Add(@{Op='jump-p';u=0;Label=$label})
        $steps.Add(@{Op='vstore';t=4;s=6;Offset=0})
        $steps.Add(@{Op='vstore';t=5;s=6;Offset=128})
    }
    $steps.Add(@{Op='return'})
    $steps.ToArray()
}
