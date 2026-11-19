#requires -Version 7.4
# Fused stock AdaIN1d then Snake over 16-bit activations, emitting the two conv-input byte planes.
# Kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec istftnet.py:20-31 (AdaIN1d) and :68-77 (Snake,
# one alpha inside and outside). AdaIN folds to a per-channel affine of x; with the phase in turns
# P = alpha*y/pi = (K*x + M) / 2^24, stock Snake is
#     s = (pi/alpha) * (P + (1 - cos(2*pi*P)) / (2*pi)).
# The fractional turn of P is the cos argument (wraparound is the range reduction); 1 - cos is
# 1 + sin(pi/2*u), u = 4g - 1 on the half turn |g|, a five-term odd Q14 polynomial in Q15 halfword
# arithmetic.
#
# Layout: native croutons; each 128-byte vector holds a row pair x 32 channels as halfwords, the even
# halfword of word lane j is row 2r and the odd halfword row 2r+1 of channel j.
# r0 input tiles: biased u16 per value (x + 32768).
# r1 high-plane window tiles: u8 = (out >> 8) + 128 in the odd byte of each halfword.
# r2 low-plane window tiles: u8 = out & 255 in the odd byte of each halfword.
# r3 per-channel constants, int32 each: K[C] at 0 (Q31 multiplier of x*2^16, giving QT turns),
#    M[C] at 4C (QT turns), S[C] at 8C (Q31 multiplier of QT turns giving the 16-bit output).
# r4 tiles >= 1. out is clamped to int16 before the plane split. r16..r28 are preserved.
# -TurnsBits QT (24 above; 22 gives K four times the range, one input LSB up to 1/64 turn): the cos
# argument stays the 16-bit fractional turn, bits QT-16..QT-1 of P.
function New-KokoroAdaInSnakeTurnsSteps {
    # -ControllerContact: r3 also holds P_K[C] at 12C and P_M[C] at 16C, and r5 points at the first tile's controller word
    # (v << 16, int32, one word per tile). Each tile computes K = K_base + P_K * v and M = M_base + P_M * v per channel
    # with the Q31 multiply used for K * x; v = 0 leaves K and M exactly the base values. r16 is saved and restored.
    # -MirrorDelta: nonzero, every output vector is also stored at its address plus this byte delta (the guard copy of a
    # ring's last tiles). With either option r16 to r18 are saved and restored.
    param([ValidateSet(128,256)][int]$Channels=128,[ValidateSet(22,24)][int]$TurnsBits=24,[string]$LabelPrefix='adainsnaketurns',[switch]$NoReturn,[switch]$ControllerContact,[long]$MirrorDelta=0)
    $frame = $ControllerContact -or $MirrorDelta -ne 0
    if ($frame -and $NoReturn) { throw 'The controller contact and mirrored stores restore r16 to r18 on return.' }
    # Shift registers: fraction of both rows (right, QT-16) and (1-cos)/(2 pi)
    # from Q30 to QT (right, 30-QT); r9 = 8, r11 = 6.
    $sh = if ($TurnsBits -eq 24) { @{ Fraction = 9; Cos = 11 } } else { @{ Fraction = 11; Cos = 9 } }
    $q14 = foreach ($k in 1..5) {
        $f = 1.0; for ($i = 1; $i -le 2 * $k - 1; $i++) { $f *= $i }
        [int][math]::Round([math]::Pow(-1, $k - 1) * [math]::Pow([math]::PI / 2, 2 * $k - 1) / $f * 16384)
    }
    $s = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int]$r,[long]$v) $u=[long]([uint32]($v -band 0xffffffffL)); $s.Add(@{Op='lo';x=$r;i=($u -band 65535)}); $s.Add(@{Op='hi';x=$r;i=($u -shr 16)}) }
    $splat = { param([int]$v,[long]$value) & $imm 13 $value; $s.Add(@{Op='vsplat';d=$v;s=13}) }
    $half = { param([int]$h) [long](($h -band 0xffff) -bor (($h -band 0xffff) -shl 16)) }
    if ($frame) { $s.Add(@{Op='allocframe';Bytes=16}); foreach ($r in 16,17,18) { $s.Add(@{Op='store';s=29;t=$r;Offset=(4*($r-16))}) } }
    if ($ControllerContact) { $s.Add(@{Op='addi';d=16;s=5;i=0}) }
    if ($MirrorDelta) { & $imm 18 $MirrorDelta }
    # Resident constants.
    & $splat 31 0x80008000L                     # u16 bias
    & $splat 29 0xFF00FF00L                     # high byte of each packed output
    & $splat 28 (& $half 16384)                 # 1.0 in Q14
    for ($k = 0; $k -lt 5; $k++) { & $splat (23 + $k) (& $half $q14[$k]) }   # v23 = h0 ... v27 = h4
    & $splat 22 (& $half 10430)                           # round(2^16 / (2*pi)) in each even halfword
    foreach ($kv in @(@(8,16),@(9,8),@(10,1),@(11,6),@(7,0))) { $s.Add(@{Op='imm';d=$kv[0];i=$kv[1]}) }
    $s.Add(@{Op='imm';d=12;i=($Channels/32)})
    $s.Add(@{Op='label';Name="${LabelPrefix}_channel"})
    $block=0
    & {
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
        if ($ControllerContact) {
            # This tile's controller word: r16 + 4 * (tiles done = r4 - r15), splat; then K and M from base + P * v.
            $s.Add(@{Op='sub';d=14;s=4;t=15}); $s.Add(@{Op='asl-i';d=14;s=14;i=2}); $s.Add(@{Op='add';d=14;s=14;t=16})
            $s.Add(@{Op='load';d=14;s=14;Offset=0}); $s.Add(@{Op='vsplat';d=0;s=14})
            foreach ($m in @(@(14,0),@(15,($Channels*4)))) {
                $s.Add(@{Op='addi';d=14;s=3;i=($block*128+$m[1])}); $s.Add(@{Op='vload';d=$m[0];s=14;Offset=0})
                $s.Add(@{Op='addi';d=14;s=14;i=($Channels*12)}); $s.Add(@{Op='vload';d=1;s=14;Offset=0})
                $s.Add(@{Op='vmpye-w-uh';d=2;s=1;t=0}); $s.Add(@{Op='vmpyo-acc-w-h-rnd-sat-shift';d=2;s=1;t=0})
                $s.Add(@{Op='vadd-w';d=$m[0];s=$m[0];t=2})
            }
        }
        $width=4
        $s.Add(@{Op='imm';d=14;i=(16/$width)})
        $s.Add(@{Op='loop0-r';s=14;Label=$pair}); $s.Add(@{Op='label';Name=$pair})
        $innerStart=$s.Count
        $s.Add(@{Op='vload';d=0;s=5;Offset=0})
        $s.Add(@{Op='vxor';d=0;s=0;t=31})                       # signed halfwords
        $s.Add(@{Op='vasl-w';d=1;s=0;t=8})                      # even row x * 2^16
        # Both rows multiply a signed halfword by a Q31 constant. The old low
        # partial product was exact because the activation word had 16 zero low bits.
        $s.Add(@{Op='vmpyo-w-h-rnd';d=3;s=14;t=1})
        $s.Add(@{Op='vmpyo-w-h-rnd';d=4;s=14;t=0})
        $s.Add(@{Op='vadd-w';d=3;s=3;t=15}); $s.Add(@{Op='vadd-w';d=4;s=4;t=15})
        # 16-bit fractional turn of both rows in one halfword vector.
        $s.Add(@{Op='vlsr-uw';d=5;s=3;t=$sh.Fraction}); $s.Add(@{Op='vlsr-uw';d=6;s=4;t=$sh.Fraction})
        $s.Add(@{Op='vshuffe-h';d=5;s=6;t=5})
        $s.Add(@{Op='vabs-h-sat';d=5;s=5})                      # fold onto [0, 1/2) turn
        $s.Add(@{Op='vsub-h';d=5;s=5;t=28})
        $s.Add(@{Op='vasl-h';d=5;s=5;t=10})                     # u = 4g - 1, Q15
        $s.Add(@{Op='vmpy-h-rnd-sat';d=6;s=5;t=5})              # z = u^2
        $s.Add(@{Op='vmpy-h-rnd-sat';d=7;s=27;t=6}); $s.Add(@{Op='vadd-h';d=7;s=7;t=26})
        foreach ($c in 25,24,23) { $s.Add(@{Op='vmpy-h-rnd-sat';d=7;s=7;t=6}); $s.Add(@{Op='vadd-h';d=7;s=7;t=$c}) }
        $s.Add(@{Op='vmpy-h-rnd-sat';d=7;s=7;t=5})              # sin(pi/2 u), Q14
        $s.Add(@{Op='vadd-h-sat';d=7;s=7;t=28})                 # 1 - cos, Q14
        # Back to words per row, scale (1 - cos)/(2 pi) into QT turns, add to P.
        $s.Add(@{Op='vmpy-ww-h-h';d=8;s=7;t=22})
        foreach ($p in @(@(8,3),@(9,4))) {

            $s.Add(@{Op='vasr-w';d=$p[0];s=$p[0];t=$sh.Cos})
            $s.Add(@{Op='vadd-w';d=$p[1];s=$p[1];t=$p[0]})
        }
        foreach ($p in @(@(10,3),@(11,4))) {                    # out = V*S >> 31, clamped to int16
            $s.Add(@{Op='vmpye-w-uh';d=$p[0];s=$p[1];t=16})
            $s.Add(@{Op='vmpyo-acc-w-h-rnd-sat-shift';d=$p[0];s=$p[1];t=16})
        }
        # Interleave the clamped rows once. The high plane flips the sign bit;
        # the halfword shift places each low byte directly in its window lane.
        $s.Add(@{Op='vsat-h-w';d=10;s=11;t=10})
        $s.Add(@{Op='vand';d=12;s=10;t=29}); $s.Add(@{Op='vxor';d=12;s=12;t=31})
        $s.Add(@{Op='vstore';s=6;t=12;Offset=0})
        if ($MirrorDelta) { $s.Add(@{Op='add';d=17;s=6;t=18}); $s.Add(@{Op='vstore';s=17;t=12;Offset=0}) }
        $s.Add(@{Op='vasl-h';d=10;s=10;t=9})
        $s.Add(@{Op='vstore';s=13;t=10;Offset=0})
        if ($MirrorDelta) { $s.Add(@{Op='add';d=17;s=13;t=18}); $s.Add(@{Op='vstore';s=17;t=10;Offset=0}) }
        # Generate the original row-pair operations once, then schedule four independent inputs.
        if($width -eq 4){
            $body=$s.GetRange($innerStart,$s.Count-$innerStart)
            $s.RemoveRange($innerStart,$body.Count)
            # Each column names one temporary in a row pair. The two later pairs reuse
            # polynomial temporaries after the first two pairs have stored their output.
            $map=0,1,2,2,0,1,3,4,1,3,1,3,2
            $banks=@(@(2,0,3,1,4),@(5,6,9,7,8),@(12,10,13,11,17),@(20,18,21,19,30))
            foreach($section in 0){
                $ops=$body
                $lanes=0..3
                foreach($step in $ops){
                    if($step.Op -eq 'add'){ $s.Add($step); continue }
                    foreach($lane in $lanes){
                        $copy=$step.Clone()
                        $fields=switch -Regex ($step.Op){
                            '^vload$' { 'd'; break }
                            '^vstore$' { 't'; break }
                            '^vabs|^vasl-|^vasr-|^vlsr-' { 'd';'s'; break }
                            default {'d';'s';'t'}
                        }
                        foreach($field in $fields){
                            $v=$step[$field]
                            if($v -lt $map.Count){$copy[$field]=$banks[$lane][$map[$v]]}
                        }
                        if($copy.ContainsKey('Offset')){$copy.Offset=128*$lane}
                        $s.Add($copy)
                    }
                }
            }
        }
        $s.Add(@{Op='addi';d=5;s=5;i=(128*$width)}); $s.Add(@{Op='addi';d=6;s=6;i=(128*$width)}); $s.Add(@{Op='addi';d=13;s=13;i=(128*$width)})
        $s.Add(@{Op='endloop0'})
        $s.Add(@{Op='addi';d=5;s=5;i=($Channels*64-2048)}); $s.Add(@{Op='addi';d=6;s=6;i=($Channels*64-2048)}); $s.Add(@{Op='addi';d=13;s=13;i=($Channels*64-2048)})
        $s.Add(@{Op='addi';d=15;s=15;i=-1})
        $s.Add(@{Op='gtu';d=0;s=15;t=7})
        $s.Add(@{Op='jump-p';u=0;Label=$tile})
    }
    foreach($arg in 0,1,2){$s.Add(@{Op='addi';d=$arg;s=$arg;i=2048})}
    $s.Add(@{Op='addi';d=3;s=3;i=128})
    $s.Add(@{Op='addi';d=12;s=12;i=-1});$s.Add(@{Op='gtu';d=0;s=12;t=7});$s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_channel"})
    if ($frame) { foreach ($r in 16,17,18) { $s.Add(@{Op='load';d=$r;s=29;Offset=(4*($r-16))}) }; $s.Add(@{Op='dealloc-return'}) }
    elseif (-not $NoReturn) { $s.Add(@{Op='return'}) }
    $s.ToArray()
}
