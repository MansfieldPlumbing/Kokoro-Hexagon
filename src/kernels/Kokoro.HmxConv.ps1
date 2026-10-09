#requires -Version 7.4
# HMX int8 dilated Conv1d (same padding), one 32-row output tile per loop iteration.
# Algorithm and layouts proven bit-exact in hexagon-sim: docs/results/hmx-dilated-conv-sim-20261006.md.
#
# Calling convention (plain function, caller-saved registers only):
#   r0 = activation tile 0 (VTCM): crouton (tp, cb) at (tp*CB + cb)*2048, tp counted from the first
#        real tile; PAD halo tiles of zero point 128 precede and follow it.
#   r1 = weights (VTCM), consumption order: group g, tap k, input block cb; 2 KB each =
#        output channels 64g+0..31 then 64g+32..63, W(i, c) at byte 128*(i/4) + 4*c + i%4.
#   r2 = output tile 0 (VTCM), crouton (tb, ob) at (tb*OB + ob)*2048, byte 2*IDX(row, c) + 1.
#   r3 = column tables, 256 B per output block ob: words 0..31 fp16 scale, words 32..63 int32 bias.
#   r4 = number of 32-row output tiles (>= 1).
#   With -OutputPlanes: r3 holds two tables per output block at 512*ob (high plane, then low plane),
#   and r5 = low-plane output tile 0, same crouton addressing as r2. The high store keeps the
#   accumulator (:retain:sat.ub); the low store wraps (.ub). With power-of-two scales 2^(1-L) and
#   2^(9-L) both stores are exact bytes of the same biased accumulator: high = sat(floor(a/2^(L+8))),
#   low = floor(a/2^L) mod 256 (onnxsim 0dd9980a scripts/android/hmx_gemm/README.md:297-311).
# Activation u8 = x + 128; the table's int32 must carry -128*sum(w) for the zero point.
function New-KokoroHmxConvSteps {
    param(
        [ValidateSet(128, 256)][int] $InputChannels = 128,
        [ValidateSet(128, 256)][int] $OutputChannels = 128,
        [ValidateSet(3, 7, 11)][int] $Kernel = 3,
        [ValidateSet(1, 3, 5)][int] $Dilation = 1,
        [string] $LabelPrefix = 'hmxconv',
        # Two accumulator byte planes per output (see calling convention).
        [switch] $OutputPlanes,
        # Fall through instead of returning, for inlining into a caller.
        [switch] $NoReturn
    )
    $cb = $InputChannels / 32; $ob = $OutputChannels / 32; $groups = $OutputChannels / 64
    $half = ($Kernel - 1) / 2
    if ($Dilation * $half -gt 31) { throw 'Tap shift exceeds one crouton' }
    $s = [Collections.Generic.List[hashtable]]::new()
    # rt for the :single read: dY = one time tile (CB croutons), all-Y spatial mask, channels 0..31.
    $dy = $cb * 2048
    $rt = $dy -bor 0x7ff
    $s.Add(@{Op='lo'; x=7; i=($rt -band 65535)}); $s.Add(@{Op='hi'; x=7; i=($rt -shr 16)})
    $s.Add(@{Op='imm'; d=8; i=0x7ff})                 # weight :deep range (2 KB)
    $s.Add(@{Op='imm'; d=9; i=0})                     # store Rt, loop compare zero
    $s.Add(@{Op='label'; Name="${LabelPrefix}_tile"})
    $s.Add(@{Op='addi'; d=10; s=1; i=0})              # weight pointer restarts each tile
    for ($g = 0; $g -lt $groups; $g++) {
        $s.Add(@{Op='mxclracc'})
        for ($k = 0; $k -lt $Kernel; $k++) {
            $shift = $Dilation * ($k - $half)
            $tile = [math]::Floor($shift / 32); $row = $shift - 32 * $tile
            for ($c = 0; $c -lt $cb; $c++) {
                $offset = (($tile * $cb) + $c) * 2048 + (($row -shr 1) -shl 7) + (($row -band 1) -shl 1)
                if ($offset -lt -32768 -or $offset -gt 32767) { throw 'Activation offset out of addi range' }
                $s.Add(@{Op='addi'; d=6; s=0; i=$offset})
                $s.Add(@{Op='hmx-pair'; Act='act-ub-single'; Wt='wt-b-deep'; s=6; t=7; u=10; v=8})
                $s.Add(@{Op='addi'; d=10; s=10; i=2048})
            }
        }
        foreach ($h in 0, 1) {
            $o = 2 * $g + $h
            if ($OutputPlanes) {
                # Retained stores repeat this half; the final non-retaining store moves to the next
                # (onnxsim 0dd9980a scripts/android/hmx_gemm/hmx_qconv.h:226-234).
                $s.Add(@{Op='addi'; d=11; s=3; i=(512 * $o)})
                $s.Add(@{Op='bias-mxmem2'; s=11})
                $s.Add(@{Op='addi'; d=12; s=2; i=(2048 * $o)})
                $s.Add(@{Op='mxmem-after-retain-sat-ub'; s=12; t=9})
                $s.Add(@{Op='addi'; d=11; s=3; i=(512 * $o + 256)})
                $s.Add(@{Op='bias-mxmem2'; s=11})
                $s.Add(@{Op='addi'; d=12; s=5; i=(2048 * $o)})
                $s.Add(@{Op='mxmem-after-ub'; s=12; t=9})
            } else {
                $s.Add(@{Op='addi'; d=11; s=3; i=(256 * $o)})
                $s.Add(@{Op='bias-mxmem2'; s=11})
                $s.Add(@{Op='addi'; d=12; s=2; i=(2048 * $o)})
                $s.Add(@{Op='mxmem-after-sat-ub'; s=12; t=9})
            }
        }
    }
    $s.Add(@{Op='addi'; d=0; s=0; i=$dy})             # next input tile
    $s.Add(@{Op='addi'; d=2; s=2; i=($ob * 2048)})    # next output tile
    if ($OutputPlanes) { $s.Add(@{Op='addi'; d=5; s=5; i=($ob * 2048)}) }
    $s.Add(@{Op='addi'; d=4; s=4; i=-1})
    $s.Add(@{Op='gtu'; d=0; s=4; t=9})
    $s.Add(@{Op='jump-p'; u=0; Label="${LabelPrefix}_tile"})
    if (-not $NoReturn) { $s.Add(@{Op='return'}) }
    $s.ToArray()
}
