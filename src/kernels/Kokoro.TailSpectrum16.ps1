#requires -Version 7.4
# Stock generator tail spectrum: spec = exp(x[:11]), phase = sin(x[11:]), and the complex bins
# spec * exp(i phase) that TorchSTFT.inverse hands to torch.istft (Kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec
# istftnet.py Generator.forward and TorchSTFT.inverse), from 16-bit conv_post logits, as the two conv-input
# byte planes of the iSTFT conv (Re_k in block 0 lane k, Im_k in block 1 lane k).
#
# conv_post's output channels are placed so magnitude bin k is channel k (fine: a window clipped to about +-10)
# and channel 11 + k (coarse: the full calibrated range), and phase bin k channel 32 + k
# (tools/New-KokoroGeneratorTail16Fixture.ps1). The coarse lanes are rotated onto lane k (valign by 44 bytes) and
# w = min(w_fine, w_coarse + delta): in range the two agree within delta and the fine value wins; where the fine
# window saturates, the true logit is below the clip and the coarse value (exp below a spectrum LSB) wins.
# Per value (v = signed logit, units u_k per lane):
#   w = (v * 2^16 * Ke_k) >> 31 + Be_k     Q16 of log2(spec / sS): Ke = u log2(e) 2^31, Be = -log2(sS) 2^16
#                                          (fine; the coarse lane uses Kc_k, Bc_k with delta folded in);
#                                          clamped to < 15 (spec / sS < 2^15)
#   m = 2^frac(w)                          Q14, Taylor polynomial of 2^f - 1 (degree 6) in Q15
#   P = (v' * 2^16 * Kp_k) >> 31 + Mp_k    Q24 turns of the phase logit plus a quarter turn
#   a = sin(phase logit) = -cos(2 pi P)    the phase-turns polynomial of Kokoro.AdaInSnakeTurns.ps1, Q15
#   cos a, sin a                           Taylor polynomials (|a| <= 1), Q15
#   Re = round(m cos a 2^(n - 14)), Im likewise with sin a, n = floor(w): a per-lane shift by
#        s = clamp(14 - n, 0, 16) (vasr with a vector of amounts), so Re, Im are spec * (cos, sin) / sS.
# Lanes 11..31 carry no bins (their constants are zero; the iSTFT conv weights for them are zero).
#
# r0 logit tiles (64 channels, biased u16, 4096 B per tile), r1 high-plane tiles, r2 low-plane tiles (same
# addressing), r3 constants (Get-KokoroTailSpectrumConstants: 48 vectors; per-lane Ke, Be, Kp, Mp at 0..3, Kc, Bc at 35, 36),
# r4 tiles >= 1. Caller-saved registers only.

function Get-KokoroTailSpectrumConstants {
    # The 48-vector constant record with zero per-lane vectors 0..3, 35, 36 (the fixture writes those).
    $v = [byte[]]::new(48 * 128)
    $word = { param([int]$index,[long]$value) $b = [BitConverter]::GetBytes([uint32]($value -band 0xffffffffL)); for ($i = 0; $i -lt 32; $i++) { [Array]::Copy($b, 0, $v, 128 * $index + 4 * $i, 4) } }
    $half = { param([int]$index,[int]$value) & $word $index ((([long]$value -band 0xffff) -shl 16) -bor ([long]$value -band 0xffff)) }
    $fact = { param([int]$n) $f = 1.0; for ($i = 2; $i -le $n; $i++) { $f *= $i }; $f }
    for ($k = 1; $k -le 6; $k++) { & $half (3 + $k) ([int][math]::Round([math]::Pow([math]::Log(2), $k) / (& $fact $k) * 32768)) }   # 4..9: e1..e6
    for ($k = 1; $k -le 4; $k++) { & $half (9 + $k) ([int][math]::Round([math]::Pow(-1, $k) / (& $fact (2 * $k)) * 32768)) }       # 10..13: cos c1..c4
    for ($k = 1; $k -le 3; $k++) { & $half (13 + $k) ([int][math]::Round([math]::Pow(-1, $k) / (& $fact (2 * $k + 1)) * 32768)) }  # 14..16: sin d1..d3
    & $word 17 0x00007FFFL; & $word 18 0x7FFF0000L; & $word 19 (15L * 65536 - 1); & $word 20 29; & $word 21 15; & $word 22 31; & $word 23 1
    & $word 24 0xFF00FF00L; & $word 25 0x7FFF7FFFL; & $word 26 0x80008000L; & $word 27 0xFFFF0000L; & $word 28 0x0000FFFFL; & $half 29 16384
    for ($k = 1; $k -le 5; $k++) {                                                                                                  # 30..34: sin(pi/2 u) h0..h4, Q14
        & $half (29 + $k) ([int][math]::Round([math]::Pow(-1, $k - 1) * [math]::Pow([math]::PI / 2, 2 * $k - 1) / (& $fact (2 * $k - 1)) * 16384))
    }
    , $v
}

function New-KokoroTailSpectrum16Steps {
    param([string]$LabelPrefix='tailspectrum16',[switch]$NoReturn)
    $s = [Collections.Generic.List[hashtable]]::new()
    # Constant vector k: r5 = r3 + 1024 (k 0..15), r6 = r3 + 3072 (16..31), r7 = r3 + 5120 (32..47).
    $c = { param([int]$d,[int]$k) $base = if ($k -lt 16) { 5 } elseif ($k -lt 32) { 6 } else { 7 }; $center = @{5=8;6=24;7=40}[$base]; $s.Add(@{Op='vload';d=$d;s=$base;Offset=(128*($k-$center))}) }
    $mpy = { param([int]$d,[int]$a,[int]$b) $s.Add(@{Op='vmpy-h-rnd-sat';d=$d;s=$a;t=$b}) }
    $s.Add(@{Op='addi';d=5;s=3;i=1024}); $s.Add(@{Op='addi';d=6;s=3;i=3072}); $s.Add(@{Op='addi';d=7;s=3;i=5120})
    foreach ($kv in @(@(8,16),@(9,8),@(10,1),@(11,15),@(13,0))) { $s.Add(@{Op='imm';d=$kv[0];i=$kv[1]}) }
    $s.Add(@{Op='imm';d=3;i=44})                               # coarse lane k + 11 -> lane k (bytes)
    # Resident: v31 bias, v30 odd-halfword mask, v29 even mask, v28 16384, v27..v23 sin(pi/2 u) h4..h0,
    # v16 Ke, v17 Be, v18 Kp, v19 Mp, v20 32767, v21 word 1.
    & $c 31 26; & $c 30 27; & $c 29 28; & $c 28 29
    for ($k = 0; $k -lt 5; $k++) { & $c (23 + $k) (30 + $k) }
    for ($k = 0; $k -lt 4; $k++) { & $c (16 + $k) $k }
    & $c 20 25; & $c 21 23
    # Q31 multiply of the two rows: words x * 2^16 (even, odd) by the lane constant, plus the lane offset.
    $rows = { param([int]$src,[int]$k,[int]$m,[int]$de,[int]$do)
        $s.Add(@{Op='vasl-w';d=2;s=$src;t=8}); $s.Add(@{Op='vand';d=3;s=$src;t=30})
        foreach ($p in @(@($de,2),@($do,3))) {
            $s.Add(@{Op='vmpye-w-uh';d=$p[0];s=$p[1];t=$k})
            $s.Add(@{Op='vmpyo-acc-w-h-rnd-sat-shift';d=$p[0];s=$p[1];t=$k})
            $s.Add(@{Op='vadd-w';d=$p[0];s=$p[0];t=$m})
        }
    }
    $s.Add(@{Op='label';Name="${LabelPrefix}_tile"})
    $s.Add(@{Op='imm';d=12;i=16})
    $s.Add(@{Op='label';Name="${LabelPrefix}_pair"})
    $s.Add(@{Op='vload';d=0;s=0;Offset=0})
    $s.Add(@{Op='addi';d=14;s=0;i=2048}); $s.Add(@{Op='vload';d=1;s=14;Offset=0})
    $s.Add(@{Op='vxor';d=0;s=0;t=31}); $s.Add(@{Op='vxor';d=1;s=1;t=31})
    # Magnitude: w (v4 even row, v5 odd row) = min(fine, coarse + delta), clamped below 15.
    & $rows 0 16 17 4 5
    $s.Add(@{Op='valign';d=10;s=0;t=0;r=3})
    & $c 11 35; & $c 12 36
    & $rows 10 11 12 6 7
    $s.Add(@{Op='vmin-w';d=4;s=4;t=6}); $s.Add(@{Op='vmin-w';d=5;s=5;t=7})
    & $c 6 19; $s.Add(@{Op='vmin-w';d=4;s=4;t=6}); $s.Add(@{Op='vmin-w';d=5;s=5;t=6})
    # f = frac(w) in Q15 halfwords: even row (w >> 1) & 0x7FFF, odd row (w << 15) & 0x7FFF0000.
    $s.Add(@{Op='vlsr-uw';d=6;s=4;t=10}); & $c 7 17; $s.Add(@{Op='vand';d=6;s=6;t=7})
    $s.Add(@{Op='vasl-w';d=8;s=5;t=11}); & $c 7 18; $s.Add(@{Op='vand';d=8;s=8;t=7})
    $s.Add(@{Op='vor';d=6;s=6;t=8})
    # m = 2^f in Q14: p = 2^f - 1 (Q15 Horner, e6 .. e1), m = 16384 + p / 2.
    & $c 7 9
    # Saturating: near f = 1 the inner sums reach 1.0 (32768 in Q15).
    foreach ($k in 8,7,6,5,4) { & $mpy 7 7 6; & $c 8 $k; $s.Add(@{Op='vadd-h-sat';d=7;s=7;t=8}) }
    & $mpy 7 7 6
    $s.Add(@{Op='vasr-h';d=7;s=7;t=10}); $s.Add(@{Op='vadd-h';d=7;s=7;t=28})
    # Shift amounts s + 15 = clamp(29 - floor(w), 15, 31) per row word: v8 even, v9 odd.
    foreach ($p in @(@(8,4),@(9,5))) {
        $s.Add(@{Op='vasr-w';d=$p[0];s=$p[1];t=8}); & $c 10 20; $s.Add(@{Op='vsub-w';d=$p[0];s=10;t=$p[0]})
        & $c 10 21; $s.Add(@{Op='vmax-w';d=$p[0];s=$p[0];t=10}); & $c 10 22; $s.Add(@{Op='vmin-w';d=$p[0];s=$p[0];t=10})
    }
    # Phase: P (v4, v5) in Q24 turns with the quarter turn; 16-bit fractional turn of both rows in v10.
    & $rows 1 18 19 4 5
    $s.Add(@{Op='vlsr-uw';d=10;s=4;t=9}); $s.Add(@{Op='vand';d=10;s=10;t=29})
    $s.Add(@{Op='vasl-w';d=11;s=5;t=9}); $s.Add(@{Op='vand';d=11;s=11;t=30})
    $s.Add(@{Op='vor';d=10;s=10;t=11})
    # -cos(2 pi P) = sin(pi/2 u), u = 4|g| - 1 (as Kokoro.AdaInSnakeTurns.ps1), Q14; a = 2 * that, Q15.
    $s.Add(@{Op='vabs-h-sat';d=10;s=10}); $s.Add(@{Op='vsub-h';d=10;s=10;t=28}); $s.Add(@{Op='vasl-h';d=10;s=10;t=10})
    & $mpy 11 10 10
    & $mpy 12 27 11; $s.Add(@{Op='vadd-h';d=12;s=12;t=26})
    foreach ($k in 25,24,23) { & $mpy 12 12 11; $s.Add(@{Op='vadd-h';d=12;s=12;t=$k}) }
    & $mpy 12 12 10
    $s.Add(@{Op='vadd-h-sat';d=12;s=12;t=12})
    # cos a = 1 + z (c1 + z (c2 + z (c3 + z c4))) with 1 as 32767; sin a = a + a z (d1 + z (d2 + z d3)).
    & $mpy 11 12 12
    & $c 13 13; foreach ($k in 12,11,10) { & $mpy 13 13 11; & $c 14 $k; $s.Add(@{Op='vadd-h';d=13;s=13;t=14}) }
    & $mpy 13 13 11; $s.Add(@{Op='vadd-h-sat';d=13;s=13;t=20})
    & $c 14 16; foreach ($k in 15,14) { & $mpy 14 14 11; & $c 15 $k; $s.Add(@{Op='vadd-h';d=14;s=14;t=15}) }
    & $mpy 14 14 11; & $mpy 14 14 12; $s.Add(@{Op='vadd-h-sat';d=14;s=14;t=12})
    # Re = m cos a, Im = m sin a (Q14), then the per-lane exponent shift with rounding, and the planes.
    & $mpy 13 7 13; & $mpy 14 7 14
    foreach ($part in @(@(13,0),@(14,2048))) {
        $v = $part[0]
        $s.Add(@{Op='vasl-w';d=2;s=$v;t=8}); $s.Add(@{Op='vand';d=3;s=$v;t=30})
        $s.Add(@{Op='vasr-wv';d=2;s=2;t=8}); $s.Add(@{Op='vasr-wv';d=3;s=3;t=9})
        $s.Add(@{Op='vadd-w';d=2;s=2;t=21}); $s.Add(@{Op='vadd-w';d=3;s=3;t=21})
        $s.Add(@{Op='vasr-w';d=2;s=2;t=10}); $s.Add(@{Op='vasr-w';d=3;s=3;t=10})
        $s.Add(@{Op='vand';d=2;s=2;t=29}); $s.Add(@{Op='vasl-w';d=3;s=3;t=8}); $s.Add(@{Op='vor';d=2;s=2;t=3})
        & $c 3 24; $s.Add(@{Op='vand';d=4;s=2;t=3}); $s.Add(@{Op='vxor';d=4;s=4;t=31})
        $s.Add(@{Op='vasl-h';d=5;s=2;t=9})
        $s.Add(@{Op='addi';d=14;s=1;i=$part[1]}); $s.Add(@{Op='vstore';s=14;t=4;Offset=0})
        $s.Add(@{Op='addi';d=15;s=2;i=$part[1]}); $s.Add(@{Op='vstore';s=15;t=5;Offset=0})
    }
    $s.Add(@{Op='addi';d=0;s=0;i=128}); $s.Add(@{Op='addi';d=1;s=1;i=128}); $s.Add(@{Op='addi';d=2;s=2;i=128})
    $s.Add(@{Op='addi';d=12;s=12;i=-1})
    $s.Add(@{Op='gtu';d=0;s=12;t=13})
    $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_pair"})
    $s.Add(@{Op='addi';d=0;s=0;i=2048}); $s.Add(@{Op='addi';d=1;s=1;i=2048}); $s.Add(@{Op='addi';d=2;s=2;i=2048})
    $s.Add(@{Op='addi';d=4;s=4;i=-1})
    $s.Add(@{Op='gtu';d=0;s=4;t=13})
    $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_tile"})
    if (-not $NoReturn) { $s.Add(@{Op='return'}) }
    $s.ToArray()
}
