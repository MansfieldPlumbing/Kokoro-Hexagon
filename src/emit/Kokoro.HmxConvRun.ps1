#requires -Version 7.4
# FastRPC skel entry that runs one emitted HMX conv (Kokoro.HmxConv.ps1) on the cDSP with its own
# HMX power vote, VTCM and HMX context; no other DSP library of ours is loaded.
# Struct layouts from SDK 6.4.0.2 headers (tools/reference/hmx-sim/power_layout.c):
#   HAP_power_request_t 120 B: type @0 (HVX=2, DCVS_v2=7, HMX=13); hvx/hmx.power_up @8 (u8);
#   dcvs_v2: dcvs_enable @8, dcvs_option @9 (PERFORMANCE_MODE=16), set_dcvs_params @16,
#   target/min/max corner @20/21/22 (TURBO=6).  compute_res_attr_t 160 B.
# Sequence follows onnxsim hmx_runtime.h (refs/pr/1961 0dd9980a): HVX power, DCVS, HMX power,
# compute_resource acquire (VTCM + HMX), qurt_hvx_lock(128B) + compute_resource_hmx_lock.
#
# Method 2, sc 0x02040100 (4 in, 1 out):
#   in0 config { u32 tiles } (must equal the baked tile count), in1 activations incl. halo tiles,
#   in2 weights, in3 column tables; out0 = 64 B telemetry + output croutons.
# Telemetry: [0] u64 ticks before conv, [8] u64 ticks after, [16] power rc (OR of three),
#   [20] context id, [24] VTCM bytes granted, [28] hvx lock rc, [32] hmx lock rc, [36] stage reached.
function New-KokoroHmxConvRunSteps {
    param(
        [ValidateSet(128, 256)][int] $Channels = 128,
        [ValidateSet(3, 7, 11)][int] $Kernel = 3,
        [ValidateSet(1, 3, 5)][int] $Dilation = 1,
        [ValidateRange(1, 64)][int] $Tiles = 8
    )
    . (Join-Path $PSScriptRoot 'Kokoro.HmxConv.ps1')
    $cb = $Channels / 32; $groups = $Channels / 64
    $pad = 1
    $actBytes = ($Tiles + 2 * $pad) * $cb * 2048
    $wBytes = $groups * $Kernel * $cb * 2048
    $tblBytes = $cb * 256
    $outBytes = $Tiles * $cb * 2048
    $align = { param([long]$v) [long]([math]::Ceiling($v / 65536) * 65536) }
    $actOff = 0; $wOff = & $align $actBytes; $tblOff = $wOff + (& $align $wBytes); $outOff = $tblOff + 65536
    $vtcmBytes = & $align ($outOff + $outBytes)

    $s = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int]$r, [long]$v) $u = [uint32]($v -band 0xFFFFFFFF); $s.Add(@{Op='lo'; x=$r; i=($u -band 65535)}); $s.Add(@{Op='hi'; x=$r; i=($u -shr 16)}) }
    $tele = { param([int]$Offset, [int]$Reg) $s.Add(@{Op='store'; s=23; t=$Reg; Offset=$Offset}) }
    $stage = { param([int]$Value) $s.Add(@{Op='imm'; d=13; i=$Value}); & $tele 36 13 }
    $call = { param([string]$Name) $s.Add(@{Op='got-call'; Import=$Name; d=14}) }

    # Dispatch: open, close, run (same handle protocol as the other emitted skels).
    foreach ($d in @(@(0x00020001, 'open'), @(0x01000010, 'success'), @(0x02040100, 'run'))) {
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
    # Admit every buffer by exact minimum length before any pointer is used.
    $minimum = @(4, $actBytes, $wBytes, $tblBytes, (64 + $outBytes))
    for ($a = 0; $a -lt 5; $a++) {
        $s.Add(@{Op='load'; d=0; s=3; Offset=(8 * $a + 4)}); & $imm 1 ($minimum[$a] - 1)
        $s.Add(@{Op='gtu'; d=0; s=0; t=1}); $s.Add(@{Op='jump-p'; u=0; Label="len_$a"})
        $s.Add(@{Op='imm'; d=0; i=14}); $s.Add(@{Op='return'}); $s.Add(@{Op='label'; Name="len_$a"})
        $s.Add(@{Op='load'; d=0; s=3; Offset=(8 * $a)}); $s.Add(@{Op='imm'; d=1; i=0})
        $s.Add(@{Op='eq'; d=0; s=0; t=1}); $s.Add(@{Op='jump-p'; u=0; Label='bad'})
    }
    $s.Add(@{Op='load'; d=0; s=3; Offset=0}); $s.Add(@{Op='load'; d=0; s=0; Offset=0})
    $s.Add(@{Op='imm'; d=1; i=$Tiles}); $s.Add(@{Op='eq'; d=0; s=0; t=1}); $s.Add(@{Op='jump-p'; u=0; Label='admitted'})
    $s.Add(@{Op='imm'; d=0; i=14}); $s.Add(@{Op='return'})
    $s.Add(@{Op='label'; Name='admitted'})

    # Frame: request @0 (120), attr @128 (160), vtcm ptr @288, size @292, saved r16..r27 @296..343.
    $s.Add(@{Op='allocframe'; Bytes=352})
    for ($r = 16; $r -le 26; $r += 2) { $s.Add(@{Op='store-d'; s=29; t=$r; Offset=(296 + 4 * ($r - 16))}) }
    foreach ($p in @(@(20, 8), @(21, 16), @(22, 24), @(23, 32))) { $s.Add(@{Op='load'; d=$p[0]; s=3; Offset=$p[1]}) }
    $s.Add(@{Op='imm'; d=24; i=0})                                              # OR of power return codes
    $s.Add(@{Op='imm'; d=15; i=0})
    for ($o = 0; $o -lt 64; $o += 4) { $s.Add(@{Op='store'; s=23; t=15; Offset=$o}) }
    & $stage 1

    # Power votes. The client context is this code's own address: stable for the process.
    $zeroRequest = { for ($o = 0; $o -lt 120; $o += 4) { $s.Add(@{Op='store'; s=29; t=15; Offset=$o}) } }
    $vote = { param([object[]]$Words)
        & $zeroRequest
        foreach ($w in $Words) { & $imm 13 $w[1]; $s.Add(@{Op='store'; s=29; t=13; Offset=$w[0]}) }
        $s.Add(@{Op='add-pc'; d=0; i=0}); $s.Add(@{Op='addi'; d=1; s=29; i=0})
        & $call 'HAP_power_set'
        $s.Add(@{Op='or'; d=24; s=24; t=0})
    }
    & $vote @(@(0, 2), @(8, 1))                                                  # HVX power up
    & $vote @(@(0, 7), @(8, 0x1000), @(16, 1), @(20, 0x060606))                  # DCVS v2 performance, turbo
    & $vote @(@(0, 13), @(8, 1))                                                 # HMX power up
    & $tele 16 24
    & $stage 2

    # VTCM + HMX context.
    for ($o = 128; $o -lt 296; $o += 4) { $s.Add(@{Op='store'; s=29; t=15; Offset=$o}) }
    $s.Add(@{Op='addi'; d=0; s=29; i=128}); & $call 'compute_resource_attr_init'
    $s.Add(@{Op='addi'; d=0; s=29; i=128}); & $imm 1 $vtcmBytes; $s.Add(@{Op='imm'; d=2; i=0}); $s.Add(@{Op='imm'; d=3; i=0})
    & $call 'compute_resource_attr_set_vtcm_param_v2'
    $s.Add(@{Op='addi'; d=0; s=29; i=128}); $s.Add(@{Op='imm'; d=1; i=1}); & $call 'compute_resource_attr_set_hmx_param'
    $s.Add(@{Op='addi'; d=0; s=29; i=128}); & $imm 1 100000; & $call 'compute_resource_acquire'
    $s.Add(@{Op='addi'; d=17; s=0; i=0}); & $tele 20 17
    $s.Add(@{Op='imm'; d=15; i=0}); $s.Add(@{Op='eq'; d=0; s=17; t=15}); $s.Add(@{Op='jump-p'; u=0; Label='no_context'})
    $s.Add(@{Op='addi'; d=0; s=29; i=128}); $s.Add(@{Op='addi'; d=1; s=29; i=288}); $s.Add(@{Op='addi'; d=2; s=29; i=292})
    & $call 'compute_resource_attr_get_vtcm_ptr_v2'
    $s.Add(@{Op='load'; d=18; s=29; Offset=288}); $s.Add(@{Op='load'; d=19; s=29; Offset=292}); & $tele 24 19
    $s.Add(@{Op='imm'; d=15; i=0}); $s.Add(@{Op='eq'; d=0; s=18; t=15}); $s.Add(@{Op='jump-p'; u=0; Label='release'})
    & $imm 15 ($vtcmBytes - 1); $s.Add(@{Op='gtu'; d=0; s=19; t=15}); $s.Add(@{Op='jump-p'; u=0; Label='vtcm_ok'})
    $s.Add(@{Op='eq'; d=0; s=15; t=15}); $s.Add(@{Op='jump-p'; u=0; Label='release'})
    $s.Add(@{Op='label'; Name='vtcm_ok'})
    & $stage 3

    # Stage inputs into VTCM.
    foreach ($c in @(@($actOff, 20, $actBytes), @($wOff, 21, $wBytes), @($tblOff, 22, $tblBytes))) {
        & $imm 0 $c[0]; $s.Add(@{Op='add'; d=0; s=18; t=0}); $s.Add(@{Op='addi'; d=1; s=$c[1]; i=0}); & $imm 2 $c[2]
        & $call 'memcpy'
    }
    & $stage 4

    # Lock HVX then HMX on this thread.
    $s.Add(@{Op='imm'; d=0; i=1}); & $call 'qurt_hvx_lock'; & $tele 28 0
    $s.Add(@{Op='addi'; d=0; s=17; i=0}); & $call 'compute_resource_hmx_lock'; & $tele 32 0
    $s.Add(@{Op='imm'; d=15; i=0}); $s.Add(@{Op='eq'; d=0; s=0; t=15}); $s.Add(@{Op='jump-p'; u=0; Label='locked'})
    $s.Add(@{Op='eq'; d=0; s=15; t=15}); $s.Add(@{Op='jump-p'; u=0; Label='unlock_hvx'})
    $s.Add(@{Op='label'; Name='locked'})
    & $stage 5

    # The conv, bracketed by the 19.2 MHz hardware tick counter.
    $s.Add(@{Op='hwticks'; d=26})
    & $imm 0 ($actOff + $pad * $cb * 2048); $s.Add(@{Op='add'; d=0; s=18; t=0})
    & $imm 1 $wOff; $s.Add(@{Op='add'; d=1; s=18; t=1})
    & $imm 2 $outOff; $s.Add(@{Op='add'; d=2; s=18; t=2})
    & $imm 3 $tblOff; $s.Add(@{Op='add'; d=3; s=18; t=3})
    $s.Add(@{Op='imm'; d=4; i=$Tiles})
    foreach ($step in (New-KokoroHmxConvSteps -InputChannels $Channels -OutputChannels $Channels -Kernel $Kernel -Dilation $Dilation -LabelPrefix 'conv' -NoReturn)) { $s.Add($step) }
    # Completion before the closing tick: read back the last output word, then syncht.
    & $imm 5 ($outOff + $outBytes - 4); $s.Add(@{Op='add'; d=5; s=18; t=5}); $s.Add(@{Op='load'; d=5; s=5; Offset=0})
    $s.Add(@{Op='syncht'})
    $s.Add(@{Op='hwticks'; d=0})
    $s.Add(@{Op='store-d'; s=23; t=26; Offset=0}); $s.Add(@{Op='store-d'; s=23; t=0; Offset=8})
    & $stage 6

    $s.Add(@{Op='addi'; d=0; s=17; i=0}); & $call 'compute_resource_hmx_unlock'
    $s.Add(@{Op='label'; Name='unlock_hvx'})
    & $call 'qurt_hvx_unlock'
    # Return the output croutons after the telemetry block.
    $s.Add(@{Op='addi'; d=0; s=23; i=64}); & $imm 1 $outOff; $s.Add(@{Op='add'; d=1; s=18; t=1}); & $imm 2 $outBytes
    & $call 'memcpy'
    & $stage 7
    $s.Add(@{Op='label'; Name='release'})
    $s.Add(@{Op='addi'; d=0; s=17; i=0}); & $call 'compute_resource_release'
    $s.Add(@{Op='label'; Name='no_context'})
    for ($r = 16; $r -le 26; $r += 2) { $s.Add(@{Op='load-d'; d=$r; s=29; Offset=(296 + 4 * ($r - 16))}) }
    $s.Add(@{Op='imm'; d=0; i=0})
    $s.Add(@{Op='dealloc-return'})
    [pscustomobject]@{
        Steps = $s.ToArray()
        Layout = [pscustomobject]@{ Tiles=$Tiles; Pad=$pad; ActBytes=$actBytes; WeightBytes=$wBytes; TableBytes=$tblBytes; OutputBytes=$outBytes; VtcmBytes=$vtcmBytes }
    }
}
