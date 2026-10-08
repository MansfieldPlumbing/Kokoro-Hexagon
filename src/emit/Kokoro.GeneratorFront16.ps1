#requires -Version 7.4
# HVX bodies of the 128-channel generator front (tools/New-KokoroGeneratorFront16Fixture.ps1): ups[1] as a polyphase
# conv leaves phase r of output channel o at channel 128 r + o of input frame q; padded frame T = 6 q + r.
# Stock: Kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec istftnet.py Generator.forward (ups[1], reflection_pad, add).

# Interleave one phase pair (2c, 2c + 1) into time. Each 128-byte vector of a 256-channel phase tile holds frames q, q + 1
# (even, odd halfwords) of 32 channels; block b (phase 2c) and block 4 + b (phase 2c + 1) of the same row pair give the
# target row pairs T = 6 q + 2c (frames 2c, 2c + 1) and T = 6 (q + 1) + 2c, as even/odd halfword merges.
# r0 phase tiles (256 channels, 16384 B per tile), r1 target tiles (128 channels, 8192 B per tile; writes reach up to four
# tiles past 6 * 2 * r3 / 32, so the region needs that slack), r2 = c (0..2), r3 = row pairs of q (>= 1).
# Caller-saved registers only.
function New-KokoroFrontInterleaveSteps {
    param([string]$LabelPrefix='frontinterleave',[switch]$NoReturn)
    $s = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL); $s.Add(@{Op='lo';x=$r;i=($u -band 65535)}); $s.Add(@{Op='hi';x=$r;i=($u -shr 16)}) }
    & $imm 13 0x0000FFFFL; $s.Add(@{Op='vsplat';d=31;s=13})
    & $imm 13 0xFFFF0000L; $s.Add(@{Op='vsplat';d=30;s=13})
    $s.Add(@{Op='imm';d=8;i=16}); $s.Add(@{Op='imm';d=7;i=0}); $s.Add(@{Op='imm';d=4;i=0})     # r4 = j
    $loop = "${LabelPrefix}_j"
    $s.Add(@{Op='label';Name=$loop})
    # Source row pair j: tile j >> 4, row pair j & 15.
    $s.Add(@{Op='lsr-i';d=5;s=4;i=4}); $s.Add(@{Op='asl-i';d=5;s=5;i=14})
    $s.Add(@{Op='imm';d=6;i=15}); $s.Add(@{Op='and';d=6;s=4;t=6}); $s.Add(@{Op='asl-i';d=6;s=6;i=7}); $s.Add(@{Op='add';d=5;s=5;t=6}); $s.Add(@{Op='add';d=5;s=5;t=0})
    # Target row pairs R1 = 6 j + c and R2 = R1 + 3: offsets (R >> 4) * 8192 + (R & 15) * 128.
    $s.Add(@{Op='asl-i';d=9;s=4;i=1}); $s.Add(@{Op='add';d=9;s=9;t=4}); $s.Add(@{Op='asl-i';d=9;s=9;i=1}); $s.Add(@{Op='add';d=9;s=9;t=2})   # R1
    foreach ($pair in @(@(10, 0), @(11, 3))) {
        $s.Add(@{Op='addi';d=12;s=9;i=$pair[1]})
        $s.Add(@{Op='lsr-i';d=$pair[0];s=12;i=4}); $s.Add(@{Op='asl-i';d=$pair[0];s=$pair[0];i=13})
        $s.Add(@{Op='imm';d=6;i=15}); $s.Add(@{Op='and';d=12;s=12;t=6}); $s.Add(@{Op='asl-i';d=12;s=12;i=7}); $s.Add(@{Op='add';d=$pair[0];s=$pair[0];t=12}); $s.Add(@{Op='add';d=$pair[0];s=$pair[0];t=1})
    }
    for ($b = 0; $b -lt 4; $b++) {
        $s.Add(@{Op='addi';d=12;s=5;i=(2048*$b)}); $s.Add(@{Op='vload';d=0;s=12;Offset=0})
        $s.Add(@{Op='addi';d=12;s=5;i=(2048*(4+$b))}); $s.Add(@{Op='vload';d=1;s=12;Offset=0})
        $s.Add(@{Op='vand';d=2;s=0;t=31}); $s.Add(@{Op='vasl-w';d=3;s=1;t=8}); $s.Add(@{Op='vor';d=2;s=2;t=3})       # frame q
        $s.Add(@{Op='vlsr-uw';d=4;s=0;t=8}); $s.Add(@{Op='vand';d=5;s=1;t=30}); $s.Add(@{Op='vor';d=4;s=4;t=5})      # frame q + 1
        $s.Add(@{Op='addi';d=12;s=10;i=(2048*$b)}); $s.Add(@{Op='vstore';s=12;t=2;Offset=0})
        $s.Add(@{Op='addi';d=12;s=11;i=(2048*$b)}); $s.Add(@{Op='vstore';s=12;t=4;Offset=0})
    }
    $s.Add(@{Op='addi';d=4;s=4;i=1})
    $s.Add(@{Op='gtu';d=0;s=3;t=4})
    $s.Add(@{Op='jump-p';u=0;Label=$loop})
    if (-not $NoReturn) { $s.Add(@{Op='return'}) }
    $s.ToArray()
}

# R = sat(rU * X + rN * R) per channel with Q14 ratios (below 2): each product at half scale (Q15 rounding multiply by
# the Q14 ratio), summed, then doubled with saturation. 128-channel biased u16 croutons.
# r0 X tiles, r1 R tiles (in and out), r2 ratios: rU int32[128] at 0, rN int32[128] at 512, r3 tiles >= 1.
# Caller-saved registers only.
function New-KokoroFrontAddSteps {
    param([string]$LabelPrefix='frontadd',[switch]$NoReturn)
    $s = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL); $s.Add(@{Op='lo';x=$r;i=($u -band 65535)}); $s.Add(@{Op='hi';x=$r;i=($u -shr 16)}) }
    & $imm 13 0x80008000L; $s.Add(@{Op='vsplat';d=31;s=13})
    $s.Add(@{Op='imm';d=9;i=16}); $s.Add(@{Op='imm';d=7;i=0})
    # Ratios in both halfwords of each word lane: v16..v19 rU, v20..v23 rN (one vector per block).
    for ($b = 0; $b -lt 8; $b++) {
        $s.Add(@{Op='addi';d=6;s=2;i=($(if ($b -lt 4) { 0 } else { 512 }) + 128 * ($b % 4))})
        $s.Add(@{Op='vload';d=(16+$b);s=6;Offset=0})
        $s.Add(@{Op='vasl-w';d=24;s=(16+$b);t=9}); $s.Add(@{Op='vlsr-uw';d=25;s=24;t=9}); $s.Add(@{Op='vor';d=(16+$b);s=24;t=25})
    }
    $s.Add(@{Op='addi';d=15;s=3;i=0})
    $tile = "${LabelPrefix}_tile"
    $s.Add(@{Op='label';Name=$tile})
    for ($b = 0; $b -lt 4; $b++) {
        $s.Add(@{Op='imm';d=14;i=16})
        $pair = "${LabelPrefix}_b${b}"
        $s.Add(@{Op='label';Name=$pair})
        $s.Add(@{Op='vload';d=0;s=0;Offset=0}); $s.Add(@{Op='vxor';d=0;s=0;t=31})
        $s.Add(@{Op='vload';d=1;s=1;Offset=0}); $s.Add(@{Op='vxor';d=1;s=1;t=31})
        $s.Add(@{Op='vmpy-h-rnd-sat';d=0;s=0;t=(16+$b)}); $s.Add(@{Op='vmpy-h-rnd-sat';d=1;s=1;t=(20+$b)})
        $s.Add(@{Op='vadd-h-sat';d=0;s=0;t=1}); $s.Add(@{Op='vadd-h-sat';d=0;s=0;t=0})
        $s.Add(@{Op='vxor';d=0;s=0;t=31}); $s.Add(@{Op='vstore';s=1;t=0;Offset=0})
        $s.Add(@{Op='addi';d=0;s=0;i=128}); $s.Add(@{Op='addi';d=1;s=1;i=128})
        $s.Add(@{Op='addi';d=14;s=14;i=-1}); $s.Add(@{Op='gtu';d=0;s=14;t=7}); $s.Add(@{Op='jump-p';u=0;Label=$pair})
    }
    $s.Add(@{Op='addi';d=15;s=15;i=-1}); $s.Add(@{Op='gtu';d=0;s=15;t=7}); $s.Add(@{Op='jump-p';u=0;Label=$tile})
    if (-not $NoReturn) { $s.Add(@{Op='return'}) }
    $s.ToArray()
}
