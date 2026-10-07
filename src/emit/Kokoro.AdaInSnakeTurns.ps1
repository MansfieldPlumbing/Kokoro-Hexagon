#requires -Version 7.4
# Fused stock AdaIN1d then Snake over 16-bit activations, emitting the two conv-input byte planes.
# Kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec istftnet.py:20-31 (AdaIN1d) and :68-77 (Snake,
# one alpha inside and outside). AdaIN folds to a per-channel affine of x; with the phase in turns
# P = alpha*y/pi = (K*x + M) / 2^24, stock Snake is
#     s = (pi/alpha) * (P + (1 - cos(2*pi*P)) / (2*pi)).
# The fractional turn of P is the cos argument (wraparound is the range reduction); 1 - cos is
# 1 + sin(pi/2*u), u = 4g - 1 on the half turn |g|, a five-term odd Q14 polynomial in Q15 halfword
# arithmetic. Reference and precision: docs/results/snake-turns-reference-20261007.md.
#
# Layout: native croutons; each 128-byte vector holds a row pair x 32 channels as halfwords, the even
# halfword of word lane j is row 2r and the odd halfword row 2r+1 of channel j.
# r0 input tiles: biased u16 per value (x + 32768).
# r1 high-plane window tiles: u8 = (out >> 8) + 128 in the odd byte of each halfword.
# r2 low-plane window tiles: u8 = out & 255 in the odd byte of each halfword.
# r3 per-channel constants, int32 each: K[C] at 0 (Q31 multiplier of x*2^16, giving Q24 turns),
#    M[C] at 4C (Q24 turns), S[C] at 8C (Q31 multiplier of Q24 turns giving the 16-bit output).
# r4 tiles >= 1. out is clamped to int16 before the plane split. r16..r27 are untouched.
function New-KokoroAdaInSnakeTurnsSteps {
    param([ValidateSet(128,256)][int]$Channels=128,[string]$LabelPrefix='adainsnaketurns',[switch]$NoReturn)
    $q14 = foreach ($k in 1..5) {
        $f = 1.0; for ($i = 1; $i -le 2 * $k - 1; $i++) { $f *= $i }
        [int][math]::Round([math]::Pow(-1, $k - 1) * [math]::Pow([math]::PI / 2, 2 * $k - 1) / $f * 16384)
    }
    $s = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL); $s.Add(@{Op='lo';x=$r;i=($u -band 65535)}); $s.Add(@{Op='hi';x=$r;i=($u -shr 16)}) }
    $splat = { param([int]$v,[long]$value) & $imm 13 $value; $s.Add(@{Op='vsplat';d=$v;s=13}) }
    $half = { param([int]$h) [long](($h -band 0xffff) -bor (($h -band 0xffff) -shl 16)) }
    # Resident constants.
    & $splat 31 0x80008000L                     # u16 bias
    & $splat 30 0xFFFF0000L                     # odd-halfword mask
    & $splat 29 0x0000FFFFL                     # even-halfword mask
    & $splat 28 (& $half 16384)                 # 1.0 in Q14
    for ($k = 0; $k -lt 5; $k++) { & $splat (23 + $k) (& $half $q14[$k]) }   # v23 = h0 ... v27 = h4
    & $splat 22 10430                           # round(2^16 / (2*pi)) in each even halfword
    & $splat 21 128
    & $splat 20 255
    & $splat 18 32767
    & $splat 17 -32768
    foreach ($kv in @(@(8,16),@(9,8),@(10,1),@(11,6),@(12,24),@(7,0))) { $s.Add(@{Op='imm';d=$kv[0];i=$kv[1]}) }
    for ($block = 0; $block -lt ($Channels / 32); $block++) {
        $s.Add(@{Op='addi';d=6;s=3;i=($block*128)})
        $s.Add(@{Op='vload';d=14;s=6;Offset=0})
        $s.Add(@{Op='addi';d=6;s=6;i=($Channels*4)})
        $s.Add(@{Op='vload';d=15;s=6;Offset=0})
        $s.Add(@{Op='addi';d=6;s=6;i=($Channels*4)})
        $s.Add(@{Op='vload';d=16;s=6;Offset=0})
        $s.Add(@{Op='addi';d=5;s=0;i=($block*2048)})
        $s.Add(@{Op='addi';d=6;s=1;i=($block*2048)})
        $s.Add(@{Op='addi';d=13;s=2;i=($block*2048)})
        $s.Add(@{Op='addi';d=15;s=4;i=0})
        $tile = "${LabelPrefix}_b${block}_tile"; $pair = "${LabelPrefix}_b${block}_pair"
        $s.Add(@{Op='label';Name=$tile})
        $s.Add(@{Op='imm';d=14;i=16})
        $s.Add(@{Op='label';Name=$pair})
        $s.Add(@{Op='vload';d=0;s=5;Offset=0})
        $s.Add(@{Op='vxor';d=0;s=0;t=31})                       # signed halfwords
        $s.Add(@{Op='vasl-w';d=1;s=0;t=8})                      # even row x * 2^16
        $s.Add(@{Op='vand';d=2;s=0;t=30})                       # odd row  x * 2^16
        foreach ($p in @(@(3,1),@(4,2))) {                      # P = K*x*2^16 >> 31 + M, Q24 turns
            $s.Add(@{Op='vmpye-w-uh';d=$p[0];s=$p[1];t=14})
            $s.Add(@{Op='vmpyo-acc-w-h-rnd-sat-shift';d=$p[0];s=$p[1];t=14})
            $s.Add(@{Op='vadd-w';d=$p[0];s=$p[0];t=15})
        }
        # 16-bit fractional turn of both rows in one halfword vector.
        $s.Add(@{Op='vlsr-uw';d=5;s=3;t=9}); $s.Add(@{Op='vand';d=5;s=5;t=29})
        $s.Add(@{Op='vasl-w';d=6;s=4;t=9});  $s.Add(@{Op='vand';d=6;s=6;t=30})
        $s.Add(@{Op='vor';d=5;s=5;t=6})
        $s.Add(@{Op='vabs-h-sat';d=5;s=5})                      # fold onto [0, 1/2) turn
        $s.Add(@{Op='vsub-h';d=5;s=5;t=28})
        $s.Add(@{Op='vasl-h';d=5;s=5;t=10})                     # u = 4g - 1, Q15
        $s.Add(@{Op='vmpy-h-rnd-sat';d=6;s=5;t=5})              # z = u^2
        $s.Add(@{Op='vmpy-h-rnd-sat';d=7;s=27;t=6}); $s.Add(@{Op='vadd-h';d=7;s=7;t=26})
        foreach ($c in 25,24,23) { $s.Add(@{Op='vmpy-h-rnd-sat';d=7;s=7;t=6}); $s.Add(@{Op='vadd-h';d=7;s=7;t=$c}) }
        $s.Add(@{Op='vmpy-h-rnd-sat';d=7;s=7;t=5})              # sin(pi/2 u), Q14
        $s.Add(@{Op='vadd-h-sat';d=7;s=7;t=28})                 # 1 - cos, Q14
        # Back to words per row, scale (1 - cos)/(2 pi) into Q24 turns, add to P.
        $s.Add(@{Op='vasl-w';d=8;s=7;t=8}); $s.Add(@{Op='vasr-w';d=8;s=8;t=8})
        $s.Add(@{Op='vasr-w';d=9;s=7;t=8})
        foreach ($p in @(@(8,3),@(9,4))) {
            $s.Add(@{Op='vmpyie-w-uh';d=$p[0];s=$p[0];t=22})
            $s.Add(@{Op='vasr-w';d=$p[0];s=$p[0];t=11})
            $s.Add(@{Op='vadd-w';d=$p[1];s=$p[1];t=$p[0]})
        }
        foreach ($p in @(@(10,3),@(11,4))) {                    # out = V*S >> 31, clamped to int16
            $s.Add(@{Op='vmpye-w-uh';d=$p[0];s=$p[1];t=16})
            $s.Add(@{Op='vmpyo-acc-w-h-rnd-sat-shift';d=$p[0];s=$p[1];t=16})
            $s.Add(@{Op='vmax-w';d=$p[0];s=$p[0];t=17})
            $s.Add(@{Op='vmin-w';d=$p[0];s=$p[0];t=18})
        }
        # High plane: (out >> 8) + 128 into the odd byte of each halfword.
        $s.Add(@{Op='vasr-w';d=12;s=10;t=9}); $s.Add(@{Op='vadd-w';d=12;s=12;t=21}); $s.Add(@{Op='vasl-w';d=12;s=12;t=9})
        $s.Add(@{Op='vasr-w';d=13;s=11;t=9}); $s.Add(@{Op='vadd-w';d=13;s=13;t=21}); $s.Add(@{Op='vasl-w';d=13;s=13;t=12})
        $s.Add(@{Op='vor';d=12;s=12;t=13})
        $s.Add(@{Op='vstore';s=6;t=12;Offset=0})
        # Low plane: out & 255 into the odd byte of each halfword.
        $s.Add(@{Op='vand';d=10;s=10;t=20}); $s.Add(@{Op='vasl-w';d=10;s=10;t=9})
        $s.Add(@{Op='vand';d=11;s=11;t=20}); $s.Add(@{Op='vasl-w';d=11;s=11;t=12})
        $s.Add(@{Op='vor';d=10;s=10;t=11})
        $s.Add(@{Op='vstore';s=13;t=10;Offset=0})
        $s.Add(@{Op='addi';d=5;s=5;i=128}); $s.Add(@{Op='addi';d=6;s=6;i=128}); $s.Add(@{Op='addi';d=13;s=13;i=128})
        $s.Add(@{Op='addi';d=14;s=14;i=-1})
        $s.Add(@{Op='gtu';d=0;s=14;t=7})
        $s.Add(@{Op='jump-p';u=0;Label=$pair})
        $s.Add(@{Op='addi';d=5;s=5;i=($Channels*64-2048)}); $s.Add(@{Op='addi';d=6;s=6;i=($Channels*64-2048)}); $s.Add(@{Op='addi';d=13;s=13;i=($Channels*64-2048)})
        $s.Add(@{Op='addi';d=15;s=15;i=-1})
        $s.Add(@{Op='gtu';d=0;s=15;t=7})
        $s.Add(@{Op='jump-p';u=0;Label=$tile})
    }
    if (-not $NoReturn) { $s.Add(@{Op='return'}) }
    $s.ToArray()
}
