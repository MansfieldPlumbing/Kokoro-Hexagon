#requires -Version 7.4
# Per-channel constants of the phase-turns AdaIN+Snake body (Kokoro.AdaInSnakeTurns.ps1) from 16-bit
# group moments (Kokoro.AdaInMoments16.ps1). Design: docs/generator60x-16bit-design.md ("Coefficients").
# Stock AdaIN1d (Kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec istftnet.py:20-31) normalizes with the
# biased group variance; its style affine and Snake alpha are folded per channel at voice load into
#   Ka = A * alpha * 2^39 / pi      (A = style gain per input LSB, signed 64-bit)
#   Mb = alpha * B * 2^24 / pi      (B = style offset, Q24 turns)
#   S  = (pi / alpha) * 2^7 / sX    (output scale, copied)
#   epsD = round(eps * N^2 / sR^2)  (u64)
# Per group, with sum x^2 = 65536 A2 + 512 AB + B2:
#   D = N * sum x^2 - S1^2 + epsD,  root = floor(sqrt(D)),
#   K = sign(Ka) * round(|Ka| * N / root),  M = Mb - round(K * S1 / (N * 2^15)).
# Square root and division use exact trial bits on 64-bit products, as Kokoro.AdaInInteger.ps1 does.
# Caller guarantees epsD > 0 and |Ka| * N / root < 2^31 (the design keeps |K| below about 1.7e8, ten
# turns of phase); out-of-range quotients saturate at 2^31 - 1.
# r0 = moments record (per 32-channel block, 512 B: S1[32], A2[32], AB[32], B2[32]),
# r1 = parameters, 32 B per channel: Ka (int64) at 0, Mb at 8, S at 12, epsD (u64) at 16,
# r2 = output K[C] at 0, M[C] at 4C, S[C] at 8C, r3 = N (1..32768). Callee-saved registers are restored.
function New-KokoroAdaInTurnsCoefficientsSteps {
    param([ValidateSet(128,256)][int]$Channels=128,[string]$LabelPrefix='turnscoeff')
    $s = [Collections.Generic.List[hashtable]]::new()
    $s.Add(@{Op='allocframe';Bytes=64})
    foreach ($r in 16,18,20,22,24,26) { $s.Add(@{Op='store-d';s=29;t=$r;Offset=(($r-16)*4)}) }
    $s.Add(@{Op='imm';d=16;i=0})
    $s.Add(@{Op='imm';d=26;i=1})
    $s.Add(@{Op='imm';d=25;i=512})
    $s.Add(@{Op='imm';d=24;i=1}); $s.Add(@{Op='asl-i';d=24;s=24;i=16})          # 65536
    $s.Add(@{Op='asl-i';d=27;s=3;i=15})                                          # N * 2^15
    $s.Add(@{Op='imm';d=5;i=-1})                                                 # for x >= 0 tests: x > -1
    $next = { $script:__tc++; "${LabelPrefix}_$($script:__tc)" }
    $script:__tc = 0
    # Unsigned 64-bit r7:6 / 32-bit divisor register -> 31-bit quotient in $q (exact trial bits).
    $divide = { param([int]$divisor,[int]$q)
        $s.Add(@{Op='imm';d=$q;i=0})
        $s.Add(@{Op='imm';d=15;i=1}); $s.Add(@{Op='asl-i';d=15;s=15;i=30})
        $bit = & $next; $skip = & $next
        $s.Add(@{Op='label';Name=$bit})
        $s.Add(@{Op='or';d=14;s=$q;t=15})
        $s.Add(@{Op='mpyu-d';d=10;s=14;t=$divisor})
        $s.Add(@{Op='gtu-d';d=0;s=10;t=6})
        $s.Add(@{Op='jump-p';u=0;Label=$skip})
        $s.Add(@{Op='addi';d=$q;s=14;i=0})
        $s.Add(@{Op='label';Name=$skip})
        $s.Add(@{Op='lsr-i';d=15;s=15;i=1})
        $s.Add(@{Op='gtu';d=0;s=15;t=16})
        $s.Add(@{Op='jump-p';u=0;Label=$bit})
    }
    for ($block = 0; $block -lt ($Channels / 32); $block++) {
        $s.Add(@{Op='imm';d=17;i=32})
        $channel = "${LabelPrefix}_b${block}"
        $s.Add(@{Op='label';Name=$channel})
        $s.Add(@{Op='load';d=20;s=0;Offset=0})                               # S1
        $s.Add(@{Op='load';d=21;s=0;Offset=128})                             # A2
        $s.Add(@{Op='load';d=22;s=0;Offset=256})                             # AB
        $s.Add(@{Op='load';d=23;s=0;Offset=384})                             # B2
        # sum x^2 (r7:6) = 65536 A2 + 512 AB + B2
        $s.Add(@{Op='mpy-d';d=6;s=21;t=24})
        $s.Add(@{Op='mpy-d';d=8;s=22;t=25}); $s.Add(@{Op='add-d';d=6;s=6;t=8})
        $s.Add(@{Op='mpy-d';d=8;s=23;t=26}); $s.Add(@{Op='add-d';d=6;s=6;t=8})
        # N * sum x^2 (r9:8): low word times N, plus the small high word times N into the high word.
        $s.Add(@{Op='mpyu-d';d=8;s=6;t=3})
        $s.Add(@{Op='mpyu-d';d=10;s=7;t=3})
        $s.Add(@{Op='add';d=9;s=9;t=10})
        # D = N sum x^2 - S1^2 + epsD (r9:8)
        $s.Add(@{Op='mpy-d';d=12;s=20;t=20}); $s.Add(@{Op='sub-d';d=8;s=8;t=12})
        $s.Add(@{Op='load-d';d=12;s=1;Offset=16}); $s.Add(@{Op='add-d';d=8;s=8;t=12})
        # root (r18) = floor(sqrt(D)), D < 2^62
        $s.Add(@{Op='imm';d=18;i=0})
        $s.Add(@{Op='imm';d=19;i=1}); $s.Add(@{Op='asl-i';d=19;s=19;i=30})
        $sq = & $next; $sqSkip = & $next
        $s.Add(@{Op='label';Name=$sq})
        $s.Add(@{Op='or';d=14;s=18;t=19})
        $s.Add(@{Op='mpyu-d';d=10;s=14;t=14})
        $s.Add(@{Op='gtu-d';d=0;s=10;t=8})
        $s.Add(@{Op='jump-p';u=0;Label=$sqSkip})
        $s.Add(@{Op='addi';d=18;s=14;i=0})
        $s.Add(@{Op='label';Name=$sqSkip})
        $s.Add(@{Op='lsr-i';d=19;s=19;i=1})
        $s.Add(@{Op='gtu';d=0;s=19;t=16})
        $s.Add(@{Op='jump-p';u=0;Label=$sq})
        # |Ka| (r13:12), sign of Ka in r19 (1 when negative).
        $s.Add(@{Op='load-d';d=12;s=1;Offset=0})
        $s.Add(@{Op='imm';d=19;i=0})
        $pos = & $next
        $s.Add(@{Op='gt';d=0;s=13;t=5})
        $s.Add(@{Op='jump-p';u=0;Label=$pos})
        $s.Add(@{Op='imm';d=10;i=0}); $s.Add(@{Op='imm';d=11;i=0}); $s.Add(@{Op='sub-d';d=12;s=10;t=12})
        $s.Add(@{Op='imm';d=19;i=1})
        $s.Add(@{Op='label';Name=$pos})
        # |Ka| * N + root/2 (r7:6), then / root -> |K| in r21
        $s.Add(@{Op='mpyu-d';d=6;s=12;t=3})
        $s.Add(@{Op='mpyu-d';d=10;s=13;t=3})
        $s.Add(@{Op='add';d=7;s=7;t=10})
        $s.Add(@{Op='lsr-i';d=10;s=18;i=1}); $s.Add(@{Op='imm';d=11;i=0}); $s.Add(@{Op='add-d';d=6;s=6;t=10})
        & $divide 18 21
        $kpos = & $next
        $s.Add(@{Op='gtu';d=0;s=26;t=19})
        $s.Add(@{Op='jump-p';u=0;Label=$kpos})
        $s.Add(@{Op='sub';d=21;s=16;t=21})
        $s.Add(@{Op='label';Name=$kpos})
        # M = Mb - round(K * S1 / (N * 2^15)): |K * S1| (r7:6), sign in r19.
        $s.Add(@{Op='mpy-d';d=6;s=21;t=20})
        $s.Add(@{Op='imm';d=19;i=0})
        $mpos = & $next
        $s.Add(@{Op='gt';d=0;s=7;t=5})
        $s.Add(@{Op='jump-p';u=0;Label=$mpos})
        $s.Add(@{Op='imm';d=10;i=0}); $s.Add(@{Op='imm';d=11;i=0}); $s.Add(@{Op='sub-d';d=6;s=10;t=6})
        $s.Add(@{Op='imm';d=19;i=1})
        $s.Add(@{Op='label';Name=$mpos})
        $s.Add(@{Op='lsr-i';d=10;s=27;i=1}); $s.Add(@{Op='imm';d=11;i=0}); $s.Add(@{Op='add-d';d=6;s=6;t=10})
        & $divide 27 22
        $qpos = & $next
        $s.Add(@{Op='gtu';d=0;s=26;t=19})
        $s.Add(@{Op='jump-p';u=0;Label=$qpos})
        $s.Add(@{Op='sub';d=22;s=16;t=22})
        $s.Add(@{Op='label';Name=$qpos})
        $s.Add(@{Op='load';d=23;s=1;Offset=8})
        $s.Add(@{Op='sub';d=23;s=23;t=22})                                   # M
        $s.Add(@{Op='load';d=14;s=1;Offset=12})                              # S
        $s.Add(@{Op='store';s=2;t=21;Offset=0})
        $s.Add(@{Op='store';s=2;t=23;Offset=($Channels*4)})
        $s.Add(@{Op='store';s=2;t=14;Offset=($Channels*8)})
        $s.Add(@{Op='addi';d=0;s=0;i=4}); $s.Add(@{Op='addi';d=1;s=1;i=32}); $s.Add(@{Op='addi';d=2;s=2;i=4})
        $s.Add(@{Op='addi';d=17;s=17;i=-1})
        $s.Add(@{Op='gtu';d=0;s=17;t=16})
        $s.Add(@{Op='jump-p';u=0;Label=$channel})
        $s.Add(@{Op='addi';d=0;s=0;i=384})
    }
    foreach ($r in 16,18,20,22,24,26) { $s.Add(@{Op='load-d';d=$r;s=29;Offset=(($r-16)*4)}) }
    $s.Add(@{Op='dealloc-return'})
    $s.ToArray()
}
