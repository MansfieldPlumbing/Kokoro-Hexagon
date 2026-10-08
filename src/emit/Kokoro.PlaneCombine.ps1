#requires -Version 7.4
# Combine the four byte planes of a two-group HMX conv (Kokoro.HmxConvPlanes.ps1) into 16-bit values.
# Design: docs/generator60x-16bit-design.md ("Combine"). Groups 1 and 2 rebuild their biased 16-bit
# window w = high << 8 | low (bias 32768); the value is the sum of the signed windows, saturated to int16.
# -Groups 3 adds the low x low group of -WeightPlanes 2, whose window (shift L + 8, |w| < 128) is its low
# plane alone, sign-extended (tools/New-KokoroGenerator60x16Fixture.ps1 tables). With -Group3Shifts that window
# sits at shift L + 8 + g per channel (range +-127 * 2^g) and is sign-extended by a per-lane arithmetic shift of
# 8 - g, from halfword vectors at r2 + 1024 (one per 32-channel block, both halfwords of a lane equal).
#   -Mode Conv:     store the value biased (u16 = v + 32768): conv1 output C.
#   -Mode Residual: O = v * ratio_c (Q15 rounding multiply, per channel), R = sat(R + O), stored biased:
#                   conv2 output added into the residual stream in one pass.
# Native croutons: tile t, block ob at (t*OB + ob)*2048 in every plane and in the output; each 128-byte
# vector is a row pair x 32 channels; word lane j is channel 32*ob + j for both rows.
# r0 = plane base (plane p at r0 + p*PlaneStride; high bytes in odd positions), r1 = output tiles
# (Residual: also the R input), r2 = Residual: ratio Q15 per channel as int32[C] (low halfword used),
# r3 = tiles >= 1. r16..r27 are untouched.
function New-KokoroPlaneCombineSteps {
    param(
        [ValidateSet('Conv','Residual')][string] $Mode = 'Conv',
        [ValidateSet(64, 128, 256)][int] $Channels = 128,
        [ValidateSet(2,3)][int] $Groups = 2,
        [switch] $Group3Shifts,
        [Parameter(Mandatory)][ValidateRange(2048, 1073741824)][long] $PlaneStride,
        [string] $LabelPrefix = 'planecombine',
        [switch] $NoReturn
    )
    if ($PlaneStride % 2048 -ne 0) { throw 'Plane stride must keep 2 KB tile alignment' }
    $ob = $Channels / 32
    $s = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL); $s.Add(@{Op='lo';x=$r;i=($u -band 65535)}); $s.Add(@{Op='hi';x=$r;i=($u -shr 16)}) }
    & $imm 13 0xFF00FF00L; $s.Add(@{Op='vsplat';d=31;s=13})
    & $imm 13 0x00FF00FFL; $s.Add(@{Op='vsplat';d=30;s=13})
    & $imm 13 0x80008000L; $s.Add(@{Op='vsplat';d=29;s=13})
    $s.Add(@{Op='imm';d=8;i=8}); $s.Add(@{Op='imm';d=9;i=16}); $s.Add(@{Op='imm';d=7;i=0})
    & $imm 10 $PlaneStride
    if ($Mode -eq 'Residual') {
        # Per-channel Q15 ratio in both halfwords of each word lane, one vector per block.
        for ($b = 0; $b -lt $ob; $b++) {
            $s.Add(@{Op='addi';d=6;s=2;i=(128*$b)})
            $s.Add(@{Op='vload';d=(20+$b);s=6;Offset=0})
            $s.Add(@{Op='vasl-w';d=24;s=(20+$b);t=9})                # low halfword into the high one
            $s.Add(@{Op='vlsr-uw';d=25;s=24;t=9})                    # and back down: clear any high bits
            $s.Add(@{Op='vor';d=(20+$b);s=24;t=25})
        }
    }
    if ($Group3Shifts) {
        if ($Groups -ne 3) { throw 'Group 3 shifts need three groups' }
        for ($b = 0; $b -lt $ob; $b++) { $s.Add(@{Op='addi';d=6;s=2;i=(1024+128*$b)}); $s.Add(@{Op='vload';d=(16+$b);s=6;Offset=0}) }
    }
    $s.Add(@{Op='addi';d=15;s=3;i=0})
    $tile = "${LabelPrefix}_tile"
    $s.Add(@{Op='label';Name=$tile})
    for ($b = 0; $b -lt $ob; $b++) {
        $s.Add(@{Op='imm';d=14;i=16})
        $pair = "${LabelPrefix}_b${b}"
        $s.Add(@{Op='label';Name=$pair})
        # Planes: r0 (A1 high), r0+S (A1 low), r0+2S (A2 high), r0+3S (A2 low).
        $s.Add(@{Op='vload';d=0;s=0;Offset=0})
        $s.Add(@{Op='add';d=11;s=0;t=10}); $s.Add(@{Op='vload';d=1;s=11;Offset=0})
        $s.Add(@{Op='add';d=11;s=11;t=10}); $s.Add(@{Op='vload';d=2;s=11;Offset=0})
        $s.Add(@{Op='add';d=11;s=11;t=10}); $s.Add(@{Op='vload';d=3;s=11;Offset=0})
        $pairs = @(@(0,1),@(2,3))
        if ($Groups -eq 3) {
            # Low x low group: only its low plane (r0+5S) is read; the byte is its whole signed window.
            $s.Add(@{Op='add';d=11;s=11;t=10}); $s.Add(@{Op='add';d=11;s=11;t=10}); $s.Add(@{Op='vload';d=6;s=11;Offset=0})
            if ($Group3Shifts) { $s.Add(@{Op='vasr-hv';d=6;s=6;t=(16+$b)}) }   # sign-extend, times 2^g
            else { $s.Add(@{Op='vasr-h';d=6;s=6;t=8}) }                     # sign-extend the odd byte
        }
        foreach ($g in $pairs) {
            $s.Add(@{Op='vand';d=$g[0];s=$g[0];t=31})                 # high byte stays in the odd position
            $s.Add(@{Op='vlsr-uw';d=$g[1];s=$g[1];t=8})
            $s.Add(@{Op='vand';d=$g[1];s=$g[1];t=30})                 # low byte to the even position
            $s.Add(@{Op='vor';d=$g[0];s=$g[0];t=$g[1]})
            $s.Add(@{Op='vxor';d=$g[0];s=$g[0];t=29})                 # signed window
        }
        $s.Add(@{Op='vadd-h-sat';d=4;s=0;t=2})                        # value, int16
        if ($Groups -eq 3) { $s.Add(@{Op='vadd-h-sat';d=4;s=4;t=6}) }
        if ($Mode -eq 'Residual') {
            $s.Add(@{Op='vmpy-h-rnd-sat';d=4;s=4;t=(20+$b)})          # O = v * ratio_c
            $s.Add(@{Op='vload';d=5;s=1;Offset=0})
            $s.Add(@{Op='vxor';d=5;s=5;t=29})
            $s.Add(@{Op='vadd-h-sat';d=4;s=5;t=4})                    # R + O
        }
        $s.Add(@{Op='vxor';d=4;s=4;t=29})
        $s.Add(@{Op='vstore';s=1;t=4;Offset=0})
        $s.Add(@{Op='addi';d=0;s=0;i=128}); $s.Add(@{Op='addi';d=1;s=1;i=128})
        $s.Add(@{Op='addi';d=14;s=14;i=-1})
        $s.Add(@{Op='gtu';d=0;s=14;t=7})
        $s.Add(@{Op='jump-p';u=0;Label=$pair})
    }
    $s.Add(@{Op='addi';d=15;s=15;i=-1})
    $s.Add(@{Op='gtu';d=0;s=15;t=7})
    $s.Add(@{Op='jump-p';u=0;Label=$tile})
    if (-not $NoReturn) { $s.Add(@{Op='return'}) }
    $s.ToArray()
}
