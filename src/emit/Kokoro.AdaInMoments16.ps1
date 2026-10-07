#requires -Version 7.4
# AdaIN group moments over 16-bit activations (biased u16 in native croutons), accumulated onto a
# per-channel record. Design: docs/generator60x-16bit-design.md ("Moments").
# x = 256 a + b with a = x >> 8 (signed) and b = x & 255; per channel the record holds
#   S1 = sum x,  A2 = sum a^2,  AB = sum a*b,  B2 = sum b^2   (int32 each)
# so sum x^2 = 65536 A2 + 512 AB + B2 exactly. Each partial stays below 2^31 for 7,801 frames.
# Record: per 32-channel block b, 512 bytes at 512*b: S1[32], A2[32], AB[32], B2[32].
# Padded rows must hold x = 0 (biased 0x8000) so they add nothing.
# r0 = tile 0 (8 KB per 128-channel tile), r1 = record (read, added to, written), r2 = tiles >= 1.
# r16..r27 are untouched.
function New-KokoroAdaInMoments16Steps {
    param([ValidateSet(128,256)][int]$Channels=128,[string]$LabelPrefix='adainmoments16',[switch]$NoReturn)
    $s = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL); $s.Add(@{Op='lo';x=$r;i=($u -band 65535)}); $s.Add(@{Op='hi';x=$r;i=($u -shr 16)}) }
    & $imm 13 0x80008000L; $s.Add(@{Op='vsplat';d=31;s=13})
    & $imm 13 0x00FF00FFL; $s.Add(@{Op='vsplat';d=30;s=13})
    & $imm 12 0x00010001L                       # multiplier 1 in both halfwords
    $s.Add(@{Op='imm';d=8;i=8}); $s.Add(@{Op='imm';d=7;i=0})
    for ($block = 0; $block -lt ($Channels / 32); $block++) {
        foreach ($v in 0..7) { $s.Add(@{Op='vxor';d=$v;s=$v;t=$v}) }
        $s.Add(@{Op='addi';d=5;s=0;i=($block*2048)})
        $s.Add(@{Op='addi';d=15;s=2;i=0})
        $tile = "${LabelPrefix}_b${block}_tile"; $vec = "${LabelPrefix}_b${block}_vec"
        $s.Add(@{Op='label';Name=$tile})
        $s.Add(@{Op='imm';d=14;i=16})
        $s.Add(@{Op='label';Name=$vec})
        $s.Add(@{Op='vload';d=8;s=5;Offset=0})
        $s.Add(@{Op='vxor';d=8;s=8;t=31})                       # signed x
        $s.Add(@{Op='vmpy-acc-ww-h-r';d=0;s=8;t=12})            # S1 (even rows v0, odd rows v1)
        $s.Add(@{Op='vasr-h';d=9;s=8;t=8})                      # a
        $s.Add(@{Op='vand';d=10;s=8;t=30})                      # b
        $s.Add(@{Op='vmpy-acc-ww-h-h';d=2;s=9;t=9})             # A2
        $s.Add(@{Op='vmpy-acc-ww-h-h';d=4;s=9;t=10})            # AB
        $s.Add(@{Op='vmpy-acc-ww-h-h';d=6;s=10;t=10})           # B2
        $s.Add(@{Op='addi';d=5;s=5;i=128})
        $s.Add(@{Op='addi';d=14;s=14;i=-1})
        $s.Add(@{Op='gtu';d=0;s=14;t=7})
        $s.Add(@{Op='jump-p';u=0;Label=$vec})
        $s.Add(@{Op='addi';d=5;s=5;i=($Channels*64-2048)})
        $s.Add(@{Op='addi';d=15;s=15;i=-1})
        $s.Add(@{Op='gtu';d=0;s=15;t=7})
        $s.Add(@{Op='jump-p';u=0;Label=$tile})
        # Fold even and odd rows, add onto the record.
        $s.Add(@{Op='addi';d=6;s=1;i=($block*512)})
        for ($q = 0; $q -lt 4; $q++) {
            $s.Add(@{Op='vadd-w';d=(2*$q);s=(2*$q);t=(2*$q+1)})
            $s.Add(@{Op='vload';d=11;s=6;Offset=(128*$q)})
            $s.Add(@{Op='vadd-w';d=(2*$q);s=(2*$q);t=11})
            $s.Add(@{Op='vstore';s=6;t=(2*$q);Offset=(128*$q)})
        }
    }
    if (-not $NoReturn) { $s.Add(@{Op='return'}) }
    $s.ToArray()
}
