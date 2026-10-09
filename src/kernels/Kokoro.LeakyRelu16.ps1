#requires -Version 7.4
# Stock generator tail LeakyReLU (F.leaky_relu, slope 0.01; Kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec
# istftnet.py Generator.forward) on 16-bit activations, emitting the two conv-input byte planes of conv_post.
# The input's per-channel scale passes through unchanged (leaky(s q) = s leaky(q) for s > 0) and is folded
# into conv_post's weights (tools/New-KokoroGeneratorTail16Fixture.ps1), so the body is channel-free:
#   y = max(q, 0) + round(min(q, 0) * 328 / 32768)        (0.01 as Q15 328: 0.1% of the negative part)
#   high plane (y >> 8) + 128 = (y & 0xFF00) ^ 0x8000, low plane y & 255, each in the odd byte of a halfword.
# r0 input vectors (biased u16, x + 32768), r1 high-plane vectors, r2 low-plane vectors, r3 vector count >= 1
# (64 per 128-channel tile). Caller-saved registers only.
function New-KokoroLeakyRelu16Steps {
    # -Slope: the negative slope as a Q15 multiplier (0.01 for the tail, 0.1 for the generator's upsampling inputs).
    param([string]$LabelPrefix='leakyrelu16',[ValidateRange(0.0,0.5)][double]$Slope=0.01,[switch]$NoReturn)
    $q15=[long][math]::Round($Slope*32768)
    $s = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL); $s.Add(@{Op='lo';x=$r;i=($u -band 65535)}); $s.Add(@{Op='hi';x=$r;i=($u -shr 16)}) }
    & $imm 13 0x80008000L; $s.Add(@{Op='vsplat';d=31;s=13})
    & $imm 13 0xFF00FF00L; $s.Add(@{Op='vsplat';d=30;s=13})
    & $imm 13 (($q15 -shl 16) -bor $q15); $s.Add(@{Op='vsplat';d=29;s=13})   # round(slope * 32768) per halfword
    $s.Add(@{Op='vxor';d=28;s=28;t=28})                             # zero
    $s.Add(@{Op='imm';d=8;i=8}); $s.Add(@{Op='imm';d=7;i=0})
    $loop = "${LabelPrefix}_v"
    $s.Add(@{Op='label';Name=$loop})
    $s.Add(@{Op='vload';d=0;s=0;Offset=0})
    $s.Add(@{Op='vxor';d=0;s=0;t=31})                               # signed q
    $s.Add(@{Op='vmin-h';d=1;s=0;t=28})
    $s.Add(@{Op='vmax-h';d=2;s=0;t=28})
    $s.Add(@{Op='vmpy-h-rnd-sat';d=1;s=1;t=29})
    $s.Add(@{Op='vadd-h';d=0;s=2;t=1})                              # y
    $s.Add(@{Op='vand';d=3;s=0;t=30}); $s.Add(@{Op='vxor';d=3;s=3;t=31})
    $s.Add(@{Op='vasl-h';d=4;s=0;t=8})
    $s.Add(@{Op='vstore';s=1;t=3;Offset=0})
    $s.Add(@{Op='vstore';s=2;t=4;Offset=0})
    $s.Add(@{Op='addi';d=0;s=0;i=128}); $s.Add(@{Op='addi';d=1;s=1;i=128}); $s.Add(@{Op='addi';d=2;s=2;i=128})
    $s.Add(@{Op='addi';d=3;s=3;i=-1})
    $s.Add(@{Op='gtu';d=0;s=3;t=7})
    $s.Add(@{Op='jump-p';u=0;Label=$loop})
    if (-not $NoReturn) { $s.Add(@{Op='return'}) }
    $s.ToArray()
}
