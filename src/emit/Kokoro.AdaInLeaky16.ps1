#requires -Version 7.4
# Fused stock AdaIN1d then LeakyReLU(0.2) over 16-bit activations, for the decoder's AdainResBlk1d (docs/decoder-design.md).
# Kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec istftnet.py:20-31 (AdaIN1d) and AdainResBlk1d._residual (actv =
# LeakyReLU(0.2)). AdaIN folds to a per-channel affine of x (Kokoro.AdaInTurnsCoefficients.ps1,
# New-KokoroAdaInAffineCoefficientsLoopSteps): y = K * x * 2^16 >> 31 + M in output LSB, then
#     out = max(y, y * 0.2)            (0.2 as the Q31 multiplier 429496730)
# clamped to int16.
#   -Output Windows: the two conv-input byte planes, as Kokoro.AdaInSnakeTurns.ps1 (high (out >> 8) + 128, low out & 255,
#                    each in the odd byte of its halfword).
#   -Output Tensor:  out stored biased (u16 = out + 32768), for decode.3, whose pool follows.
# Layout: native croutons, tile stride 64 * Channels bytes; each 128-byte vector is a row pair x 32 channels (even halfword
# of word lane j row 2r, odd halfword row 2r+1 of channel 32*block + j).
# r0 input tiles (biased u16), r1 high window tiles (Tensor: output tiles), r2 low window tiles (Windows only),
# r3 constants, 256 bytes per block: K[32] at 0, M[32] at 128 (int32), r4 tiles >= 1. Uses r5..r15, v0..v21, v29..v31;
# r16..r27 are untouched.
function New-KokoroAdaInLeaky16Steps {
    param([ValidateRange(32,2048)][int]$Channels=1120,[ValidateSet('Windows','Tensor')][string]$Output='Windows',
        [string]$LabelPrefix='adainleaky16',[switch]$NoReturn)
    if ($Channels % 32) { throw 'Channels must be whole 32-channel blocks' }
    $s = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL); $s.Add(@{Op='lo';x=$r;i=($u -band 65535)}); $s.Add(@{Op='hi';x=$r;i=($u -shr 16)}) }
    $splat = { param([int]$v,[long]$value) & $imm 13 $value; $s.Add(@{Op='vsplat';d=$v;s=13}) }
    & $splat 31 0x80008000L                     # u16 bias
    & $splat 30 0xFFFF0000L                     # odd-halfword mask
    & $splat 29 0x0000FFFFL                     # even-halfword mask
    & $splat 21 128
    & $splat 20 255
    & $splat 18 32767
    & $splat 17 -32768
    & $splat 16 429496730                       # 0.2, Q31
    foreach ($kv in @(@(8,16),@(9,8),@(12,24),@(7,0))) { $s.Add(@{Op='imm';d=$kv[0];i=$kv[1]}) }
    & $imm 11 ($Channels*64-2048)               # end of a block's tile to the same block of the next tile
    $s.Add(@{Op='addi';d=6;s=3;i=0})            # constants of the block
    $s.Add(@{Op='addi';d=10;s=0;i=0}); $s.Add(@{Op='addi';d=28;s=1;i=0}); $s.Add(@{Op='addi';d=3;s=2;i=0})
    $s.Add(@{Op='imm';d=2;i=($Channels/32)})
    $s.Add(@{Op='label';Name="${LabelPrefix}_block"})
    $s.Add(@{Op='vload';d=14;s=6;Offset=0})     # K
    $s.Add(@{Op='vload';d=15;s=6;Offset=128})   # M
    $s.Add(@{Op='addi';d=5;s=10;i=0}); $s.Add(@{Op='addi';d=1;s=28;i=0}); $s.Add(@{Op='addi';d=13;s=3;i=0})
    $s.Add(@{Op='addi';d=15;s=4;i=0})
    $s.Add(@{Op='label';Name="${LabelPrefix}_tile"})
    $s.Add(@{Op='imm';d=14;i=16})
    $s.Add(@{Op='label';Name="${LabelPrefix}_pair"})
    $s.Add(@{Op='vload';d=0;s=5;Offset=0})
    $s.Add(@{Op='vxor';d=0;s=0;t=31})                       # signed halfwords
    $s.Add(@{Op='vasl-w';d=1;s=0;t=8})                      # even row x * 2^16
    $s.Add(@{Op='vand';d=2;s=0;t=30})                       # odd row  x * 2^16
    foreach ($p in @(@(10,1),@(11,2))) {
        $s.Add(@{Op='vmpye-w-uh';d=$p[0];s=$p[1];t=14})                         # y = K * x * 2^16 >> 31 + M
        $s.Add(@{Op='vmpyo-acc-w-h-rnd-sat-shift';d=$p[0];s=$p[1];t=14})
        $s.Add(@{Op='vadd-w';d=$p[0];s=$p[0];t=15})
        $s.Add(@{Op='vmpye-w-uh';d=3;s=$p[0];t=16})                             # 0.2 y
        $s.Add(@{Op='vmpyo-acc-w-h-rnd-sat-shift';d=3;s=$p[0];t=16})
        $s.Add(@{Op='vmax-w';d=$p[0];s=$p[0];t=3})                              # LeakyReLU
        $s.Add(@{Op='vmax-w';d=$p[0];s=$p[0];t=17})
        $s.Add(@{Op='vmin-w';d=$p[0];s=$p[0];t=18})
    }
    if ($Output -eq 'Windows') {
        $s.Add(@{Op='vasr-w';d=12;s=10;t=9}); $s.Add(@{Op='vadd-w';d=12;s=12;t=21}); $s.Add(@{Op='vasl-w';d=12;s=12;t=9})
        $s.Add(@{Op='vasr-w';d=13;s=11;t=9}); $s.Add(@{Op='vadd-w';d=13;s=13;t=21}); $s.Add(@{Op='vasl-w';d=13;s=13;t=12})
        $s.Add(@{Op='vor';d=12;s=12;t=13})
        $s.Add(@{Op='vstore';s=1;t=12;Offset=0})
        $s.Add(@{Op='vand';d=10;s=10;t=20}); $s.Add(@{Op='vasl-w';d=10;s=10;t=9})
        $s.Add(@{Op='vand';d=11;s=11;t=20}); $s.Add(@{Op='vasl-w';d=11;s=11;t=12})
        $s.Add(@{Op='vor';d=10;s=10;t=11})
        $s.Add(@{Op='vstore';s=13;t=10;Offset=0})
        $s.Add(@{Op='addi';d=13;s=13;i=128})
    } else {
        $s.Add(@{Op='vand';d=10;s=10;t=29}); $s.Add(@{Op='vasl-w';d=11;s=11;t=8})
        $s.Add(@{Op='vor';d=10;s=10;t=11}); $s.Add(@{Op='vxor';d=10;s=10;t=31})
        $s.Add(@{Op='vstore';s=1;t=10;Offset=0})
    }
    $s.Add(@{Op='addi';d=5;s=5;i=128}); $s.Add(@{Op='addi';d=1;s=1;i=128})
    $s.Add(@{Op='addi';d=14;s=14;i=-1})
    $s.Add(@{Op='gtu';d=0;s=14;t=7})
    $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_pair"})
    $s.Add(@{Op='add';d=5;s=5;t=11}); $s.Add(@{Op='add';d=1;s=1;t=11})
    if ($Output -eq 'Windows') { $s.Add(@{Op='add';d=13;s=13;t=11}) }
    $s.Add(@{Op='addi';d=15;s=15;i=-1})
    $s.Add(@{Op='gtu';d=0;s=15;t=7})
    $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_tile"})
    $s.Add(@{Op='addi';d=6;s=6;i=256})
    $s.Add(@{Op='addi';d=10;s=10;i=2048}); $s.Add(@{Op='addi';d=28;s=28;i=2048}); $s.Add(@{Op='addi';d=3;s=3;i=2048})
    $s.Add(@{Op='addi';d=2;s=2;i=-1})
    $s.Add(@{Op='gtu';d=0;s=2;t=7})
    $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_block"})
    if (-not $NoReturn) { $s.Add(@{Op='return'}) }
    $s.ToArray()
}
