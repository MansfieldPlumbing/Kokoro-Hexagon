#requires -Version 7.4
# Stock nn.LayerNorm over channels, per token, on 16-bit activations (biased u16 native croutons), with the per-channel
# weight and bias folded into the output LSB. ALBERT (transformers modeling_albert.py AlbertLayer: attention.LayerNorm,
# full_layer_layer_norm; AlbertEmbeddings.LayerNorm). Structure after MNN 43bc0686
# source/backend/hexagon/htp-ops-lib/src/dsp/layer_norm_ops.cc (per-row reduction tree, one reciprocal square root per
# row, then a per-channel scale); arithmetic integer, as Kokoro.AdaInMoments16.ps1 and Kokoro.AdaInTurnsCoefficients.ps1.
#
# Per token t over the C channels, with x = 256 a + b (a = x >> 8 signed, b = x & 255):
#   S1 = sum x, A2 = sum a^2, AB = sum a b, B2 = sum b^2 (int32 lanes, summed over the 32 lanes by a rotate-add tree),
#   D = C (65536 A2 + 512 AB + B2) - S1^2 + epsD   (= C^2 (var + eps) in input LSB^2, int64), root = floor(sqrt(D)),
#   e = bit length of root, m = round(2^(29 + e) / root) (2^29 < m <= 2^30), sh = 27 - e,
#   n = q31((C x - S1), m) << sh        (= (x - mean) / sqrt(var + eps) * 2^25, |n| < 2^31 for C <= 2048),
#   y = clamp(q31(n, g_c) + B_c, +-32767) stored biased, g_c = round(gamma_c / sOut_c * 2^6), B_c = round(beta_c / sOut_c).
# q31(u, v) = (u v + 2^30) >> 31 (vmpye + vmpyo:<<1:rnd:sat:shift, as Kokoro.AdaInLeaky16.ps1). A row with D = 0 gives
# n = 0 (y = B_c). Rows past the token count hold x = 0 and come out as B_c.
#
# r0 = input tile 0, r1 = output tile 0 (may equal r0), both tile stride 64 * C bytes; r2 = constants: per 32-channel
# block 256 B (g[32] at 0, B[32] at 128, int32), then epsD (int64) at 256 * C / 32; r3 = 1024 B scratch (128-aligned);
# r4 = tiles >= 1. Uses r5..r15, r28, v0..v31; r16..r27 are saved and restored.
function New-KokoroLayerNorm16Steps {
    param([ValidateRange(32,2048)][int]$Channels=768,[string]$LabelPrefix='layernorm16')
    if ($Channels % 32) { throw 'Channels must be whole 32-channel blocks' }
    $C = $Channels; $blocks = $C / 32; $epsOffset = 256 * $blocks
    $s = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL); $s.Add(@{Op='lo';x=$r;i=($u -band 65535)}); $s.Add(@{Op='hi';x=$r;i=($u -shr 16)}) }
    $script:__ln = 0
    $next = { $script:__ln++; "${LabelPrefix}_$($script:__ln)" }
    $loop = { param([int]$counter,[string]$label) $s.Add(@{Op='addi';d=$counter;s=$counter;i=-1}); $s.Add(@{Op='gtu';d=0;s=$counter;t=16}); $s.Add(@{Op='jump-p';u=0;Label=$label}) }

    $s.Add(@{Op='allocframe';Bytes=64})
    foreach ($r in 16,18,20,22,24,26) { $s.Add(@{Op='store-d';s=29;t=$r;Offset=(($r-16)*4)}) }
    $s.Add(@{Op='imm';d=16;i=0})
    $s.Add(@{Op='imm';d=24;i=1}); $s.Add(@{Op='asl-i';d=24;s=24;i=16})         # 65536
    $s.Add(@{Op='imm';d=25;i=512})
    $s.Add(@{Op='imm';d=26;i=1})
    & $imm 27 $C
    & $imm 13 0x80008000L; $s.Add(@{Op='vsplat';d=31;s=13})
    & $imm 13 0x00FF00FFL; $s.Add(@{Op='vsplat';d=30;s=13})
    & $imm 13 0x0000FFFFL; $s.Add(@{Op='vsplat';d=29;s=13})
    & $imm 13 32767; $s.Add(@{Op='vsplat';d=27;s=13})
    & $imm 13 -32768; $s.Add(@{Op='vsplat';d=26;s=13})

    # Per-token scalar stage: stats in r20 (S1), r21 (A2), r22 (AB), r23 (B2) -> r20 S1, r21 m, r22 sh.
    $token = {
        # sum x^2 (r7:6) = 65536 A2 + 512 AB + B2
        $s.Add(@{Op='mpy-d';d=6;s=21;t=24})
        $s.Add(@{Op='mpy-d';d=8;s=22;t=25}); $s.Add(@{Op='add-d';d=6;s=6;t=8})
        $s.Add(@{Op='mpy-d';d=8;s=23;t=26}); $s.Add(@{Op='add-d';d=6;s=6;t=8})
        # D (r9:8) = C sum x^2 - S1^2 + epsD
        $s.Add(@{Op='mpyu-d';d=8;s=6;t=27}); $s.Add(@{Op='mpyu-d';d=10;s=7;t=27}); $s.Add(@{Op='add';d=9;s=9;t=10})
        $s.Add(@{Op='mpy-d';d=10;s=20;t=20}); $s.Add(@{Op='sub-d';d=8;s=8;t=10})
        $s.Add(@{Op='load-d';d=10;s=2;Offset=$epsOffset}); $s.Add(@{Op='add-d';d=8;s=8;t=10})
        # root (r18) = floor(sqrt(D)) by exact trial bits (D < 2^62)
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
        # root = 0 (a constant row): m = 0, sh = 0.
        $s.Add(@{Op='imm';d=21;i=0}); $s.Add(@{Op='imm';d=22;i=0})
        $done = & $next
        $s.Add(@{Op='eq';d=0;s=18;t=16}); $s.Add(@{Op='jump-p';u=0;Label=$done})
        # e (r13) = bit length of root
        $s.Add(@{Op='addi';d=12;s=18;i=0}); $s.Add(@{Op='imm';d=13;i=0})
        $bl = & $next
        $s.Add(@{Op='label';Name=$bl})
        $s.Add(@{Op='lsr-i';d=12;s=12;i=1}); $s.Add(@{Op='addi';d=13;s=13;i=1})
        $s.Add(@{Op='gtu';d=0;s=12;t=16}); $s.Add(@{Op='jump-p';u=0;Label=$bl})
        # numerator (r7:6) = 2^(29 + e) + floor(root / 2)
        & $imm 6 0x20000000L; $s.Add(@{Op='imm';d=7;i=0})
        $s.Add(@{Op='addi';d=12;s=13;i=0})
        $dbl = & $next
        $s.Add(@{Op='label';Name=$dbl})
        $s.Add(@{Op='add-d';d=6;s=6;t=6})
        & $loop 12 $dbl
        $s.Add(@{Op='lsr-i';d=10;s=18;i=1}); $s.Add(@{Op='imm';d=11;i=0}); $s.Add(@{Op='add-d';d=6;s=6;t=10})
        # m (r21) = numerator / root (exact trial bits, 31-bit quotient)
        $s.Add(@{Op='imm';d=21;i=0})
        $s.Add(@{Op='imm';d=15;i=1}); $s.Add(@{Op='asl-i';d=15;s=15;i=30})
        $bit = & $next; $skip = & $next
        $s.Add(@{Op='label';Name=$bit})
        $s.Add(@{Op='or';d=14;s=21;t=15})
        $s.Add(@{Op='mpyu-d';d=10;s=14;t=18})
        $s.Add(@{Op='gtu-d';d=0;s=10;t=6})
        $s.Add(@{Op='jump-p';u=0;Label=$skip})
        $s.Add(@{Op='addi';d=21;s=14;i=0})
        $s.Add(@{Op='label';Name=$skip})
        $s.Add(@{Op='lsr-i';d=15;s=15;i=1})
        $s.Add(@{Op='gtu';d=0;s=15;t=16})
        $s.Add(@{Op='jump-p';u=0;Label=$bit})
        # sh (r22) = 27 - e
        $s.Add(@{Op='imm';d=22;i=27}); $s.Add(@{Op='sub';d=22;s=22;t=13})
        $s.Add(@{Op='label';Name=$done})
    }

    $s.Add(@{Op='label';Name="${LabelPrefix}_tile"})
    $s.Add(@{Op='addi';d=28;s=0;i=0})                 # input row pair base
    $s.Add(@{Op='addi';d=17;s=1;i=0})                 # output row pair base
    $s.Add(@{Op='imm';d=13;i=16}); $s.Add(@{Op='store';s=29;t=13;Offset=48})   # row pairs left in this tile
    $s.Add(@{Op='label';Name="${LabelPrefix}_pair"})

    # Stage 1: moments of rows 2r (even halfwords, v0 v2 v4 v6) and 2r+1 (odd, v1 v3 v5 v7) over all channel blocks.
    foreach ($v in 0..7) { $s.Add(@{Op='vxor';d=$v;s=$v;t=$v}) }
    & $imm 6 0x00010001L; $s.Add(@{Op='imm';d=8;i=8})
    $s.Add(@{Op='addi';d=5;s=28;i=0}); $s.Add(@{Op='imm';d=12;i=$blocks})
    $s.Add(@{Op='label';Name="${LabelPrefix}_mblock"})
    $s.Add(@{Op='vload';d=8;s=5;Offset=0})
    $s.Add(@{Op='vxor';d=8;s=8;t=31})
    $s.Add(@{Op='vmpy-acc-ww-h-r';d=0;s=8;t=6})
    $s.Add(@{Op='vasr-h';d=9;s=8;t=8})
    $s.Add(@{Op='vand';d=10;s=8;t=30})
    $s.Add(@{Op='vmpy-acc-ww-h-h';d=2;s=9;t=9})
    $s.Add(@{Op='vmpy-acc-ww-h-h';d=4;s=9;t=10})
    $s.Add(@{Op='vmpy-acc-ww-h-h';d=6;s=10;t=10})
    $s.Add(@{Op='addi';d=5;s=5;i=2048})
    & $loop 12 "${LabelPrefix}_mblock"
    # Sum the 32 word lanes of each statistic (rotate-add tree), lane 0 to scratch.
    foreach ($v in 0..7) {
        foreach ($amount in 64, 32, 16, 8, 4) {
            $s.Add(@{Op='imm';d=7;i=$amount})
            $s.Add(@{Op='valign';d=11;s=$v;t=$v;r=7})
            $s.Add(@{Op='vadd-w';d=$v;s=$v;t=11})
        }
        $s.Add(@{Op='vstore';s=3;t=$v;Offset=(128*$v)})
    }
    # Stage 2: per-token constants, splatted: v14/v15 S1, v16/v17 m, v18/v19 sh (even row, odd row).
    foreach ($row in 0, 1) {
        $s.Add(@{Op='load';d=20;s=3;Offset=(128*(0+$row))})
        $s.Add(@{Op='load';d=21;s=3;Offset=(128*(2+$row))})
        $s.Add(@{Op='load';d=22;s=3;Offset=(128*(4+$row))})
        $s.Add(@{Op='load';d=23;s=3;Offset=(128*(6+$row))})
        & $token
        $s.Add(@{Op='vsplat';d=(14+$row);s=20})
        $s.Add(@{Op='vsplat';d=(16+$row);s=21})
        $s.Add(@{Op='vsplat';d=(18+$row);s=22})
    }
    # Stage 3: normalize, per-channel affine, clamp, repack biased.
    & $imm 10 (($C -shl 16) -bor $C); $s.Add(@{Op='imm';d=9;i=16})
    $s.Add(@{Op='addi';d=5;s=28;i=0}); $s.Add(@{Op='addi';d=6;s=17;i=0}); $s.Add(@{Op='addi';d=11;s=2;i=0})
    $s.Add(@{Op='imm';d=12;i=$blocks})
    $s.Add(@{Op='label';Name="${LabelPrefix}_ablock"})
    $s.Add(@{Op='vload';d=8;s=5;Offset=0})
    $s.Add(@{Op='vxor';d=8;s=8;t=31})
    $s.Add(@{Op='vxor';d=12;s=12;t=12}); $s.Add(@{Op='vxor';d=13;s=13;t=13})
    $s.Add(@{Op='vmpy-acc-ww-h-r';d=12;s=8;t=10})                            # C x (even rows v12, odd rows v13)
    $s.Add(@{Op='vsub-w';d=12;s=12;t=14}); $s.Add(@{Op='vsub-w';d=13;s=13;t=15})
    $s.Add(@{Op='vmpye-w-uh';d=20;s=12;t=16}); $s.Add(@{Op='vmpyo-acc-w-h-rnd-sat-shift';d=20;s=12;t=16})
    $s.Add(@{Op='vmpye-w-uh';d=21;s=13;t=17}); $s.Add(@{Op='vmpyo-acc-w-h-rnd-sat-shift';d=21;s=13;t=17})
    $s.Add(@{Op='vasl-wv';d=20;s=20;t=18}); $s.Add(@{Op='vasl-wv';d=21;s=21;t=19})
    $s.Add(@{Op='vload';d=22;s=11;Offset=0}); $s.Add(@{Op='vload';d=23;s=11;Offset=128})
    foreach ($p in @(@(24,20),@(25,21))) {
        $s.Add(@{Op='vmpye-w-uh';d=$p[0];s=$p[1];t=22}); $s.Add(@{Op='vmpyo-acc-w-h-rnd-sat-shift';d=$p[0];s=$p[1];t=22})
        $s.Add(@{Op='vadd-w';d=$p[0];s=$p[0];t=23})
        $s.Add(@{Op='vmax-w';d=$p[0];s=$p[0];t=26}); $s.Add(@{Op='vmin-w';d=$p[0];s=$p[0];t=27})
    }
    $s.Add(@{Op='vand';d=24;s=24;t=29}); $s.Add(@{Op='vasl-w';d=25;s=25;t=9}); $s.Add(@{Op='vor';d=24;s=24;t=25}); $s.Add(@{Op='vxor';d=24;s=24;t=31})
    $s.Add(@{Op='vstore';s=6;t=24;Offset=0})
    $s.Add(@{Op='addi';d=5;s=5;i=2048}); $s.Add(@{Op='addi';d=6;s=6;i=2048}); $s.Add(@{Op='addi';d=11;s=11;i=256})
    & $loop 12 "${LabelPrefix}_ablock"
    # Next row pair, then next tile.
    $s.Add(@{Op='addi';d=28;s=28;i=128}); $s.Add(@{Op='addi';d=17;s=17;i=128})
    $s.Add(@{Op='load';d=13;s=29;Offset=48})
    $s.Add(@{Op='addi';d=13;s=13;i=-1}); $s.Add(@{Op='store';s=29;t=13;Offset=48})
    $s.Add(@{Op='gtu';d=0;s=13;t=16}); $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_pair"})
    & $imm 13 (64L * $C)
    $s.Add(@{Op='add';d=0;s=0;t=13}); $s.Add(@{Op='add';d=1;s=1;t=13})
    & $loop 4 "${LabelPrefix}_tile"
    foreach ($r in 16,18,20,22,24,26) { $s.Add(@{Op='load-d';d=$r;s=29;Offset=(($r-16)*4)}) }
    $s.Add(@{Op='dealloc-return'})
    $s.ToArray()
}
