#requires -Version 7.4
# Stock gelu_new (transformers NewGELUActivation, ALBERT hidden_act; 0.5 x (1 + tanh(sqrt(2/pi) (x + 0.044715 x^3))))
# on 16-bit activations (biased u16 native croutons), elementwise, as relu(x) - q(|x|) with q(a) = -gelu_new(-a) >= 0:
#   a = q31(|x| 2^16, Ma)                  Q16 of |x| sIn / Range (Ma = sIn / Range * 2^31), clamped to 65535
#   i = a >> 8, f = a & 255                256 intervals; q(0) = 0 and q(Range) rounds to 0, so i + 1 wraps to 0
#   q = Q[i] + ((Q[i+1] - Q[i]) f >> 8)    Q17 table (|q| < 0.25), the Kokoro.SnakeInteger.ps1 vlut16 lookup
#   y = clamp(q31(max(x, 0) 2^16, Ka) - q31(q 2^16, Kb), +-32767)   Ka = sIn / sOut * 2^15, Kb = 2^-2 / sOut
# Table and interpolation: Invoke-KokoroDevelopment.ps1 New-KokoroGeluTable / Invoke-KokoroGeluTable (the host model of this
# arithmetic). Lookup: V73 HVX PRM 80-N2040-54 Rev AB pp.227-230 (vlut16), table shuffled as Kokoro.SnakeInteger.ps1.
# Structure after MNN 43bc0686 htp-ops-lib/src/dsp/unary_ops.cc (table activation); arithmetic integer.
#
# r0 = input (biased u16), r1 = output (may equal r0), r2 = constants: Ma, Ka, Kb (int32) at 0, 4, 8, then four 128 B
# shuffled table vectors at 128; r3 = number of 128-byte vectors (tiles * C / 32 * 16) >= 1.
# Uses r4..r15, v0..v31; r16..r27 are untouched.
function New-KokoroGelu16Steps {
    param([string]$LabelPrefix='gelu16')
    $s = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL); $s.Add(@{Op='lo';x=$r;i=($u -band 65535)}); $s.Add(@{Op='hi';x=$r;i=($u -shr 16)}) }
    $splat = { param([int]$v,[long]$value) & $imm 13 $value; $s.Add(@{Op='vsplat';d=$v;s=13}) }
    $q31 = { param([int]$d,[int]$x,[int]$k) $s.Add(@{Op='vmpye-w-uh';d=$d;s=$x;t=$k}); $s.Add(@{Op='vmpyo-acc-w-h-rnd-sat-shift';d=$d;s=$x;t=$k}) }
    $s.Add(@{Op='imm';d=8;i=8}); $s.Add(@{Op='imm';d=9;i=16}); $s.Add(@{Op='imm';d=12;i=0})
    & $splat 31 0x80008000L; & $splat 30 0xFFFF0000L; & $splat 29 0x0000FFFFL
    & $splat 27 32767; & $splat 26 -32768; & $splat 4 65535; & $splat 3 255; & $splat 5 1
    $s.Add(@{Op='vxor';d=6;s=6;t=6})
    $s.Add(@{Op='load';d=13;s=2;Offset=0}); $s.Add(@{Op='vsplat';d=10;s=13})      # Ma
    $s.Add(@{Op='load';d=13;s=2;Offset=4}); $s.Add(@{Op='vsplat';d=11;s=13})      # Ka
    $s.Add(@{Op='load';d=13;s=2;Offset=8}); $s.Add(@{Op='vsplat';d=17;s=13})      # Kb
    for ($chunk = 0; $chunk -lt 4; $chunk++) { $s.Add(@{Op='vload';d=(20+$chunk);s=2;Offset=(128+128*$chunk)}) }
    $s.Add(@{Op='addi';d=4;s=0;i=0}); $s.Add(@{Op='addi';d=5;s=1;i=0}); $s.Add(@{Op='addi';d=15;s=3;i=0})
    $s.Add(@{Op='label';Name="${LabelPrefix}_vec"})
    $s.Add(@{Op='vload';d=0;s=4;Offset=0})
    $s.Add(@{Op='vxor';d=0;s=0;t=31})                                              # x (signed halfwords)
    $s.Add(@{Op='vabs-h-sat';d=1;s=0})                                             # |x|
    foreach ($row in 0, 1) {
        $result = if ($row -eq 0) { 7 } else { 8 }
        # Row 2r (even halfwords) or 2r+1 (odd) as words times 2^16.
        if ($row -eq 0) { $s.Add(@{Op='vasl-w';d=2;s=0;t=9}); $s.Add(@{Op='vasl-w';d=9;s=1;t=9}) }
        else { $s.Add(@{Op='vand';d=2;s=0;t=30}); $s.Add(@{Op='vand';d=9;s=1;t=30}) }
        $s.Add(@{Op='vmax-w';d=2;s=2;t=6}); & $q31 12 2 11                            # y1 = relu(x) in output LSB
        & $q31 13 9 10; $s.Add(@{Op='vmin-w';d=13;s=13;t=4})                          # a
        $s.Add(@{Op='vand';d=14;s=13;t=3})                                             # f
        $s.Add(@{Op='vlsr-uw';d=15;s=13;t=8})                                          # i
        $s.Add(@{Op='vadd-w';d=16;s=15;t=5}); $s.Add(@{Op='vand';d=16;s=16;t=3})       # i + 1 (wraps)
        for ($match = 0; $match -lt 16; $match++) {
            $s.Add(@{Op='imm';d=6;i=$match})
            $op = if ($match -eq 0) { 'vlut16' } else { 'vlut16-or' }
            $table = 20 + [int][math]::Floor($match / 4)
            $s.Add(@{Op=$op;d=18;s=15;v=$table;x=6})
            $s.Add(@{Op=$op;d=24;s=16;v=$table;x=6})
        }
        $s.Add(@{Op='vsub-w';d=28;s=24;t=18}); $s.Add(@{Op='vmpyie-w-uh';d=28;s=28;t=14})
        $s.Add(@{Op='vasr-w';d=28;s=28;t=8}); $s.Add(@{Op='vadd-w';d=28;s=28;t=18})    # q (Q17)
        $s.Add(@{Op='vasl-w';d=28;s=28;t=9}); & $q31 13 28 17                          # y2 = q in output LSB
        $s.Add(@{Op='vsub-w';d=$result;s=12;t=13})
        $s.Add(@{Op='vmax-w';d=$result;s=$result;t=26}); $s.Add(@{Op='vmin-w';d=$result;s=$result;t=27})
    }
    $s.Add(@{Op='vand';d=7;s=7;t=29}); $s.Add(@{Op='vasl-w';d=8;s=8;t=9}); $s.Add(@{Op='vor';d=7;s=7;t=8}); $s.Add(@{Op='vxor';d=7;s=7;t=31})
    $s.Add(@{Op='vstore';s=5;t=7;Offset=0})
    $s.Add(@{Op='addi';d=4;s=4;i=128}); $s.Add(@{Op='addi';d=5;s=5;i=128})
    $s.Add(@{Op='addi';d=15;s=15;i=-1}); $s.Add(@{Op='gtu';d=0;s=15;t=12}); $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_vec"})
    $s.Add(@{Op='return'})
    $s.ToArray()
}
