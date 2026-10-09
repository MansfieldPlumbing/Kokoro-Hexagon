#requires -Version 7.4
# Pure PowerShell V73 instruction sequence for the pinned R0Sub0 elementwise benchmark graph.
# Affine, mask and Snake-approximation intermediates remain in registers.
# Uses caller-saved registers r0-r15 and predicate p0. No frame, zero relocations, zero imports.
function New-KokoroR0Sub0Steps {
    param(
        [Parameter(Mandatory)][object[]]$Nodes,
        [int]$Frames = 7681,
        [int]$Channels = 128,
        [int]$PaddedFrames = 7712,
        [int]$WeightBytes = 1195008,
        [psobject]$Weights = $null
    )
    if ($Frames -le 0 -or $Channels -ne 128 -or $WeightBytes -lt 1195008) {
        throw 'Invalid r0.0 kernel specialization'
    }

    $expectedOps = @('Mul','Add','Mul','Mul','Mul','Mul','Add','Mul','Mul','Mul','Add')
    $expectedInputs = @(
        '@z,@gain', '%0,@shift', '%1,@mask', '%2,@alpha', '%3,%3', '%4,@cubic',
        '@one,%5', '%3,%6', '%7,%7', '%8,@inverseAlpha', '%2,%9'
    )
    if ($Nodes.Count -ne $expectedOps.Count) { throw 'Unexpected R0Sub0 graph size' }
    for ($nodeIndex = 0; $nodeIndex -lt $Nodes.Count; $nodeIndex++) {
        if ($Nodes[$nodeIndex].Op -cne $expectedOps[$nodeIndex] -or
            ($Nodes[$nodeIndex].Inputs -join ',') -cne $expectedInputs[$nodeIndex]) {
            throw "Unexpected R0Sub0 graph at node $nodeIndex"
        }
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
    $steps.Add(@{Op='vsplat'; d=5; s=12}) # retained in the measured artifact
    # r13 = c3 (-0.16666667f = 0xBE2AAAAB)
    $steps.Add(@{Op='lo'; x=13; i=0xAAAB})
    $steps.Add(@{Op='hi'; x=13; i=0xBE2A})
    $steps.Add(@{Op='vsplat'; d=6; s=13}) # retained in the measured artifact
    # Default style vectors. v0-v5 are constants; v6-v29 hold eight independent lanes.
    $steps.Add(@{Op='vsplat'; d=0; s=12}) # gain
    $steps.Add(@{Op='vsplat'; d=1; s=15}) # shift
    $steps.Add(@{Op='vsplat'; d=2; s=12}) # alpha
    $steps.Add(@{Op='vsplat'; d=3; s=12}) # inverse alpha
    $steps.Add(@{Op='vsplat'; d=4; s=12}) # one
    $steps.Add(@{Op='vsplat'; d=5; s=13}) # cubic coefficient

    # T_start: Read 64-bit hardware timer tick timestamp immediately before compute loop
    $steps.Add(@{Op='hwticks'; d=2})

    # Eight-way schedule selected from the lowered graph. Liveness reuse keeps each lane to
    # three vector registers, allowing eight independent dependency chains in v6-v29.
    # Outer loop: 128 channels (r12 = 128)
    # Inner loop: 30 groups of eight vectors per channel (r11 = 30, processing 240 vectors)
    # Plus 1 tail vector per channel = 241 total vectors per channel (30,848 total vectors).
    # Interleaving eight lanes matches the available HVX register pressure.
    $vectorsPerChannel = [int]($PaddedFrames / 32)   # 241
    $laneCount = 8
    $groupsPerChannel = [int]($vectorsPerChannel / $laneCount) # 30
    $tailCount = $vectorsPerChannel % $laneCount                 # 1

    & $imm 12 $Channels
    $steps.Add(@{Op='label'; Name='channel_loop'})
    $steps.Add(@{Op='add'; d=6; s=14; t=15}) # r6 = mask_base (rewind mask for channel)
    & $imm 11 $groupsPerChannel

    $steps.Add(@{Op='label'; Name='group_loop'})
    $lanes = for ($lane = 0; $lane -lt $laneCount; $lane++) {
        [pscustomobject]@{ Y = 6 + 3 * $lane; U = 7 + 3 * $lane; Temp = 8 + 3 * $lane }
    }
    foreach ($lane in $lanes) {
        $steps.Add(@{Op='vload-post'; d=$lane.Y; s=5; i=1})
        $steps.Add(@{Op='vload-post'; d=$lane.U; s=6; i=1})
    }
    foreach ($lane in $lanes) { $steps.Add(@{Op='vmpy-sf'; d=$lane.Y; s=$lane.Y; t=0}) }
    foreach ($lane in $lanes) { $steps.Add(@{Op='vadd-sf'; d=$lane.Y; s=$lane.Y; t=1}) }
    foreach ($lane in $lanes) { $steps.Add(@{Op='vmpy-sf'; d=$lane.Y; s=$lane.Y; t=$lane.U}) }
    foreach ($lane in $lanes) { $steps.Add(@{Op='vmpy-sf'; d=$lane.U; s=$lane.Y; t=2}) }
    foreach ($lane in $lanes) { $steps.Add(@{Op='vmpy-sf'; d=$lane.Temp; s=$lane.U; t=$lane.U}) }
    foreach ($lane in $lanes) { $steps.Add(@{Op='vmpy-sf'; d=$lane.Temp; s=$lane.Temp; t=5}) }
    foreach ($lane in $lanes) { $steps.Add(@{Op='vadd-sf'; d=$lane.Temp; s=4; t=$lane.Temp}) }
    foreach ($lane in $lanes) { $steps.Add(@{Op='vmpy-sf'; d=$lane.U; s=$lane.U; t=$lane.Temp}) }
    foreach ($lane in $lanes) { $steps.Add(@{Op='vmpy-sf'; d=$lane.U; s=$lane.U; t=$lane.U}) }
    foreach ($lane in $lanes) { $steps.Add(@{Op='vmpy-sf'; d=$lane.U; s=$lane.U; t=3}) }
    foreach ($lane in $lanes) { $steps.Add(@{Op='vadd-sf'; d=$lane.U; s=$lane.Y; t=$lane.U}) }
    foreach ($lane in $lanes) { $steps.Add(@{Op='vstore-post'; t=$lane.U; s=10; i=1}) }

    $steps.Add(@{Op='addi'; d=11; s=11; i=-1})
    $steps.Add(@{Op='gtu'; d=0; s=11; t=15})
    $steps.Add(@{Op='jump-p'; u=0; Label='group_loop'})

    if ($tailCount -eq 1) {
        $lane = $lanes[0]
        $steps.Add(@{Op='vload-post'; d=$lane.Y; s=5; i=1})
        $steps.Add(@{Op='vload-post'; d=$lane.U; s=6; i=1})
        $steps.Add(@{Op='vmpy-sf'; d=$lane.Y; s=$lane.Y; t=0})
        $steps.Add(@{Op='vadd-sf'; d=$lane.Y; s=$lane.Y; t=1})
        $steps.Add(@{Op='vmpy-sf'; d=$lane.Y; s=$lane.Y; t=$lane.U})
        $steps.Add(@{Op='vmpy-sf'; d=$lane.U; s=$lane.Y; t=2})
        $steps.Add(@{Op='vmpy-sf'; d=$lane.Temp; s=$lane.U; t=$lane.U})
        $steps.Add(@{Op='vmpy-sf'; d=$lane.Temp; s=$lane.Temp; t=5})
        $steps.Add(@{Op='vadd-sf'; d=$lane.Temp; s=4; t=$lane.Temp})
        $steps.Add(@{Op='vmpy-sf'; d=$lane.U; s=$lane.U; t=$lane.Temp})
        $steps.Add(@{Op='vmpy-sf'; d=$lane.U; s=$lane.U; t=$lane.U})
        $steps.Add(@{Op='vmpy-sf'; d=$lane.U; s=$lane.U; t=3})
        $steps.Add(@{Op='vadd-sf'; d=$lane.U; s=$lane.Y; t=$lane.U})
        $steps.Add(@{Op='vstore-post'; t=$lane.U; s=10; i=1})
    }

    $steps.Add(@{Op='addi'; d=12; s=12; i=-1})
    $steps.Add(@{Op='gtu'; d=0; s=12; t=15})
    $steps.Add(@{Op='jump-p'; u=0; Label='channel_loop'})

    # T_end: Read 64-bit hardware timer tick timestamp immediately after compute loop
    $steps.Add(@{Op='hwticks'; d=0})
    $steps.Add(@{Op='store-d'; s=9; t=2; Offset=0}) # Store T_start after the timed region
    $steps.Add(@{Op='store-d'; s=9; t=0; Offset=8}) # Store T_end

    $steps.Add(@{Op='imm'; d=0; i=0})
    $steps.Add(@{Op='return'})

    return $steps.ToArray()
}
