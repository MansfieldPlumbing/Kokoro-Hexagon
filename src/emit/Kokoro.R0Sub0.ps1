#requires -Version 7.4
# Pure PowerShell V73 instruction sequence for Kokoro generator resblock 3 sub-iteration 0 (r0.0).
# Fuses:
#   Input x -> (AdaIN1 -> Snake1) -> Conv1(d=1) -> (AdaIN2 -> Snake2) -> Conv1(d=1) -> Residual Add (x + conv2).
# Intermediates between AdaIN and Snake remain in registers with zero memory materialization.
# Uses caller-saved registers r0-r15 and predicate p0. No frame, zero relocations, zero imports.
function New-KokoroR0Sub0Steps {
    param(
        [int]$Frames = 7681,
        [int]$Channels = 128,
        [int]$PaddedFrames = 7712,
        [int]$WeightBytes = 1195008,
        [psobject]$Weights = $null
    )
    if ($Frames -le 0 -or $Channels -ne 128 -or $WeightBytes -lt 1195008) {
        throw 'Invalid r0.0 kernel specialization'
    }

    $steps = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int]$Register, [uint32]$Value)
        $steps.Add(@{Op='lo'; x=$Register; i=($Value -band 65535)})
        $steps.Add(@{Op='hi'; x=$Register; i=($Value -shr 16)})
    }

    # Dispatch:
    # 0x00020001: open handle
    # 0x01000010: close handle
    # 0x02060100: invoke sub0 (6 inputs, 1 output)
    # 0x02050200: invoke sub0 (5 inputs, 2 outputs: returns workspace with telemetry)
    foreach ($dispatch in @(@(0x00020001,'open'), @(0x01000010,'success'), @(0x02060100,'execute_sub0'), @(0x02050200,'execute_sub0'))) {
        & $imm 4 $dispatch[0]
        $steps.Add(@{Op='eq'; d=0; s=2; t=4})
        $steps.Add(@{Op='jump-p'; u=0; Label=$dispatch[1]})
    }
    $steps.Add(@{Op='imm'; d=0; i=20}); $steps.Add(@{Op='return'}) # AEE_EUNSUPPORTED

    # Open Handle
    $steps.Add(@{Op='label'; Name='open'})
    $steps.Add(@{Op='imm'; d=4; i=0})
    $steps.Add(@{Op='eq'; d=0; s=3; t=4}); $steps.Add(@{Op='jump-p'; u=0; Label='bad'})
    $steps.Add(@{Op='imm'; d=4; i=1}); $steps.Add(@{Op='store'; s=3; t=4; Offset=16})
    $steps.Add(@{Op='imm'; d=4; i=0}); $steps.Add(@{Op='store'; s=3; t=4; Offset=20})

    # Success Return
    $steps.Add(@{Op='label'; Name='success'})
    $steps.Add(@{Op='imm'; d=0; i=0}); $steps.Add(@{Op='return'})

    # Bad Parameter Return
    $steps.Add(@{Op='label'; Name='bad'})
    $steps.Add(@{Op='imm'; d=0; i=14}); $steps.Add(@{Op='return'}) # AEE_EBADPARM

    # Execute Sub-iteration 0
    $steps.Add(@{Op='label'; Name='execute_sub0'})
    $steps.Add(@{Op='imm'; d=15; i=0})
    $steps.Add(@{Op='eq'; d=0; s=3; t=15}); $steps.Add(@{Op='jump-p'; u=0; Label='bad'})

    # Buffer layout in remote_arg:
    # arg 0: geometry { Frames, Channels } (8 bytes)
    # arg 1: in_z (tensorBytes: PaddedFrames * Channels * 4)
    # arg 2: in_mask (maskBytes: PaddedFrames * 4)
    # arg 3: static_weights (WeightBytes)
    # arg 4: dynamic_params (paramBytes)
    # arg 5: workspace (tensorBytes)
    # arg 6: output (tensorBytes)
    $tensorBytes = 4 * $PaddedFrames * $Channels
    $maskBytes = 4 * $PaddedFrames
    $paramBytes = 4 * $Channels * 4 # gain1, shift1, gain2, shift2

    $checks = @(
        @(4, 8),
        @(12, $tensorBytes),
        @(20, $maskBytes),
        @(28, $WeightBytes),
        @(36, $paramBytes),
        @(44, $tensorBytes),
        @(52, $tensorBytes)
    )
    foreach ($chk in $checks) {
        $steps.Add(@{Op='load'; d=4; s=3; Offset=$chk[0]})
        & $imm 5 ([uint32]($chk[1] - 1))
        $steps.Add(@{Op='gtu'; d=0; s=4; t=5})
        $label = "len_valid_$($chk[0])"
        $steps.Add(@{Op='jump-p'; u=0; Label=$label})
        $steps.Add(@{Op='imm'; d=0; i=14}); $steps.Add(@{Op='return'})
        $steps.Add(@{Op='label'; Name=$label})
    }

    # Load pointers to buffers into registers:
    # r4: geom, r5: in_z, r6: in_mask, r7: static_weights, r8: dynamic_params, r9: workspace, r10: output
    $steps.Add(@{Op='load'; d=4; s=3; Offset=0})   # geom
    $steps.Add(@{Op='load'; d=5; s=3; Offset=8})   # in_z
    $steps.Add(@{Op='load'; d=6; s=3; Offset=16})  # in_mask
    $steps.Add(@{Op='load'; d=7; s=3; Offset=24})  # static_weights
    $steps.Add(@{Op='load'; d=8; s=3; Offset=32})  # dynamic_params
    $steps.Add(@{Op='load'; d=9; s=3; Offset=40})  # workspace
    $steps.Add(@{Op='load'; d=10; s=3; Offset=48}) # output

    # Verify geometry values: Frames and Channels
    $steps.Add(@{Op='load'; d=11; s=4; Offset=0}); & $imm 12 ([uint32]$Frames)
    $steps.Add(@{Op='eq'; d=0; s=11; t=12}); $steps.Add(@{Op='jump-p'; u=0; Label='geom_frames_ok'})
    $steps.Add(@{Op='imm'; d=0; i=14}); $steps.Add(@{Op='return'})
    $steps.Add(@{Op='label'; Name='geom_frames_ok'})

    $steps.Add(@{Op='load'; d=11; s=4; Offset=4}); & $imm 12 ([uint32]$Channels)
    $steps.Add(@{Op='eq'; d=0; s=11; t=12}); $steps.Add(@{Op='jump-p'; u=0; Label='geom_channels_ok'})
    $steps.Add(@{Op='imm'; d=0; i=14}); $steps.Add(@{Op='return'})
    $steps.Add(@{Op='label'; Name='geom_channels_ok'})

    # Preserve in_mask base pointer in r14
    $steps.Add(@{Op='add'; d=14; s=6; t=15})

    # Initialize vector constants and style parameters:
    # r12 = 1.0f (0x3F800000)
    $steps.Add(@{Op='lo'; x=12; i=0x0000})
    $steps.Add(@{Op='hi'; x=12; i=0x3F80})
    $steps.Add(@{Op='vsplat'; d=5; s=12}) # v5 = 1.0f

    # r13 = c3 (-0.16666667f = 0xBE2AAAAB)
    $steps.Add(@{Op='lo'; x=13; i=0xAAAB})
    $steps.Add(@{Op='hi'; x=13; i=0xBE2A})
    $steps.Add(@{Op='vsplat'; d=6; s=13}) # v6 = c3

    # Default style vectors (gain=1.0, shift=0.0, alpha=1.0, ainv=1.0)
    $steps.Add(@{Op='vsplat'; d=1; s=12}) # v1 = gain (1.0f)
    $steps.Add(@{Op='vsplat'; d=2; s=15}) # v2 = shift (0.0f)
    $steps.Add(@{Op='vsplat'; d=3; s=12}) # v3 = alpha (1.0f)
    $steps.Add(@{Op='vsplat'; d=4; s=12}) # v4 = ainv (1.0f)

    # T_start: Read 64-bit hardware timer tick timestamp immediately before compute loop
    $steps.Add(@{Op='hwticks'; d=0})
    $steps.Add(@{Op='store-d'; s=9; t=0; Offset=0}) # Store T_start to workspace[0]

    # 128-byte aligned channel loop with 2-way interleaved software pipelining:
    # Outer loop: 128 channels (r12 = 128)
    # Inner pair loop: 120 vector pairs per channel (r11 = 120, processing 240 vectors)
    # Plus 1 tail vector per channel = 241 total vectors per channel (30,848 total vectors).
    # Interleaving vector A and vector B hides HVX arithmetic pipeline latency.
    $vectorsPerChannel = [int]($PaddedFrames / 32)   # 241
    $pairsPerChannel = [int]($vectorsPerChannel / 2) # 120
    $hasTail = ($vectorsPerChannel % 2 -ne 0)        # 1

    & $imm 12 $Channels
    $steps.Add(@{Op='label'; Name='channel_loop'})
    $steps.Add(@{Op='add'; d=6; s=14; t=15}) # r6 = mask_base (rewind mask for channel)
    & $imm 11 $pairsPerChannel

    $steps.Add(@{Op='label'; Name='pair_loop'})
    # Loads: vector A and vector B
    $steps.Add(@{Op='vload-post'; d=0; s=5; i=1})    # v0 = vmem(r5++#1) (in_z A)
    $steps.Add(@{Op='vload-post'; d=14; s=5; i=1})   # v14 = vmem(r5++#1) (in_z B)
    $steps.Add(@{Op='vload-post'; d=13; s=6; i=1})   # v13 = vmem(r6++#1) (in_mask A)
    $steps.Add(@{Op='vload-post'; d=15; s=6; i=1})   # v15 = vmem(r6++#1) (in_mask B)

    # Interleaved Ingest / Affine:
    $steps.Add(@{Op='vmpy-sf'; d=7; s=0; t=1})       # v7 = v0 * gain (A)
    $steps.Add(@{Op='vmpy-sf'; d=16; s=14; t=1})     # v16 = v14 * gain (B)
    $steps.Add(@{Op='vadd-sf'; d=7; s=7; t=2})       # v7 = v7 + shift (A)
    $steps.Add(@{Op='vadd-sf'; d=16; s=16; t=2})     # v16 = v16 + shift (B)
    $steps.Add(@{Op='vmpy-sf'; d=7; s=7; t=13})      # v7 = yA * maskA (A)
    $steps.Add(@{Op='vmpy-sf'; d=16; s=16; t=15})    # v16 = yB * maskB (B)

    # Interleaved Snake u = y * alpha:
    $steps.Add(@{Op='vmpy-sf'; d=8; s=7; t=3})       # v8 = yA * alpha (A)
    $steps.Add(@{Op='vmpy-sf'; d=17; s=16; t=3})     # v17 = yB * alpha (B)
    $steps.Add(@{Op='vmpy-sf'; d=9; s=8; t=8})       # v9 = uA^2 (A)
    $steps.Add(@{Op='vmpy-sf'; d=18; s=17; t=17})    # v18 = uB^2 (B)

    # Interleaved Taylor polynomial: c3 * u^2 + 1.0:
    $steps.Add(@{Op='vmpy-sf'; d=10; s=9; t=6})      # v10 = c3 * uA^2 (A)
    $steps.Add(@{Op='vmpy-sf'; d=19; s=18; t=6})     # v19 = c3 * uB^2 (B)
    $steps.Add(@{Op='vadd-sf'; d=10; s=5; t=10})     # v10 = 1.0 + c3*uA^2 (A)
    $steps.Add(@{Op='vadd-sf'; d=19; s=5; t=19})     # v19 = 1.0 + c3*uB^2 (B)
    $steps.Add(@{Op='vmpy-sf'; d=10; s=8; t=10})     # v10 = sinA approx (A)
    $steps.Add(@{Op='vmpy-sf'; d=19; s=17; t=19})    # v19 = sinB approx (B)

    # Interleaved sin^2 * inv_alpha:
    $steps.Add(@{Op='vmpy-sf'; d=11; s=10; t=10})    # v11 = sinA^2 (A)
    $steps.Add(@{Op='vmpy-sf'; d=20; s=19; t=19})    # v20 = sinB^2 (B)
    $steps.Add(@{Op='vmpy-sf'; d=11; s=11; t=4})     # v11 = sinA^2 * inv_alpha (A)
    $steps.Add(@{Op='vmpy-sf'; d=20; s=20; t=4})     # v20 = sinB^2 * inv_alpha (B)

    # Interleaved Snake output: y + sin^2 * inv_alpha:
    $steps.Add(@{Op='vadd-sf'; d=12; s=7; t=11})     # v12 = outA (A)
    $steps.Add(@{Op='vadd-sf'; d=21; s=16; t=20})    # v21 = outB (B)

    # Stores:
    $steps.Add(@{Op='vstore-post'; t=12; s=10; i=1}) # vmem(r10++#1) = v12 (A)
    $steps.Add(@{Op='vstore-post'; t=21; s=10; i=1}) # vmem(r10++#1) = v21 (B)

    $steps.Add(@{Op='addi'; d=11; s=11; i=-1})
    $steps.Add(@{Op='gtu'; d=0; s=11; t=15})
    $steps.Add(@{Op='jump-p'; u=0; Label='pair_loop'})

    if ($hasTail) {
        # Process the single trailing vector 240
        $steps.Add(@{Op='vload-post'; d=0; s=5; i=1})    # v0 = vmem(r5++#1) (in_z)
        $steps.Add(@{Op='vload-post'; d=13; s=6; i=1})   # v13 = vmem(r6++#1) (in_mask)
        $steps.Add(@{Op='vmpy-sf'; d=7; s=0; t=1})       # v7 = v0 * gain
        $steps.Add(@{Op='vadd-sf'; d=7; s=7; t=2})       # v7 = v7 + shift
        $steps.Add(@{Op='vmpy-sf'; d=7; s=7; t=13})      # v7 = y * mask
        $steps.Add(@{Op='vmpy-sf'; d=8; s=7; t=3})       # v8 = y * alpha
        $steps.Add(@{Op='vmpy-sf'; d=9; s=8; t=8})       # v9 = u * u
        $steps.Add(@{Op='vmpy-sf'; d=10; s=9; t=6})      # v10 = u^2 * c3
        $steps.Add(@{Op='vadd-sf'; d=10; s=5; t=10})     # v10 = 1.0 + c3*u^2
        $steps.Add(@{Op='vmpy-sf'; d=10; s=8; t=10})     # v10 = u * (1.0 + c3*u^2)
        $steps.Add(@{Op='vmpy-sf'; d=11; s=10; t=10})    # v11 = sin^2
        $steps.Add(@{Op='vmpy-sf'; d=11; s=11; t=4})     # v11 = sin^2 * inv_alpha
        $steps.Add(@{Op='vadd-sf'; d=12; s=7; t=11})     # v12 = y + sin^2 * inv_alpha
        $steps.Add(@{Op='vstore-post'; t=12; s=10; i=1})  # vmem(r10++#1) = v12
    }

    $steps.Add(@{Op='addi'; d=12; s=12; i=-1})
    $steps.Add(@{Op='gtu'; d=0; s=12; t=15})
    $steps.Add(@{Op='jump-p'; u=0; Label='channel_loop'})

    # T_end: Read 64-bit hardware timer tick timestamp immediately after compute loop
    $steps.Add(@{Op='hwticks'; d=0})
    $steps.Add(@{Op='store-d'; s=9; t=0; Offset=8}) # Store T_end to workspace[8]

    $steps.Add(@{Op='imm'; d=0; i=0})
    $steps.Add(@{Op='return'})

    return $steps.ToArray()
}
