#requires -Version 7.4
# Stock harmonic source, merged (Kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec istftnet.py SineGen with
# upsample_scale 300, harmonic_num 8, sine_amp 0.1, noise_std 0.003, voiced_threshold 10; SourceModuleHnNSF l_linear 9 -> 1
# and tanh), at 24 kHz from the frame-rate f0, in closed form (checked against stock captures: 62 dB, the stock float32
# phase rounding):
#   phase of harmonic h at sample j = h Psi(j) turns, Psi = the align_corners-False linear interpolation (clamped) over
#   frames of P_k = sum_{m <= k} 300 inc_m, inc_m = f0_m / 24000 turns per sample. So Psi is P_0 for j < 150, then per
#   segment k (j = 300 k + 150 + n, n < 300) P_k + (n + 1/2) inc_(k+1), and P_(L-1) from 300 (L - 1) + 150. SineGen's
#   random initial phase is added at sample 0 only and never reaches the frame-rate interpolation.
#   Where f0_(k+1) < 0, stock's (f0 h / 24000) % 1 adds one turn per sample to every harmonic in segment k, which with the
#   half-sample offset is half a turn: the segment's sines change sign (a per-sample sign mask).
#   merged = tanh(b + sum_h w_h (0.1 sin(2 pi h Psi) uv + n_h)), uv = f0 > 10 (nearest-upsampled), n_h = amp(uv) g_h,
#   amp = 0.003 (voiced) or 0.1 / 3; the noise enters as z = sum_h w_h g_h (an input stream, Q12; one Gaussian in
#   distribution) times amp.
# Formats: f0 Q16 Hz (int32); Psi Q32 turns (wrapping); the harmonic phase's top 16 bits as a turn plus a quarter turn
# into the Q15 polynomial for -cos(2 pi x) (as Kokoro.TailSpectrum16.ps1); sums and the output in Q15 (merge unit 2^-15).

function Get-KokoroHarmonicSourceConstants {
    # 4096-byte record. Words 0..3 (scalar): M = round(2^40 / 24000) (inc = (f0_Q16 M) >> 24), the voiced threshold
    # 10 Hz in Q16, amp voiced and unvoiced as Q15 x 8 halfwords (z is Q12). Vectors from byte 128 (index v at 128 + 128 v):
    # 0..8 harmonic h + 1 as a word splat, 9..17 c_h = 0.1 w_h (Q15 halfwords, the fixture writes them), 18 b (Q15,
    # fixture), 19..23 sin(pi/2 u) polynomial h0..h4 (Q14), 24 16384, 25 0x4000 (quarter turn), 26..28 tanh t1..t3 (Q15),
    # 29 0x0000FFFF, 30 0xFFFF0000.
    $v = [byte[]]::new(4096)
    $put = { param([int]$at,[long]$value) [BitConverter]::GetBytes([uint32]($value -band 0xffffffffL)).CopyTo($v, $at) }
    $word = { param([int]$index,[long]$value) for ($l = 0; $l -lt 32; $l++) { & $put (128 + 128 * $index + 4 * $l) $value } }
    $half = { param([int]$index,[int]$value) & $word $index ((([long]$value -band 0xffff) -shl 16) -bor ([long]$value -band 0xffff)) }
    $fact = { param([int]$n) $f = 1.0; for ($i = 2; $i -le $n; $i++) { $f *= $i }; $f }
    & $put 0 ([long][math]::Round([math]::Pow(2, 40) / 24000)); & $put 4 (10L * 65536)
    & $put 8 ([long][math]::Round(0.003 * 8 * 32768)); & $put 12 ([long][math]::Round(0.1 / 3 * 8 * 32768))
    for ($h = 1; $h -le 9; $h++) { & $word ($h - 1) $h }
    for ($k = 1; $k -le 5; $k++) { & $half (18 + $k) ([int][math]::Round([math]::Pow(-1, $k - 1) * [math]::Pow([math]::PI / 2, 2 * $k - 1) / (& $fact (2 * $k - 1)) * 16384)) }
    & $half 24 16384; & $half 25 0x4000
    & $half 26 ([int][math]::Round(-1 / 3 * 32768)); & $half 27 ([int][math]::Round(2 / 15 * 32768)); & $half 28 ([int][math]::Round(-17 / 315 * 32768))
    & $word 29 0x0000FFFFL; & $word 30 0xFFFF0000L
    , $v
}

# Scalar: f0 frames -> Psi (even samples at r2, odd at r3, word each, so a 64-sample block is one vector of each) and
# per-sample halfword masks: uv (0xFFFF voiced) at r4, sign (0xFFFF where the sines change sign) at r4 + r5, amp at
# r4 + 2 r5. r0 f0 (int32 Q16, L frames), r1 L >= 2, r5 bytes per halfword array, r6 constants record. Samples 300 L.
function New-KokoroSourcePhaseSteps {
    param([string]$LabelPrefix='sourcephase',[switch]$NoReturn)
    $s = [Collections.Generic.List[hashtable]]::new()
    $lbl = { param([string]$n) "${LabelPrefix}_$n" }
    $s.Add(@{Op='load';d=7;s=6;Offset=0})                                  # r7 M
    $s.Add(@{Op='imm';d=13;i=0})                                            # r13 zero
    # inc of frame at r0 + 4 m: r8 = (f0 M) >> 24; r12 = 0 or -1 (f0 < 0) replicated as two halfwords.
    # (The product goes to r11:r10 so that r9 keeps P_k; r12 is free between segments.)
    $incOf = { param([int]$off) $s.Add(@{Op='load';d=12;s=0;Offset=$off}); $s.Add(@{Op='mpy-d';d=10;s=12;t=7}); $s.Add(@{Op='asr-d-i';d=10;s=10;i=24}); $s.Add(@{Op='addi';d=8;s=10;i=0}); $s.Add(@{Op='asr-i';d=12;s=12;i=31}) }
    # Store r9 (even sample) and r9 + r8 (odd) at r2/r3 + 2 j (r14 = 2 j bytes), the sign word at r4 + r5 + 2 j.
    & $incOf 0
    $s.Add(@{Op='imm';d=11;i=300}); $s.Add(@{Op='mpy-d';d=10;s=8;t=11})      # r10 = 300 inc_0 (low word)
    $s.Add(@{Op='addi';d=9;s=10;i=0})                                       # r9 = P_0
    # Head: 150 samples (75 pairs) at Psi = P_0, sign 0.
    $s.Add(@{Op='imm';d=14;i=0}); $s.Add(@{Op='imm';d=15;i=75})
    $s.Add(@{Op='label';Name=(& $lbl 'head')})
    $s.Add(@{Op='add';d=10;s=2;t=14}); $s.Add(@{Op='store';s=10;t=9;Offset=0})
    $s.Add(@{Op='add';d=10;s=3;t=14}); $s.Add(@{Op='store';s=10;t=9;Offset=0})
    $s.Add(@{Op='add';d=10;s=4;t=5}); $s.Add(@{Op='add';d=10;s=10;t=14}); $s.Add(@{Op='store';s=10;t=13;Offset=0})
    $s.Add(@{Op='addi';d=14;s=14;i=4}); $s.Add(@{Op='addi';d=15;s=15;i=-1}); $s.Add(@{Op='gtu';d=0;s=15;t=13}); $s.Add(@{Op='jump-p';u=0;Label=(& $lbl 'head')})
    # Segments k = 0 .. L - 2: r9 holds P_k on entry; frame pointer r0 advances.
    $s.Add(@{Op='addi';d=1;s=1;i=-1})
    $s.Add(@{Op='label';Name=(& $lbl 'segment')})
    $s.Add(@{Op='addi';d=0;s=0;i=4})
    & $incOf 0
    $s.Add(@{Op='asr-i';d=10;s=8;i=1}); $s.Add(@{Op='add';d=11;s=9;t=10})   # r11 = P_k + inc / 2
    $s.Add(@{Op='imm';d=15;i=150})
    $s.Add(@{Op='label';Name=(& $lbl 'pair')})
    $s.Add(@{Op='add';d=10;s=2;t=14}); $s.Add(@{Op='store';s=10;t=11;Offset=0})
    $s.Add(@{Op='add';d=11;s=11;t=8})
    $s.Add(@{Op='add';d=10;s=3;t=14}); $s.Add(@{Op='store';s=10;t=11;Offset=0})
    $s.Add(@{Op='add';d=11;s=11;t=8})
    $s.Add(@{Op='add';d=10;s=4;t=5}); $s.Add(@{Op='add';d=10;s=10;t=14}); $s.Add(@{Op='store';s=10;t=12;Offset=0})
    $s.Add(@{Op='addi';d=14;s=14;i=4}); $s.Add(@{Op='addi';d=15;s=15;i=-1}); $s.Add(@{Op='gtu';d=0;s=15;t=13}); $s.Add(@{Op='jump-p';u=0;Label=(& $lbl 'pair')})
    # P_(k+1) = P_k + 300 inc_(k+1).
    $s.Add(@{Op='imm';d=11;i=300}); $s.Add(@{Op='mpy-d';d=10;s=8;t=11}); $s.Add(@{Op='add';d=9;s=9;t=10})
    $s.Add(@{Op='addi';d=1;s=1;i=-1}); $s.Add(@{Op='gtu';d=0;s=1;t=13}); $s.Add(@{Op='jump-p';u=0;Label=(& $lbl 'segment')})
    # Tail: 150 samples at P_(L-1).
    $s.Add(@{Op='imm';d=15;i=75})
    $s.Add(@{Op='label';Name=(& $lbl 'tail')})
    $s.Add(@{Op='add';d=10;s=2;t=14}); $s.Add(@{Op='store';s=10;t=9;Offset=0})
    $s.Add(@{Op='add';d=10;s=3;t=14}); $s.Add(@{Op='store';s=10;t=9;Offset=0})
    $s.Add(@{Op='add';d=10;s=4;t=5}); $s.Add(@{Op='add';d=10;s=10;t=14}); $s.Add(@{Op='store';s=10;t=13;Offset=0})
    $s.Add(@{Op='addi';d=14;s=14;i=4}); $s.Add(@{Op='addi';d=15;s=15;i=-1}); $s.Add(@{Op='gtu';d=0;s=15;t=13}); $s.Add(@{Op='jump-p';u=0;Label=(& $lbl 'tail')})
    if (-not $NoReturn) { $s.Add(@{Op='return'}) }
    $s.ToArray()
}

# Scalar: per frame m (300 samples) the uv and amp halfwords: uv word = (thr - f0) >> 31 (all ones when f0 > 10 Hz),
# amp = uv ? ampV : ampU (a per-half select), each replicated in both halves of a word. r0 f0, r1 L, r4 halfword arrays, r5 bytes
# per array, r6 constants record.
function New-KokoroSourceVoicingSteps {
    param([string]$LabelPrefix='sourcevoicing',[switch]$NoReturn)
    $s = [Collections.Generic.List[hashtable]]::new()
    $s.Add(@{Op='load';d=7;s=6;Offset=4}); $s.Add(@{Op='load';d=8;s=6;Offset=8}); $s.Add(@{Op='load';d=9;s=6;Offset=12})
    # amp = (uv & ampV) | (~uv & ampU), each amplitude replicated in both halfwords (a select: no carry between halves).
    $s.Add(@{Op='asl-i';d=10;s=8;i=16}); $s.Add(@{Op='or';d=8;s=8;t=10})      # r8 ampV in both halves
    $s.Add(@{Op='asl-i';d=10;s=9;i=16}); $s.Add(@{Op='or';d=9;s=9;t=10})      # r9 ampU in both halves
    $s.Add(@{Op='imm';d=13;i=0}); $s.Add(@{Op='addi';d=14;s=4;i=0})          # r14 uv cursor
    $s.Add(@{Op='label';Name="${LabelPrefix}_frame"})
    $s.Add(@{Op='load';d=10;s=0;Offset=0}); $s.Add(@{Op='sub';d=10;s=7;t=10}); $s.Add(@{Op='asr-i';d=10;s=10;i=31})   # r10 uv word
    $s.Add(@{Op='and';d=11;s=10;t=8}); $s.Add(@{Op='imm';d=12;i=-1}); $s.Add(@{Op='xor';d=12;s=10;t=12}); $s.Add(@{Op='and';d=12;s=12;t=9}); $s.Add(@{Op='or';d=11;s=11;t=12})   # r11 amp word
    $s.Add(@{Op='imm';d=15;i=150})
    $s.Add(@{Op='label';Name="${LabelPrefix}_pair"})
    $s.Add(@{Op='store';s=14;t=10;Offset=0})
    $s.Add(@{Op='add';d=12;s=14;t=5}); $s.Add(@{Op='add';d=12;s=12;t=5}); $s.Add(@{Op='store';s=12;t=11;Offset=0})
    $s.Add(@{Op='addi';d=14;s=14;i=4}); $s.Add(@{Op='addi';d=15;s=15;i=-1}); $s.Add(@{Op='gtu';d=0;s=15;t=13}); $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_pair"})
    $s.Add(@{Op='addi';d=0;s=0;i=4}); $s.Add(@{Op='addi';d=1;s=1;i=-1}); $s.Add(@{Op='gtu';d=0;s=1;t=13}); $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_frame"})
    if (-not $NoReturn) { $s.Add(@{Op='return'}) }
    $s.ToArray()
}

# HVX, 64 samples per block: merged source (Q15) to r5. r0 Psi even, r1 Psi odd, r2 uv halfwords (sign at r2 + r3, amp
# at r2 + 2 r3), r3 bytes per halfword array, r4 z (Q12 halfwords), r5 output (128-byte aligned), r6 constants record,
# r7 blocks >= 1. Caller-saved registers only.
function New-KokoroSourceMergeSteps {
    param([string]$LabelPrefix='sourcemerge',[switch]$NoReturn)
    $s = [Collections.Generic.List[hashtable]]::new()
    # Constant vector k (0..29) at r6 + 128 + 128 k: base r10 = r6 + 1152 (k - 8 in -8..7), r11 = r6 + 3200 (k - 24).
    $c = { param([int]$d,[int]$k) if ($k -le 15) { $s.Add(@{Op='vload';d=$d;s=10;Offset=(128*($k-8))}) } else { $s.Add(@{Op='vload';d=$d;s=11;Offset=(128*($k-24))}) } }
    $mpy = { param([int]$d,[int]$a,[int]$b) $s.Add(@{Op='vmpy-h-rnd-sat';d=$d;s=$a;t=$b}) }
    $s.Add(@{Op='addi';d=10;s=6;i=1152}); $s.Add(@{Op='addi';d=11;s=6;i=3200})
    $s.Add(@{Op='add';d=8;s=2;t=3}); $s.Add(@{Op='add';d=9;s=8;t=3})          # r8 sign, r9 amp cursors
    $s.Add(@{Op='imm';d=12;i=16}); $s.Add(@{Op='imm';d=13;i=1}); $s.Add(@{Op='imm';d=15;i=0})
    # Resident: v31 0xFFFF0000, v30 16384, v29 quarter turn, v24..v28 h4..h0.
    & $c 30 24; & $c 29 25
    for ($k = 0; $k -lt 5; $k++) { & $c (28 - $k) (19 + $k) }               # v28 h0 .. v24 h4
    & $c 31 30
    $s.Add(@{Op='label';Name="${LabelPrefix}_block"})
    $s.Add(@{Op='vload';d=0;s=0;Offset=0}); $s.Add(@{Op='vload';d=1;s=1;Offset=0})
    $s.Add(@{Op='vxor';d=2;s=2;t=2})                                        # S
    for ($h = 1; $h -le 9; $h++) {
        & $c 3 ($h - 1)
        $s.Add(@{Op='vmpyie-w-uh';d=4;s=0;t=3}); $s.Add(@{Op='vmpyie-w-uh';d=5;s=1;t=3})
        # Top 16 bits of each phase: even samples to the low halfword, odd samples to the high halfword.
        $s.Add(@{Op='vlsr-uw';d=4;s=4;t=12}); $s.Add(@{Op='vand';d=5;s=5;t=31}); $s.Add(@{Op='vor';d=4;s=4;t=5})
        $s.Add(@{Op='vadd-h';d=4;s=4;t=29})                                 # + quarter turn: -cos(2 pi (x + 1/4)) = sin(2 pi x)
        # u = 4|g| - 1 (Q15), sin(pi/2 u) = u (h0 + u2 (h1 + u2 (h2 + u2 (h3 + u2 h4)))) in Q14, doubled to Q15.
        $s.Add(@{Op='vabs-h-sat';d=4;s=4}); $s.Add(@{Op='vsub-h';d=4;s=4;t=30}); $s.Add(@{Op='vasl-h';d=4;s=4;t=13})
        & $mpy 5 4 4
        & $mpy 7 24 5; $s.Add(@{Op='vadd-h';d=7;s=7;t=25})
        foreach ($k in 26,27,28) { & $mpy 7 7 5; $s.Add(@{Op='vadd-h';d=7;s=7;t=$k}) }
        & $mpy 7 7 4; $s.Add(@{Op='vadd-h-sat';d=7;s=7;t=7})
        & $c 3 (8 + $h); & $mpy 7 7 3; $s.Add(@{Op='vadd-h-sat';d=2;s=2;t=7})
    }
    # Voicing and sign; noise; bias; tanh.
    $s.Add(@{Op='vload';d=3;s=2;Offset=0}); $s.Add(@{Op='vand';d=2;s=2;t=3})
    $s.Add(@{Op='vload';d=3;s=8;Offset=0}); $s.Add(@{Op='vxor';d=2;s=2;t=3}); $s.Add(@{Op='vsub-h';d=2;s=2;t=3})
    $s.Add(@{Op='vload';d=3;s=4;Offset=0}); $s.Add(@{Op='vload';d=4;s=9;Offset=0}); & $mpy 3 3 4; $s.Add(@{Op='vadd-h-sat';d=2;s=2;t=3})
    & $c 3 18; $s.Add(@{Op='vadd-h-sat';d=2;s=2;t=3})
    & $mpy 4 2 2                                                            # u = a^2
    & $c 5 28; & $mpy 5 5 4; & $c 6 27; $s.Add(@{Op='vadd-h';d=5;s=5;t=6})
    & $mpy 5 5 4; & $c 6 26; $s.Add(@{Op='vadd-h';d=5;s=5;t=6})
    & $mpy 5 5 4; & $mpy 5 5 2; $s.Add(@{Op='vadd-h-sat';d=2;s=2;t=5})
    $s.Add(@{Op='vstore';s=5;t=2;Offset=0})
    foreach ($r in 0,1,2,4,5,8,9) { $s.Add(@{Op='addi';d=$r;s=$r;i=128}) }
    $s.Add(@{Op='addi';d=7;s=7;i=-1}); $s.Add(@{Op='gtu';d=0;s=7;t=15}); $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_block"})
    if (-not $NoReturn) { $s.Add(@{Op='return'}) }
    $s.ToArray()
}

# Scalar: the reflect padding of the signal buffer (sample j at halfword 64 + j): halfword 64 - k <- 64 + k and
# 63 + N + k <- 63 + N - k, k = 1..10. r0 buffer, r1 N. Halfwords are read as two bytes (no halfword load encoded).
function New-KokoroSourceReflectSteps {
    param([string]$LabelPrefix='sourcereflect',[switch]$NoReturn)
    $s = [Collections.Generic.List[hashtable]]::new()
    $copy = { param([int]$fromReg,[int]$fromOff,[int]$toReg,[int]$toOff)
        $s.Add(@{Op='load-ub';d=10;s=$fromReg;Offset=$fromOff}); $s.Add(@{Op='load-ub';d=11;s=$fromReg;Offset=($fromOff+1)})
        $s.Add(@{Op='asl-i';d=11;s=11;i=8}); $s.Add(@{Op='or';d=10;s=10;t=11}); $s.Add(@{Op='store-h';s=$toReg;t=10;Offset=$toOff}) }
    for ($k = 1; $k -le 10; $k++) { & $copy 0 (2 * (64 + $k)) 0 (2 * (64 - $k)) }
    $s.Add(@{Op='add';d=2;s=1;t=1}); $s.Add(@{Op='add';d=2;s=2;t=0})        # r2 = buffer + 2 N
    for ($k = 1; $k -le 10; $k++) { & $copy 2 (2 * (63 - $k)) 2 (2 * (63 + $k)) }
    if (-not $NoReturn) { $s.Add(@{Op='return'}) }
    $s.ToArray()
}
