#requires -Version 7.4
# HMX int8 dilated Conv1d (same padding) over a two-plane input, two accumulator groups per output
# tile, each stored as two exact byte planes. Design: docs/generator60x-16bit-design.md ("Conv").
#   A1 = sum (h - 128) * Wh                      high window x high weights
#   A2 = sum l * Wh  [+ sum (h - 128) * Wl]      low window x high weights [+ high window x low weights]
#   A3 = sum l * Wl                              (-WeightPlanes 2 only) low window x low weights
# The conv value is A1 * 256 + A2 [+ A3 / 256]. The low x low product is kept: with absmax scales the
# low planes are only 18-27 dB (inputs) and 35-40 dB (weights) below their signals, and omitting it cost
# 1.1-1.3 dB PCM on the frozen 42 dB plan (docs/results/generator60x-16bit-kernels-sim-20261007.md). Each group leaves through a retained saturating store and a
# wrapping store (docs/results/hmx-two-plane-output-sim-20261007.md), so with power-of-two table
# scales the four byte planes are exact bytes of a 16-bit window of each group.
#
# Calling convention (plain function, caller-saved registers only):
#   r0 = high window tile 0 (u8, zero point 128), r1 = low window tile 0 (u8, zero point 0), same
#        crouton addressing as Kokoro.HmxConv.ps1; PAD halo tiles precede and follow each.
#   r2 = Wh, consumption order group g, tap k, input block cb, 2 KB each (as Kokoro.HmxConv.ps1).
#   r3 = column tables, 512*groups bytes per output block ob: for each group, high then low (256 B each).
#   r4 = number of 32-row output tiles (>= 1).
#   r5 = plane output base: plane p = 2*group + (0 high, 1 low) of output tile tb, block ob at
#        r5 + p*PlaneStride + (tb*OB + ob)*2048, the byte in the odd position of each halfword.
#   With -WeightPlanes 2, Wl follows Wh directly (r2 + groups*Kernel*CB*2048), same order.
function New-KokoroHmxConvPlanesSteps {
    param(
        [ValidateSet(64, 128, 256, 512)][int] $InputChannels = 128,
        [ValidateSet(64, 128, 256)][int] $OutputChannels = 128,
        [ValidateSet(3, 7, 11)][int] $Kernel = 3,
        [ValidateSet(1, 3, 5)][int] $Dilation = 1,
        [ValidateSet(1, 2)][int] $WeightPlanes = 1,
        [Parameter(Mandatory)][ValidateRange(2048, 1073741824)][long] $PlaneStride,
        [string] $LabelPrefix = 'hmxconvplanes',
        [switch] $NoReturn
    )
    $cb = $InputChannels / 32; $ob = $OutputChannels / 32; $groups = $OutputChannels / 64
    $accGroups = if ($WeightPlanes -eq 2) { 3 } else { 2 }
    $wlOffset = $groups * $Kernel * $cb * 2048
    $half = ($Kernel - 1) / 2
    if ($Dilation * $half -gt 31) { throw 'Tap shift exceeds one crouton' }
    if ($PlaneStride % 2048 -ne 0) { throw 'Plane stride must keep 2 KB tile alignment' }
    $s = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL); $s.Add(@{Op='lo';x=$r;i=($u -band 65535)}); $s.Add(@{Op='hi';x=$r;i=($u -shr 16)}) }
    $dy = $cb * 2048
    & $imm 9 ($dy -bor 0x7ff)                          # :single activation range
    $s.Add(@{Op='imm'; d=10; i=0x7ff})                # weight :deep range
    $s.Add(@{Op='imm'; d=11; i=0})                    # store Rt, loop compare zero
    # One MAC sequence: activation base register, weight base register.
    $macs = { param([int]$act,[int]$wt)
        $s.Add(@{Op='addi'; d=12; s=$wt; i=0})
        for ($k = 0; $k -lt $Kernel; $k++) {
            $shift = $Dilation * ($k - $half)
            $tile = [math]::Floor($shift / 32); $row = $shift - 32 * $tile
            for ($c = 0; $c -lt $cb; $c++) {
                $offset = (($tile * $cb) + $c) * 2048 + (($row -shr 1) -shl 7) + (($row -band 1) -shl 1)
                if ($offset -lt -32768 -or $offset -gt 32767) { throw 'Activation offset out of addi range' }
                $s.Add(@{Op='addi'; d=8; s=$act; i=$offset})
                $s.Add(@{Op='hmx-pair'; Act='act-ub-single'; Wt='wt-b-deep'; s=8; t=9; u=12; v=10})
                $s.Add(@{Op='addi'; d=12; s=12; i=2048})
            }
        }
    }
    $s.Add(@{Op='label'; Name="${LabelPrefix}_tile"})
    for ($g = 0; $g -lt $groups; $g++) {
        $gw = $g * $Kernel * $cb * 2048
        foreach ($group in 0..($accGroups - 1)) {
            $s.Add(@{Op='mxclracc'})
            if ($group -eq 0) {
                & $imm 15 $gw; $s.Add(@{Op='add'; d=13; s=2; t=15}); & $macs 0 13
            } elseif ($group -eq 1) {
                & $imm 15 $gw; $s.Add(@{Op='add'; d=13; s=2; t=15}); & $macs 1 13
                if ($WeightPlanes -eq 2) { & $imm 15 ($wlOffset + $gw); $s.Add(@{Op='add'; d=13; s=2; t=15}); & $macs 0 13 }
            } else {
                & $imm 15 ($wlOffset + $gw); $s.Add(@{Op='add'; d=13; s=2; t=15}); & $macs 1 13
            }
            foreach ($h in 0, 1) {
                $o = 2 * $g + $h
                foreach ($plane in 0, 1) {
                    $p = 2 * $group + $plane
                    $s.Add(@{Op='addi'; d=14; s=3; i=(512 * $accGroups * $o + 256 * $p)})
                    $s.Add(@{Op='bias-mxmem2'; s=14})
                    & $imm 15 ($p * $PlaneStride + 2048 * $o)
                    $s.Add(@{Op='add'; d=14; s=5; t=15})
                    $s.Add(@{Op=$(if ($plane -eq 0) { 'mxmem-after-retain-sat-ub' } else { 'mxmem-after-ub' }); s=14; t=11})
                }
            }
        }
    }
    if ($dy -le 32767) { $s.Add(@{Op='addi'; d=0; s=0; i=$dy}); $s.Add(@{Op='addi'; d=1; s=1; i=$dy}) }
    else { & $imm 15 $dy; $s.Add(@{Op='add'; d=0; s=0; t=15}); $s.Add(@{Op='add'; d=1; s=1; t=15}) }   # 512-channel tiles: 32 KB
    $s.Add(@{Op='addi'; d=5; s=5; i=($ob * 2048)})
    $s.Add(@{Op='addi'; d=4; s=4; i=-1})
    $s.Add(@{Op='gtu'; d=0; s=4; t=11})
    $s.Add(@{Op='jump-p'; u=0; Label="${LabelPrefix}_tile"})
    if (-not $NoReturn) { $s.Add(@{Op='return'}) }
    $s.ToArray()
}
