#requires -Version 7.4
# Integer full-group channel moments in the plain HMX crouton layout.
# V73 HVX PRM 80-N2040-54 Rev AB, word add, unsigned logical right shift,
# and word-by-low-unsigned-halfword multiply (vmpyie).
# SDK PDF SHA256 D153DC5BE149FD90518438A10142BB9828A782EBD7F9551FF20DDBA92A435297.
# r0 = native input tile 0; r1 = 1024-byte output; r2 = tile count >=1.
# Output per 32-channel block: 128 bytes uint32 sums, then 128 bytes sums of squares.
# Odd native bytes are u8 values. Unused final-group rows MUST contain u8 zero,
# so neither moment includes padding. The actual frame count accompanies the
# sums for downstream mean/variance; no per-tile normalization is performed.
# Caller bounds: 128 channels, at most 32768 valid frames / 1024 tiles, input and
# output 128-byte aligned and disjoint. 65025*32768 < INT32_MAX for sum of squares.
function New-KokoroAdaInStatisticsSteps {
    # Channels controls native tile bytes (Channels*64) and moments (Channels*8).
    param([ValidateSet(128,256)][int]$Channels=128,[string]$LabelPrefix='adainstats',[switch]$NoReturn)
    $steps=[Collections.Generic.List[hashtable]]::new()
    $steps.Add(@{Op='imm';d=7;i=8})
    $steps.Add(@{Op='imm';d=8;i=24})
    $steps.Add(@{Op='imm';d=9;i=0})
    $steps.Add(@{Op='imm';d=10;i=255})
    $steps.Add(@{Op='vsplat';d=3;s=10})
    for ($block=0; $block -lt ($Channels/32); $block++) {
        $steps.Add(@{Op='addi';d=4;s=0;i=($block*2048)})
        $steps.Add(@{Op='addi';d=5;s=2;i=0})
        $steps.Add(@{Op='vxor';d=4;s=4;t=4})
        $steps.Add(@{Op='vxor';d=5;s=5;t=5})
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
        $steps.Add(@{Op='addi';d=6;s=1;i=($block*256)})
        $steps.Add(@{Op='vstore';t=4;s=6;Offset=0})
        $steps.Add(@{Op='vstore';t=5;s=6;Offset=128})
    }
    if (-not $NoReturn) { $steps.Add(@{Op='return'}) }
    $steps.ToArray()
}
