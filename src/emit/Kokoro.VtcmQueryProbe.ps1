#requires -Version 7.4
# FastRPC skel that reports the VTCM this process can use: the partition the query API reports,
# then an acquire of that whole partition with HMX, as the generator runner will acquire it.
# Layouts from SDK 6.4.0.2 incs/HAP_compute_res.h:
#   compute_resource_query_VTCM(application_id, *total_block_size, *total_block_layout,
#                               *avail_block_size, *avail_block_layout)
#   compute_res_vtcm_page_t 72 B: block_size @0, page_list_len @4, page_list[8] of
#   { page_size, num_pages } @8.  Application ID 0 selects the default partition.
# Power votes and the acquire sequence are those of Kokoro.HmxConvRun.ps1.
#
# Method 2, sc 0x02010100 (1 in, 1 out): in0 { u32 application_id }, out0 >= 256 B.
#   [0] query rc, [4] total bytes, [8..79] total layout, [80] available bytes, [84..155] available layout,
#   [160] power rc (OR of three), [164] context id, [168] granted bytes, [172] granted pointer nonzero,
#   [176] release rc, [180] stage reached, [184] application id, [188] set_app_type rc.
function New-KokoroVtcmQuerySteps {
    $s = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int]$r, [long]$v) $u = [uint32]($v -band 0xFFFFFFFF); $s.Add(@{Op='lo'; x=$r; i=($u -band 65535)}); $s.Add(@{Op='hi'; x=$r; i=($u -shr 16)}) }
    $tele = { param([int]$Offset, [int]$Reg) $s.Add(@{Op='store'; s=23; t=$Reg; Offset=$Offset}) }
    $stage = { param([int]$Value) $s.Add(@{Op='imm'; d=13; i=$Value}); & $tele 180 13 }
    $call = { param([string]$Name) $s.Add(@{Op='got-call'; Import=$Name; d=14}) }

    foreach ($d in @(@(0x00020001, 'open'), @(0x01000010, 'success'), @(0x02010100, 'run'))) {
        & $imm 4 $d[0]; $s.Add(@{Op='eq'; d=0; s=2; t=4}); $s.Add(@{Op='jump-p'; u=0; Label=$d[1]})
    }
    $s.Add(@{Op='imm'; d=0; i=20}); $s.Add(@{Op='return'})                     # AEE_EUNSUPPORTED
    $s.Add(@{Op='label'; Name='open'}); $s.Add(@{Op='imm'; d=4; i=0})
    $s.Add(@{Op='eq'; d=0; s=3; t=4}); $s.Add(@{Op='jump-p'; u=0; Label='bad'})
    $s.Add(@{Op='imm'; d=4; i=1}); $s.Add(@{Op='store'; s=3; t=4; Offset=16})
    $s.Add(@{Op='imm'; d=4; i=0}); $s.Add(@{Op='store'; s=3; t=4; Offset=20})
    $s.Add(@{Op='label'; Name='success'}); $s.Add(@{Op='imm'; d=0; i=0}); $s.Add(@{Op='return'})
    $s.Add(@{Op='label'; Name='bad'}); $s.Add(@{Op='imm'; d=0; i=14}); $s.Add(@{Op='return'})   # AEE_EBADPARM

    $s.Add(@{Op='label'; Name='run'})
    $s.Add(@{Op='imm'; d=4; i=0}); $s.Add(@{Op='eq'; d=0; s=3; t=4}); $s.Add(@{Op='jump-p'; u=0; Label='bad'})
    # Admit both buffers by exact minimum length and pointer before use.
    $minimum = @(4, 256)
    for ($a = 0; $a -lt 2; $a++) {
        $s.Add(@{Op='load'; d=0; s=3; Offset=(8 * $a + 4)}); & $imm 1 ($minimum[$a] - 1)
        $s.Add(@{Op='gtu'; d=0; s=0; t=1}); $s.Add(@{Op='jump-p'; u=0; Label="len_$a"})
        $s.Add(@{Op='imm'; d=0; i=14}); $s.Add(@{Op='return'}); $s.Add(@{Op='label'; Name="len_$a"})
        $s.Add(@{Op='load'; d=0; s=3; Offset=(8 * $a)}); $s.Add(@{Op='imm'; d=1; i=0})
        $s.Add(@{Op='eq'; d=0; s=0; t=1}); $s.Add(@{Op='jump-p'; u=0; Label='bad'})
    }

    # Frame: request @0 (120), attr @128 (160), vtcm ptr @288, size @292, saved r16..r27 @296..343.
    $s.Add(@{Op='allocframe'; Bytes=352})
    for ($r = 16; $r -le 26; $r += 2) { $s.Add(@{Op='store-d'; s=29; t=$r; Offset=(296 + 4 * ($r - 16))}) }
    $s.Add(@{Op='load'; d=20; s=3; Offset=0}); $s.Add(@{Op='load'; d=20; s=20; Offset=0})
    $s.Add(@{Op='load'; d=23; s=3; Offset=8})
    $s.Add(@{Op='imm'; d=15; i=0})
    for ($o = 0; $o -lt 256; $o += 4) { $s.Add(@{Op='store'; s=23; t=15; Offset=$o}) }
    & $tele 184 20
    & $stage 1

    # Partition query; the layouts are written straight into the output buffer.
    $s.Add(@{Op='addi'; d=0; s=20; i=0})
    $s.Add(@{Op='addi'; d=1; s=23; i=4}); $s.Add(@{Op='addi'; d=2; s=23; i=8})
    $s.Add(@{Op='addi'; d=3; s=23; i=80}); $s.Add(@{Op='addi'; d=4; s=23; i=84})
    & $call 'compute_resource_query_VTCM'
    & $tele 0 0
    & $stage 2

    # Power votes. The client context is this code's own address: stable for the process.
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
    & $vote @(@(0, 2), @(8, 1))                                                  # HVX power up
    & $vote @(@(0, 7), @(8, 0x1000), @(16, 1), @(20, 0x060606))                  # DCVS v2 performance, turbo
    & $vote @(@(0, 13), @(8, 1))                                                 # HMX power up
    & $tele 160 24
    & $stage 3

    # Acquire the whole reported partition with HMX, record what was granted, release.
    $s.Add(@{Op='load'; d=16; s=23; Offset=4})
    $s.Add(@{Op='eq'; d=0; s=16; t=15}); $s.Add(@{Op='jump-p'; u=0; Label='done'})
    for ($o = 128; $o -lt 296; $o += 4) { $s.Add(@{Op='store'; s=29; t=15; Offset=$o}) }
    $s.Add(@{Op='addi'; d=0; s=29; i=128}); & $call 'compute_resource_attr_init'
    $s.Add(@{Op='addi'; d=0; s=29; i=128}); $s.Add(@{Op='addi'; d=1; s=20; i=0}); & $call 'compute_resource_attr_set_app_type'
    & $tele 188 0
    $s.Add(@{Op='addi'; d=0; s=29; i=128}); $s.Add(@{Op='addi'; d=1; s=16; i=0}); $s.Add(@{Op='imm'; d=2; i=0}); $s.Add(@{Op='imm'; d=3; i=0})
    & $call 'compute_resource_attr_set_vtcm_param_v2'
    $s.Add(@{Op='addi'; d=0; s=29; i=128}); $s.Add(@{Op='imm'; d=1; i=1}); & $call 'compute_resource_attr_set_hmx_param'
    $s.Add(@{Op='addi'; d=0; s=29; i=128}); & $imm 1 100000; & $call 'compute_resource_acquire'
    $s.Add(@{Op='addi'; d=17; s=0; i=0}); & $tele 164 17
    & $stage 4
    $s.Add(@{Op='imm'; d=15; i=0}); $s.Add(@{Op='eq'; d=0; s=17; t=15}); $s.Add(@{Op='jump-p'; u=0; Label='done'})
    $s.Add(@{Op='store'; s=29; t=15; Offset=288}); $s.Add(@{Op='store'; s=29; t=15; Offset=292})
    $s.Add(@{Op='addi'; d=0; s=29; i=128}); $s.Add(@{Op='addi'; d=1; s=29; i=288}); $s.Add(@{Op='addi'; d=2; s=29; i=292})
    & $call 'compute_resource_attr_get_vtcm_ptr_v2'
    $s.Add(@{Op='load'; d=19; s=29; Offset=292}); & $tele 168 19
    $s.Add(@{Op='load'; d=18; s=29; Offset=288}); $s.Add(@{Op='imm'; d=15; i=0}); $s.Add(@{Op='imm'; d=13; i=0})
    $s.Add(@{Op='eq'; d=0; s=18; t=15}); $s.Add(@{Op='jump-p'; u=0; Label='null_ptr'})
    $s.Add(@{Op='imm'; d=13; i=1})
    $s.Add(@{Op='label'; Name='null_ptr'}); & $tele 172 13
    $s.Add(@{Op='addi'; d=0; s=17; i=0}); & $call 'compute_resource_release'
    & $tele 176 0
    & $stage 5

    $s.Add(@{Op='label'; Name='done'})
    for ($r = 16; $r -le 26; $r += 2) { $s.Add(@{Op='load-d'; d=$r; s=29; Offset=(296 + 4 * ($r - 16))}) }
    $s.Add(@{Op='imm'; d=0; i=0})
    $s.Add(@{Op='dealloc-return'})
    $s.ToArray()
}
