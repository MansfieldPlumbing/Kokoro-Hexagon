#requires -Version 7.4
# Stock ALBERT self-attention core on 16-bit activations (biased u16 native croutons, 12 heads of 64): per head
# scores = q k^T / 8, softmax over the T keys (one unpadded sentence: no key is masked except the tile padding),
# context = p v. transformers modeling_albert.py AlbertSdpaAttention (scaled_dot_product_attention). Structure after
# MNN 43bc0686 htp-ops-lib/src/dsp/attention_common.hpp (row max, exp and sum, one reciprocal per row, scale);
# arithmetic integer on HVX (Invoke-KokoroDevelopment.ps1 Measure-KokoroAlbertAttention -Mode A12K16 models the precision).
#
# Units: q is rescaled beforehand (New-KokoroScaleConvert16Steps) so that q'_c k_c has one LSB U_h per head, |q'| <= 2047;
# k is 16-bit with any per-channel LSB; v keeps its per-channel LSB, which the context inherits.
#   A  kd[j][b] = k[j] (block b of the head) in both halfwords of every lane; vd[j][b] likewise from v.  (j < T)
#   B  S[i][j] = sum_c q'[i,c] k[j,c]: per query row pair and key, vmpy over the head's two blocks, then the 32 lanes
#      summed by a rotate-add tree (as Kokoro.LayerNorm16.ps1). int32.
#   C  per query row i < T, vectorized over keys (lanes j, Tpad / 32 chunks):
#      t = clamp(q31(S - max_j S, Ce_h), -31 * 2^16, 0)      Q16 of (S - max) U_h / 8 log2(e), Ce_h = U_h / 8 log2(e) 2^47
#      n = -(t >> 16), f = (t & 0xFFFF) >> 1 (Q15), m = 16384 + h(f) / 2 with h(f) = 2^f - 1 by Q15 Horner (e6 .. e1),
#      as Kokoro.TailSpectrum16.ps1;  e_j = (m >> n) & mask_j  (Q14, padded keys 0);  R = round(2^29 / sum_j e_j);
#      p_j = min((e_j R + 2^13) >> 14, 32767)   (Q15)
#   D  ctx[i,c] = clamp((sum_j p_ij v[j,c] + 2^14) >> 15, +-32767): the probability pair of rows 2r, 2r+1 splatted per
#      key against vd, no lane reduction (sum_j p <= 2^15 keeps it inside int32).
#
# r0 = q' (biased u16, 768 wide), r1 = k, r2 = v, r3 = context out (rows past T must already hold 0x8000; rows < T are
# written), r4 = constants (Get-KokoroAttention16Constants layout: Ce[12] int32 at 0; Horner e1..e6 halfword pairs at
# 128; per 32-key chunk the key mask and its INT_MIN fill at 256 + 256 c), r5 = scratch (Get-KokoroAttention16Scratch,
# 128-aligned). r16..r27 are saved and restored.
function Get-KokoroAttention16Scratch {
    param([Parameter(Mandatory)][ValidateRange(1,512)][int]$Tokens)
    $pad = 32 * [int][math]::Ceiling($Tokens / 32)
    $kd = 0L; $vd = 256L * $Tokens; $sc = $vd + 256L * $Tokens; $pr = $sc + 4L * $pad * $pad; $tmp = $pr + 4L * $pad * $pad
    [pscustomobject]@{ Tokens = $Tokens; Padded = $pad; Kd = $kd; Vd = $vd; Scores = $sc; Probabilities = $pr; Temp = $tmp; Bytes = ($tmp + 256L) }
}

function New-KokoroAttention16Steps {
    param([Parameter(Mandatory)][ValidateRange(1,512)][int]$Tokens,[string]$LabelPrefix='attention16')
    $heads = 12; $width = 768; $tileStride = 64L * $width
    $L = Get-KokoroAttention16Scratch -Tokens $Tokens; $pad = $L.Padded; $chunks = $pad / 32; $rowBytes = 4L * $pad
    $rowPairs = [int][math]::Ceiling($Tokens / 2)
    $s = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL); $s.Add(@{Op='lo';x=$r;i=($u -band 65535)}); $s.Add(@{Op='hi';x=$r;i=($u -shr 16)}) }
    $addc = { param([int]$d,[int]$src,[long]$v) if ($v -ge -32768 -and $v -le 32767) { $s.Add(@{Op='addi';d=$d;s=$src;i=[int]$v}) } else { & $imm 15 $v; $s.Add(@{Op='add';d=$d;s=$src;t=15}) } }
    $splat = { param([int]$v,[long]$value) & $imm 13 $value; $s.Add(@{Op='vsplat';d=$v;s=13}) }
    $script:__at = 0
    $next = { $script:__at++; "${LabelPrefix}_$($script:__at)" }
    $countdown = { param([int]$counter,[string]$label) $s.Add(@{Op='addi';d=$counter;s=$counter;i=-1}); $s.Add(@{Op='gtu';d=0;s=$counter;t=27}); $s.Add(@{Op='jump-p';u=0;Label=$label}) }
    # Lane reduction of v$v with v$tmp: op vadd-w or vmax-w; r7 holds the rotate amount.
    $reduce = { param([int]$v,[int]$tmp,[string]$op) foreach ($amount in 64, 32, 16, 8, 4) { $s.Add(@{Op='imm';d=7;i=$amount}); $s.Add(@{Op='valign';d=$tmp;s=$v;t=$v;r=7}); $s.Add(@{Op=$op;d=$v;s=$v;t=$tmp}) } }

    $s.Add(@{Op='allocframe';Bytes=64})
    foreach ($r in 16,18,20,22,24,26) { $s.Add(@{Op='store-d';s=29;t=$r;Offset=(($r-16)*4)}) }
    $s.Add(@{Op='addi';d=18;s=0;i=0}); $s.Add(@{Op='addi';d=19;s=1;i=0}); $s.Add(@{Op='addi';d=20;s=2;i=0})
    $s.Add(@{Op='addi';d=21;s=3;i=0}); $s.Add(@{Op='addi';d=22;s=4;i=0}); $s.Add(@{Op='addi';d=23;s=5;i=0})
    $s.Add(@{Op='imm';d=27;i=0})
    & $splat 31 0x80008000L; & $splat 30 0xFFFF0000L; & $splat 29 0x0000FFFFL; & $splat 28 0x40004000L
    & $splat 27 32767; & $splat 26 -32768; & $splat 25 (-31L * 65536); & $splat 23 8192; & $splat 16 16384; & $splat 14 ([int]::MinValue)
    $s.Add(@{Op='vxor';d=24;s=24;t=24})
    for ($k = 0; $k -lt 6; $k++) { $s.Add(@{Op='load';d=13;s=22;Offset=(128 + 4*$k)}); $s.Add(@{Op='vsplat';d=(17+$k);s=13}) }   # e1..e6 in v17..v22
    # Zero the scores and probabilities.
    & $addc 4 23 $L.Scores; & $imm 5 ((2L * $pad * $rowBytes) / 128); $zero = & $next
    $s.Add(@{Op='vxor';d=0;s=0;t=0})
    $s.Add(@{Op='label';Name=$zero}); $s.Add(@{Op='vstore';s=4;t=0;Offset=0}); $s.Add(@{Op='addi';d=4;s=4;i=128}); & $countdown 5 $zero

    $s.Add(@{Op='imm';d=17;i=0}); $s.Add(@{Op='imm';d=16;i=$heads}); $s.Add(@{Op='addi';d=26;s=22;i=0})
    $headLabel = "${LabelPrefix}_head"
    $s.Add(@{Op='label';Name=$headLabel})
    $s.Add(@{Op='load';d=13;s=26;Offset=0}); $s.Add(@{Op='vsplat';d=15;s=13})                         # Ce of this head

    # A: broadcast rows of k (into kd) and v (into vd).
    foreach ($pair in @(@(19, $L.Kd), @(20, $L.Vd))) {
        $s.Add(@{Op='add';d=8;s=$pair[0];t=17}); & $addc 9 23 $pair[1]; & $imm 10 $Tokens
        $tile = & $next; $rp = & $next; $done = & $next
        $s.Add(@{Op='label';Name=$tile}); $s.Add(@{Op='imm';d=11;i=16}); $s.Add(@{Op='addi';d=12;s=8;i=0})
        $s.Add(@{Op='label';Name=$rp})
        $s.Add(@{Op='vload';d=0;s=12;Offset=0}); $s.Add(@{Op='addi';d=13;s=12;i=2048}); $s.Add(@{Op='vload';d=1;s=13;Offset=0})
        $s.Add(@{Op='vxor';d=0;s=0;t=31}); $s.Add(@{Op='vxor';d=1;s=1;t=31})
        $s.Add(@{Op='imm';d=14;i=16})
        foreach ($b in 0, 1) { $s.Add(@{Op='vand';d=2;s=$b;t=29}); $s.Add(@{Op='vasl-w';d=3;s=2;t=14}); $s.Add(@{Op='vor';d=2;s=2;t=3}); $s.Add(@{Op='vstore';s=9;t=2;Offset=(128*$b)}) }
        $s.Add(@{Op='addi';d=10;s=10;i=-1}); $s.Add(@{Op='eq';d=0;s=10;t=27}); $s.Add(@{Op='jump-p';u=0;Label=$done})
        $s.Add(@{Op='addi';d=13;s=9;i=256})
        foreach ($b in 0, 1) { $s.Add(@{Op='vand';d=2;s=$b;t=30}); $s.Add(@{Op='vlsr-uw';d=3;s=2;t=14}); $s.Add(@{Op='vor';d=2;s=2;t=3}); $s.Add(@{Op='vstore';s=13;t=2;Offset=(128*$b)}) }
        $s.Add(@{Op='addi';d=10;s=10;i=-1}); $s.Add(@{Op='eq';d=0;s=10;t=27}); $s.Add(@{Op='jump-p';u=0;Label=$done})
        $s.Add(@{Op='addi';d=9;s=9;i=512}); $s.Add(@{Op='addi';d=12;s=12;i=128})
        & $countdown 11 $rp
        & $addc 8 8 $tileStride
        $s.Add(@{Op='gtu';d=0;s=10;t=27}); $s.Add(@{Op='jump-p';u=0;Label=$tile})
        $s.Add(@{Op='label';Name=$done})
    }

    # B: scores of query row pairs r < ceil(T / 2) against keys j < T.
    $s.Add(@{Op='add';d=8;s=18;t=17}); $s.Add(@{Op='imm';d=11;i=16}); & $imm 12 $rowPairs; & $addc 24 23 $L.Scores
    $rpB = & $next; $keyB = & $next; $doneB = & $next; $sameTile = & $next
    $s.Add(@{Op='label';Name=$rpB})
    $s.Add(@{Op='vload';d=4;s=8;Offset=0}); $s.Add(@{Op='addi';d=13;s=8;i=2048}); $s.Add(@{Op='vload';d=5;s=13;Offset=0})
    $s.Add(@{Op='vxor';d=4;s=4;t=31}); $s.Add(@{Op='vxor';d=5;s=5;t=31})
    & $addc 9 23 $L.Kd; & $imm 10 $Tokens; $s.Add(@{Op='addi';d=13;s=24;i=0}); & $addc 28 24 $rowBytes; & $addc 14 23 $L.Temp
    $s.Add(@{Op='label';Name=$keyB})
    $s.Add(@{Op='vxor';d=0;s=0;t=0}); $s.Add(@{Op='vxor';d=1;s=1;t=1})
    $s.Add(@{Op='vload';d=6;s=9;Offset=0}); $s.Add(@{Op='vload';d=7;s=9;Offset=128})
    $s.Add(@{Op='vmpy-acc-ww-h-h';d=0;s=4;t=6}); $s.Add(@{Op='vmpy-acc-ww-h-h';d=0;s=5;t=7})
    & $reduce 0 2 'vadd-w'; & $reduce 1 3 'vadd-w'
    $s.Add(@{Op='vstore';s=14;t=0;Offset=0}); $s.Add(@{Op='vstore';s=14;t=1;Offset=128})
    $s.Add(@{Op='load';d=6;s=14;Offset=0}); $s.Add(@{Op='load';d=15;s=14;Offset=128})
    $s.Add(@{Op='store';s=13;t=6;Offset=0}); $s.Add(@{Op='store';s=28;t=15;Offset=0})
    $s.Add(@{Op='addi';d=13;s=13;i=4}); $s.Add(@{Op='addi';d=28;s=28;i=4}); $s.Add(@{Op='addi';d=9;s=9;i=256})
    & $countdown 10 $keyB
    & $addc 24 24 (2 * $rowBytes)
    $s.Add(@{Op='addi';d=12;s=12;i=-1}); $s.Add(@{Op='eq';d=0;s=12;t=27}); $s.Add(@{Op='jump-p';u=0;Label=$doneB})
    $s.Add(@{Op='addi';d=8;s=8;i=128})
    & $countdown 11 $rpB
    & $addc 8 8 ($tileStride - 2048); $s.Add(@{Op='imm';d=11;i=16})
    $s.Add(@{Op='eq';d=0;s=27;t=27}); $s.Add(@{Op='jump-p';u=0;Label=$rpB})
    $s.Add(@{Op='label';Name=$doneB})

    # C: softmax of rows i < T, chunks of 32 keys.
    & $addc 24 23 $L.Scores; & $addc 25 23 $L.Probabilities; & $imm 12 $Tokens; & $addc 14 23 $L.Temp
    $rowC = & $next
    $s.Add(@{Op='label';Name=$rowC})
    # C1: row max over the real keys.
    $s.Add(@{Op='vor';d=0;s=14;t=14}); $s.Add(@{Op='addi';d=9;s=24;i=0}); & $addc 10 22 256; $s.Add(@{Op='imm';d=11;i=$chunks})
    $maxC = & $next
    $s.Add(@{Op='label';Name=$maxC})
    $s.Add(@{Op='vload';d=1;s=9;Offset=0}); $s.Add(@{Op='vload';d=2;s=10;Offset=0}); $s.Add(@{Op='vload';d=3;s=10;Offset=128})
    $s.Add(@{Op='vand';d=1;s=1;t=2}); $s.Add(@{Op='vor';d=1;s=1;t=3}); $s.Add(@{Op='vmax-w';d=0;s=0;t=1})
    $s.Add(@{Op='addi';d=9;s=9;i=128}); $s.Add(@{Op='addi';d=10;s=10;i=256}); & $countdown 11 $maxC
    & $reduce 0 2 'vmax-w'
    $s.Add(@{Op='vstore';s=14;t=0;Offset=0}); $s.Add(@{Op='load';d=6;s=14;Offset=0}); $s.Add(@{Op='vsplat';d=13;s=6})
    # C2: e = (2^frac >> n) & mask, sum.
    $s.Add(@{Op='vxor';d=12;s=12;t=12}); $s.Add(@{Op='addi';d=9;s=24;i=0}); & $addc 10 22 256; $s.Add(@{Op='imm';d=11;i=$chunks})
    $s.Add(@{Op='imm';d=6;i=16}); $s.Add(@{Op='imm';d=7;i=1})
    $expC = & $next
    $s.Add(@{Op='label';Name=$expC})
    $s.Add(@{Op='vload';d=1;s=9;Offset=0}); $s.Add(@{Op='vsub-w';d=1;s=1;t=13})
    $s.Add(@{Op='vmpye-w-uh';d=2;s=1;t=15}); $s.Add(@{Op='vmpyo-acc-w-h-rnd-sat-shift';d=2;s=1;t=15})
    $s.Add(@{Op='vmax-w';d=2;s=2;t=25}); $s.Add(@{Op='vmin-w';d=2;s=2;t=24})
    $s.Add(@{Op='vasr-w';d=3;s=2;t=6}); $s.Add(@{Op='vsub-w';d=3;s=24;t=3})                          # n
    $s.Add(@{Op='vand';d=4;s=2;t=29}); $s.Add(@{Op='vlsr-uw';d=4;s=4;t=7})                           # f (Q15)
    $s.Add(@{Op='vmpy-h-rnd-sat';d=5;s=22;t=4})
    foreach ($k in 4, 3, 2, 1, 0) { $s.Add(@{Op='vadd-h-sat';d=5;s=5;t=(17+$k)}); $s.Add(@{Op='vmpy-h-rnd-sat';d=5;s=5;t=4}) }
    $s.Add(@{Op='vasr-h';d=5;s=5;t=7}); $s.Add(@{Op='vadd-h';d=5;s=5;t=28}); $s.Add(@{Op='vand';d=5;s=5;t=29})   # m (Q14)
    $s.Add(@{Op='vasr-wv';d=5;s=5;t=3})
    $s.Add(@{Op='vload';d=2;s=10;Offset=0}); $s.Add(@{Op='vand';d=5;s=5;t=2})
    $s.Add(@{Op='vstore';s=9;t=5;Offset=0}); $s.Add(@{Op='vadd-w';d=12;s=12;t=5})
    $s.Add(@{Op='addi';d=9;s=9;i=128}); $s.Add(@{Op='addi';d=10;s=10;i=256}); & $countdown 11 $expC
    & $reduce 12 2 'vadd-w'
    $s.Add(@{Op='vstore';s=14;t=12;Offset=0}); $s.Add(@{Op='load';d=9;s=14;Offset=0})
    # C3: R = round(2^29 / sum) by exact trial bits (R <= 2^15 since sum >= 2^14).
    & $imm 6 0x20000000L; $s.Add(@{Op='lsr-i';d=13;s=9;i=1}); $s.Add(@{Op='add';d=6;s=6;t=13}); $s.Add(@{Op='imm';d=7;i=0})
    $s.Add(@{Op='imm';d=11;i=0}); $s.Add(@{Op='imm';d=15;i=1}); $s.Add(@{Op='asl-i';d=15;s=15;i=16})
    $bit = & $next; $skip = & $next
    $s.Add(@{Op='label';Name=$bit})
    $s.Add(@{Op='or';d=10;s=11;t=15}); $s.Add(@{Op='mpyu-d';d=4;s=10;t=9})
    $s.Add(@{Op='gtu-d';d=0;s=4;t=6}); $s.Add(@{Op='jump-p';u=0;Label=$skip}); $s.Add(@{Op='addi';d=11;s=10;i=0})
    $s.Add(@{Op='label';Name=$skip})
    $s.Add(@{Op='lsr-i';d=15;s=15;i=1}); $s.Add(@{Op='gtu';d=0;s=15;t=27}); $s.Add(@{Op='jump-p';u=0;Label=$bit})
    $s.Add(@{Op='vsplat';d=11;s=11})
    # C4: p = min((e R + 2^13) >> 14, 32767).
    $s.Add(@{Op='addi';d=9;s=24;i=0}); $s.Add(@{Op='addi';d=10;s=25;i=0}); $s.Add(@{Op='imm';d=11;i=$chunks}); $s.Add(@{Op='imm';d=6;i=14})
    $probC = & $next
    $s.Add(@{Op='label';Name=$probC})
    $s.Add(@{Op='vload';d=1;s=9;Offset=0}); $s.Add(@{Op='vmpyie-w-uh';d=2;s=1;t=11}); $s.Add(@{Op='vadd-w';d=2;s=2;t=23})
    $s.Add(@{Op='vasr-w';d=2;s=2;t=6}); $s.Add(@{Op='vmin-w';d=2;s=2;t=27}); $s.Add(@{Op='vstore';s=10;t=2;Offset=0})
    $s.Add(@{Op='addi';d=9;s=9;i=128}); $s.Add(@{Op='addi';d=10;s=10;i=128}); & $countdown 11 $probC
    & $addc 24 24 $rowBytes; & $addc 25 25 $rowBytes
    & $countdown 12 $rowC

    # D: context of query row pairs r < ceil(T / 2).
    $s.Add(@{Op='add';d=8;s=21;t=17}); $s.Add(@{Op='imm';d=11;i=16}); & $imm 12 $rowPairs; & $addc 24 23 $L.Probabilities
    & $imm 6 0xFFFF; $s.Add(@{Op='addi';d=25;s=6;i=0})
    $rpD = & $next; $keyD = & $next; $doneD = & $next
    $s.Add(@{Op='label';Name=$rpD})
    foreach ($v in 0..3) { $s.Add(@{Op='vxor';d=$v;s=$v;t=$v}) }
    & $addc 9 23 $L.Vd; & $imm 10 $Tokens; $s.Add(@{Op='addi';d=13;s=24;i=0}); & $addc 28 24 $rowBytes
    $s.Add(@{Op='label';Name=$keyD})
    $s.Add(@{Op='load';d=6;s=13;Offset=0}); $s.Add(@{Op='load';d=15;s=28;Offset=0})
    $s.Add(@{Op='and';d=6;s=6;t=25}); $s.Add(@{Op='asl-i';d=15;s=15;i=16}); $s.Add(@{Op='or';d=6;s=6;t=15}); $s.Add(@{Op='vsplat';d=8;s=6})
    $s.Add(@{Op='vload';d=9;s=9;Offset=0}); $s.Add(@{Op='vload';d=10;s=9;Offset=128})
    $s.Add(@{Op='vmpy-acc-ww-h-h';d=0;s=9;t=8}); $s.Add(@{Op='vmpy-acc-ww-h-h';d=2;s=10;t=8})
    $s.Add(@{Op='addi';d=13;s=13;i=4}); $s.Add(@{Op='addi';d=28;s=28;i=4}); $s.Add(@{Op='addi';d=9;s=9;i=256})
    & $countdown 10 $keyD
    $s.Add(@{Op='imm';d=6;i=15}); $s.Add(@{Op='imm';d=7;i=16})
    foreach ($b in 0, 1) {
        foreach ($v in (2*$b), (2*$b+1)) { $s.Add(@{Op='vadd-w';d=$v;s=$v;t=16}); $s.Add(@{Op='vasr-w';d=$v;s=$v;t=6}); $s.Add(@{Op='vmax-w';d=$v;s=$v;t=26}); $s.Add(@{Op='vmin-w';d=$v;s=$v;t=27}) }
        $s.Add(@{Op='vand';d=(4+$b);s=(2*$b);t=29}); $s.Add(@{Op='vasl-w';d=6;s=(2*$b+1);t=7}); $s.Add(@{Op='vor';d=(4+$b);s=(4+$b);t=6}); $s.Add(@{Op='vxor';d=(4+$b);s=(4+$b);t=31})
    }
    $s.Add(@{Op='vstore';s=8;t=4;Offset=0}); $s.Add(@{Op='addi';d=13;s=8;i=2048}); $s.Add(@{Op='vstore';s=13;t=5;Offset=0})
    & $addc 24 24 (2 * $rowBytes)
    $s.Add(@{Op='addi';d=12;s=12;i=-1}); $s.Add(@{Op='eq';d=0;s=12;t=27}); $s.Add(@{Op='jump-p';u=0;Label=$doneD})
    $s.Add(@{Op='addi';d=8;s=8;i=128})
    & $countdown 11 $rpD
    & $addc 8 8 ($tileStride - 2048); $s.Add(@{Op='imm';d=11;i=16})
    $s.Add(@{Op='eq';d=0;s=27;t=27}); $s.Add(@{Op='jump-p';u=0;Label=$rpD})
    $s.Add(@{Op='label';Name=$doneD})

    $s.Add(@{Op='addi';d=17;s=17;i=4096}); $s.Add(@{Op='addi';d=26;s=26;i=4})
    & $countdown 16 $headLabel
    foreach ($r in 16,18,20,22,24,26) { $s.Add(@{Op='load-d';d=$r;s=29;Offset=(($r-16)*4)}) }
    $s.Add(@{Op='dealloc-return'})
    $s.ToArray()
}
