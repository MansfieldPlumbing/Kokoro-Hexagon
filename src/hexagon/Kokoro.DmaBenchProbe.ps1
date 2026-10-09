#requires -Version 7.4
# FastRPC skel: user DMA against memcpy for DDR<->VTCM copies of one native tensor.
# Resource acquisition and power votes are those of Kokoro.VtcmQueryProbe.ps1 (application ID 0,
# whole partition, HMX). DMA uses the emitted Kokoro.DmaCopy.ps1 body (two chained 1D descriptors).
#
# Method 2, sc 0x02010100 (1 in, 1 out).
#   in0:  [0] u32 bytes (multiple of 128, 128..2^24), [4] u32 repetitions (1..64), data at 128.
#         Descriptors stay in DDR (the skel frame); descriptors in VTCM crashed SM8550.
#   out0: telemetry 256 B, then dmaDst[bytes] (written only by DMA), then memcpyDst[bytes].
#   [0] stage reached, [4] power rc, [8] context id, [12] granted bytes, [16] DMA-in check
#   (OR of word differences VTCM vs input after one DMA, 0 = equal), [20] release rc,
#   [24] dmwait status after the checked copies, [28] query rc,
#   [32] ticks memcpy DDR->VTCM, [36] DMA DDR->VTCM, [40] memcpy VTCM->DDR, [44] DMA VTCM->DDR
#   (19.2 MHz ticks summed over the repetitions); [48] ticks of the checked DMA in, [52] checked DMA out;
#   read right after dmwait: [56]/[64] done bits (desc0<<1 | desc1) in/out, [60]/[68] last word XOR in/out.
function New-KokoroDmaBenchSteps {
    . (Join-Path $PSScriptRoot 'Kokoro.DmaCopy.ps1')
    $s = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int]$r, [long]$v) $u = [uint32]($v -band 0xFFFFFFFFL); $s.Add(@{Op='lo'; x=$r; i=($u -band 65535)}); $s.Add(@{Op='hi'; x=$r; i=($u -shr 16)}) }
    $tele = { param([int]$Offset, [int]$Reg) $s.Add(@{Op='store'; s=23; t=$Reg; Offset=$Offset}) }
    $stage = { param([int]$Value) $s.Add(@{Op='imm'; d=13; i=$Value}); & $tele 0 13 }
    $call = { param([string]$Name) $s.Add(@{Op='got-call'; Import=$Name; d=14}) }
    # r19 = 64-byte aligned descriptor slots in the frame.
    $dma = { param([int]$Dest, [int]$Source)
        $s.Add(@{Op='addi'; d=1; s=$Source; i=0}); $s.Add(@{Op='addi'; d=2; s=$Dest; i=0})
        $s.Add(@{Op='addi'; d=3; s=21; i=0}); $s.Add(@{Op='addi'; d=0; s=19; i=0})
        foreach ($step in @(New-KokoroDmaCopySteps -NoReturn)) { $s.Add($step) }
    }
    $copy = { param([int]$Dest, [int]$Source)
        $s.Add(@{Op='addi'; d=0; s=$Dest; i=0}); $s.Add(@{Op='addi'; d=1; s=$Source; i=0}); $s.Add(@{Op='addi'; d=2; s=21; i=0})
        & $call 'memcpy'
    }
    $timed = { param([string]$Name, [int]$Offset, [scriptblock]$Body)
        $s.Add(@{Op='addi'; d=25; s=22; i=0})
        $s.Add(@{Op='hwticks'; d=0}); $s.Add(@{Op='store'; s=29; t=0; Offset=360})
        $s.Add(@{Op='label'; Name="rep_$Name"})
        & $Body
        $s.Add(@{Op='addi'; d=25; s=25; i=-1}); $s.Add(@{Op='imm'; d=15; i=0})
        $s.Add(@{Op='gtu'; d=0; s=25; t=15}); $s.Add(@{Op='jump-p'; u=0; Label="rep_$Name"})
        $s.Add(@{Op='hwticks'; d=0}); $s.Add(@{Op='load'; d=1; s=29; Offset=360})
        $s.Add(@{Op='sub'; d=0; s=0; t=1}); & $tele $Offset 0
    }

    foreach ($d in @(@(0x00020001, 'open'), @(0x01000010, 'success'), @(0x02010100, 'run'))) {
        & $imm 4 $d[0]; $s.Add(@{Op='eq'; d=0; s=2; t=4}); $s.Add(@{Op='jump-p'; u=0; Label=$d[1]})
    }
    $s.Add(@{Op='imm'; d=0; i=20}); $s.Add(@{Op='return'})
    $s.Add(@{Op='label'; Name='open'}); $s.Add(@{Op='imm'; d=4; i=0})
    $s.Add(@{Op='eq'; d=0; s=3; t=4}); $s.Add(@{Op='jump-p'; u=0; Label='bad'})
    $s.Add(@{Op='imm'; d=4; i=1}); $s.Add(@{Op='store'; s=3; t=4; Offset=16})
    $s.Add(@{Op='imm'; d=4; i=0}); $s.Add(@{Op='store'; s=3; t=4; Offset=20})
    $s.Add(@{Op='label'; Name='success'}); $s.Add(@{Op='imm'; d=0; i=0}); $s.Add(@{Op='return'})
    $s.Add(@{Op='label'; Name='bad'}); $s.Add(@{Op='imm'; d=0; i=14}); $s.Add(@{Op='return'})

    $s.Add(@{Op='label'; Name='run'})
    $s.Add(@{Op='imm'; d=4; i=0}); $s.Add(@{Op='eq'; d=0; s=3; t=4}); $s.Add(@{Op='jump-p'; u=0; Label='bad'})
    for ($a = 0; $a -lt 2; $a++) {
        $s.Add(@{Op='load'; d=0; s=3; Offset=(8 * $a)}); $s.Add(@{Op='imm'; d=1; i=0})
        $s.Add(@{Op='eq'; d=0; s=0; t=1}); $s.Add(@{Op='jump-p'; u=0; Label='bad'})
    }
    # Bounds: 128 <= bytes <= 2^24, bytes % 128 == 0, 1 <= reps <= 64,
    # in length >= 128 + bytes, out length >= 256 + 2 * bytes.
    $s.Add(@{Op='load'; d=5; s=3; Offset=0}); $s.Add(@{Op='load'; d=6; s=5; Offset=0}); $s.Add(@{Op='load'; d=7; s=5; Offset=4})
    $s.Add(@{Op='addi'; d=8; s=6; i=-128}); & $imm 9 (16777216 - 128)
    $s.Add(@{Op='gtu'; d=0; s=8; t=9}); $s.Add(@{Op='jump-p'; u=0; Label='bad'})
    $s.Add(@{Op='imm'; d=9; i=127}); $s.Add(@{Op='and'; d=8; s=6; t=9}); $s.Add(@{Op='imm'; d=9; i=0})
    $s.Add(@{Op='gtu'; d=0; s=8; t=9}); $s.Add(@{Op='jump-p'; u=0; Label='bad'})
    $s.Add(@{Op='addi'; d=8; s=7; i=-1}); $s.Add(@{Op='imm'; d=9; i=63})
    $s.Add(@{Op='gtu'; d=0; s=8; t=9}); $s.Add(@{Op='jump-p'; u=0; Label='bad'})
    $s.Add(@{Op='addi'; d=8; s=6; i=128}); $s.Add(@{Op='load'; d=9; s=3; Offset=4})
    $s.Add(@{Op='gtu'; d=0; s=8; t=9}); $s.Add(@{Op='jump-p'; u=0; Label='bad'})
    $s.Add(@{Op='add'; d=8; s=6; t=6}); $s.Add(@{Op='addi'; d=8; s=8; i=256}); $s.Add(@{Op='load'; d=9; s=3; Offset=12})
    $s.Add(@{Op='gtu'; d=0; s=8; t=9}); $s.Add(@{Op='jump-p'; u=0; Label='bad'})

    # Frame: request @0 (120), attr @128 (160), vtcm ptr @288, size @292, tick @360,
    # descriptors @384..511 (64-aligned slot inside), saved r16..r27 @520..567.
    $s.Add(@{Op='allocframe'; Bytes=576})
    for ($r = 16; $r -le 26; $r += 2) { $s.Add(@{Op='store-d'; s=29; t=$r; Offset=(520 + 4 * ($r - 16))}) }
    $s.Add(@{Op='load'; d=20; s=3; Offset=0}); $s.Add(@{Op='load'; d=21; s=20; Offset=0}); $s.Add(@{Op='load'; d=22; s=20; Offset=4})
    $s.Add(@{Op='addi'; d=20; s=20; i=128})
    $s.Add(@{Op='load'; d=23; s=3; Offset=8})
    $s.Add(@{Op='addi'; d=19; s=29; i=(384 + 63)}); & $imm 15 -64; $s.Add(@{Op='and'; d=19; s=19; t=15})
    $s.Add(@{Op='imm'; d=15; i=0})
    for ($o = 0; $o -lt 256; $o += 4) { $s.Add(@{Op='store'; s=23; t=15; Offset=$o}) }
    & $stage 1

    # Query the default partition: total size lands at frame @292.
    $s.Add(@{Op='imm'; d=0; i=0}); $s.Add(@{Op='addi'; d=1; s=29; i=292}); $s.Add(@{Op='addi'; d=2; s=29; i=128})
    $s.Add(@{Op='addi'; d=3; s=29; i=296}); $s.Add(@{Op='addi'; d=4; s=29; i=200})
    & $call 'compute_resource_query_VTCM'
    & $tele 28 0
    $s.Add(@{Op='load'; d=16; s=29; Offset=292})
    & $stage 2

    $s.Add(@{Op='imm'; d=24; i=0}); $s.Add(@{Op='imm'; d=15; i=0})
    $zeroRequest = { for ($o = 0; $o -lt 120; $o += 4) { $s.Add(@{Op='store'; s=29; t=15; Offset=$o}) } }
    $vote = { param([object[]]$Words)
        & $zeroRequest
        foreach ($w in $Words) { & $imm 13 $w[1]; $s.Add(@{Op='store'; s=29; t=13; Offset=$w[0]}) }
        $s.Add(@{Op='add-pc'; d=0; i=0}); $s.Add(@{Op='addi'; d=1; s=29; i=0})
        & $call 'HAP_power_set'
        $s.Add(@{Op='or'; d=24; s=24; t=0})
        $s.Add(@{Op='imm'; d=15; i=0})
    }
    & $vote @(@(0, 2), @(8, 1))
    & $vote @(@(0, 7), @(8, 0x1000), @(16, 1), @(20, 0x060606))
    & $vote @(@(0, 13), @(8, 1))
    & $tele 4 24
    & $stage 3

    # The partition must hold the tensor.
    $s.Add(@{Op='gtu'; d=0; s=21; t=16}); $s.Add(@{Op='jump-p'; u=0; Label='done'})
    for ($o = 128; $o -lt 288; $o += 4) { $s.Add(@{Op='store'; s=29; t=15; Offset=$o}) }
    $s.Add(@{Op='addi'; d=0; s=29; i=128}); & $call 'compute_resource_attr_init'
    $s.Add(@{Op='addi'; d=0; s=29; i=128}); $s.Add(@{Op='imm'; d=1; i=0}); & $call 'compute_resource_attr_set_app_type'
    $s.Add(@{Op='addi'; d=0; s=29; i=128}); $s.Add(@{Op='addi'; d=1; s=16; i=0}); $s.Add(@{Op='imm'; d=2; i=0}); $s.Add(@{Op='imm'; d=3; i=0})
    & $call 'compute_resource_attr_set_vtcm_param_v2'
    $s.Add(@{Op='addi'; d=0; s=29; i=128}); $s.Add(@{Op='imm'; d=1; i=1}); & $call 'compute_resource_attr_set_hmx_param'
    $s.Add(@{Op='addi'; d=0; s=29; i=128}); & $imm 1 100000; & $call 'compute_resource_acquire'
    $s.Add(@{Op='addi'; d=17; s=0; i=0}); & $tele 8 17
    & $stage 4
    $s.Add(@{Op='imm'; d=15; i=0}); $s.Add(@{Op='eq'; d=0; s=17; t=15}); $s.Add(@{Op='jump-p'; u=0; Label='done'})
    $s.Add(@{Op='store'; s=29; t=15; Offset=288}); $s.Add(@{Op='store'; s=29; t=15; Offset=292})
    $s.Add(@{Op='addi'; d=0; s=29; i=128}); $s.Add(@{Op='addi'; d=1; s=29; i=288}); $s.Add(@{Op='addi'; d=2; s=29; i=292})
    & $call 'compute_resource_attr_get_vtcm_ptr_v2'
    $s.Add(@{Op='load'; d=0; s=29; Offset=292}); & $tele 12 0
    $s.Add(@{Op='load'; d=18; s=29; Offset=288}); $s.Add(@{Op='imm'; d=15; i=0})
    $s.Add(@{Op='eq'; d=0; s=18; t=15}); $s.Add(@{Op='jump-p'; u=0; Label='release'})
    & $stage 5

    # Checked copies. dmaDst (out + 256) is written only by DMA from VTCM.
    # [48]/[52]: ticks of the single checked DMA in / out (fresh data, verified).
    $s.Add(@{Op='hwticks'; d=0}); $s.Add(@{Op='store'; s=29; t=0; Offset=360})
    & $dma 18 20
    # Read immediately after dmwait: both descriptors' done bits and the last copied word.
    $s.Add(@{Op='load'; d=4; s=19; Offset=4}); $s.Add(@{Op='load'; d=5; s=19; Offset=36})
    $s.Add(@{Op='add'; d=6; s=18; t=21}); $s.Add(@{Op='load'; d=6; s=6; Offset=-4}); $s.Add(@{Op='add'; d=7; s=20; t=21}); $s.Add(@{Op='load'; d=7; s=7; Offset=-4})
    $s.Add(@{Op='lsr-i'; d=4; s=4; i=31}); $s.Add(@{Op='lsr-i'; d=5; s=5; i=31}); $s.Add(@{Op='asl-i'; d=4; s=4; i=1}); $s.Add(@{Op='or'; d=4; s=4; t=5}); & $tele 56 4
    $s.Add(@{Op='xor'; d=6; s=6; t=7}); & $tele 60 6
    $s.Add(@{Op='hwticks'; d=2}); $s.Add(@{Op='load'; d=1; s=29; Offset=360}); $s.Add(@{Op='sub'; d=2; s=2; t=1}); & $tele 48 2
    $s.Add(@{Op='addi'; d=4; s=18; i=0}); $s.Add(@{Op='addi'; d=5; s=20; i=0}); $s.Add(@{Op='lsr-i'; d=6; s=21; i=2})
    $s.Add(@{Op='imm'; d=7; i=0}); $s.Add(@{Op='imm'; d=15; i=0})
    $s.Add(@{Op='label'; Name='check'})
    $s.Add(@{Op='load'; d=8; s=4; Offset=0}); $s.Add(@{Op='load'; d=9; s=5; Offset=0})
    $s.Add(@{Op='xor'; d=8; s=8; t=9}); $s.Add(@{Op='or'; d=7; s=7; t=8})
    $s.Add(@{Op='addi'; d=4; s=4; i=4}); $s.Add(@{Op='addi'; d=5; s=5; i=4}); $s.Add(@{Op='addi'; d=6; s=6; i=-1})
    $s.Add(@{Op='gtu'; d=0; s=6; t=15}); $s.Add(@{Op='jump-p'; u=0; Label='check'})
    & $tele 16 7
    $s.Add(@{Op='addi'; d=27; s=23; i=256})
    $s.Add(@{Op='hwticks'; d=0}); $s.Add(@{Op='store'; s=29; t=0; Offset=360})
    & $dma 27 18
    & $tele 24 0
    # Read immediately after dmwait: both descriptors' done bits and the last copied word.
    $s.Add(@{Op='load'; d=4; s=19; Offset=4}); $s.Add(@{Op='load'; d=5; s=19; Offset=36})
    $s.Add(@{Op='add'; d=6; s=27; t=21}); $s.Add(@{Op='load'; d=6; s=6; Offset=-4}); $s.Add(@{Op='add'; d=7; s=18; t=21}); $s.Add(@{Op='load'; d=7; s=7; Offset=-4})
    $s.Add(@{Op='lsr-i'; d=4; s=4; i=31}); $s.Add(@{Op='lsr-i'; d=5; s=5; i=31}); $s.Add(@{Op='asl-i'; d=4; s=4; i=1}); $s.Add(@{Op='or'; d=4; s=4; t=5}); & $tele 64 4
    $s.Add(@{Op='xor'; d=6; s=6; t=7}); & $tele 68 6
    $s.Add(@{Op='hwticks'; d=2}); $s.Add(@{Op='load'; d=1; s=29; Offset=360}); $s.Add(@{Op='sub'; d=2; s=2; t=1}); & $tele 52 2
    & $stage 6

    & $timed 'memcpy_in' 32 { & $copy 18 20 }
    & $timed 'dma_in' 36 { & $dma 18 20 }
    $s.Add(@{Op='add'; d=27; s=27; t=21})
    & $timed 'memcpy_out' 40 { & $copy 27 18 }
    $s.Add(@{Op='addi'; d=27; s=23; i=256})
    & $timed 'dma_out' 44 { & $dma 27 18 }
    & $stage 7

    $s.Add(@{Op='label'; Name='release'})
    $s.Add(@{Op='addi'; d=0; s=17; i=0}); & $call 'compute_resource_release'
    & $tele 20 0

    $s.Add(@{Op='label'; Name='done'})
    for ($r = 16; $r -le 26; $r += 2) { $s.Add(@{Op='load-d'; d=$r; s=29; Offset=(520 + 4 * ($r - 16))}) }
    $s.Add(@{Op='imm'; d=0; i=0})
    $s.Add(@{Op='dealloc-return'})
    $s.ToArray()
}
