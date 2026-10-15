#requires -Version 7.4
# Generator register epilogue, design authority Kokoro_Generator_Register_Datapath.md sections 3, 4, 6a.
# Native FP16 croutons throughout: one vector is two time rows interleaved by channel.
# r0 convolution output; r1 residual input; r2 updated residual output;
# r3 first activated operand; r6/r7 second/third activated operands when Branches=3;
# r6 is the third mean input when AddThird is selected with one branch.
# r12 fixed constants; r5 streamed lock blocks for Lock; r13 tile count.
# All pointers are linear VTCM addresses, never :circ HMX operands.
# Constants: [channel block][branch][A, B, K, PHI, Height], each a 128 B float32 vector.
# K = alpha*A/pi*2^24, PHI = alpha*B/pi*2^24, Height = 1/alpha (zero for alpha=0).
# The wrapping phase is folded and shaped in registers. Smoothstep evaluates
# s*s*(3-2*s); Lock folds the supplied seat phase and evaluates its bounded tangent.
# No lookup or waveform table is present.
# Each convolution crouton is loaded once; optional residual and up to three operands are stored
# from that register pass. Arithmetic is unbundled until whole-generator correctness passes.
function New-KokoroGeneratorEpilogueSteps {
    param(
        [ValidateSet(128,256)][int] $Channels = 128,
        [ValidateSet(1,3)][int] $Branches = 1,
        [switch] $AddResidual,
        [switch] $StoreResidual,
        [switch] $AddThird,
        [ValidateRange(0.0,1.0)][double] $LeakySlope = 1.0,
        [ValidateSet('Lock','Smoothstep')][string] $Shape = 'Lock',
        [ValidateRange(16,64)][int] $BlockFrames = 16,
        [ValidateRange(0,63)][int] $InitialFrameOffset = 0,
        [string] $LabelPrefix = 'generator_epilogue'
    )
    $Smoothstep = $Shape -ceq 'Smoothstep'
    $PhaseLock = $Shape -ceq 'Lock'
    if ($InitialFrameOffset -ge $BlockFrames) { throw 'Initial lock frame offset must be inside its block.' }
    if ($AddThird -and (-not $AddResidual -or $Branches -ne 1)) { throw 'The third mean input requires one residual branch.' }
    $positions = if ($Channels -eq 256) { 10 } else { 60 }
    $lockStride = $Channels/32 * ($positions/2 * 1024) * $Branches
    $s = [Collections.Generic.List[hashtable]]::new()
    $splat = {
        param([int]$Vector, [long]$Value)
        $bits = $Value -band 0xffffffffL
        $s.Add(@{Op='lo';x=15;i=($bits -band 65535L)})
        $s.Add(@{Op='hi';x=15;i=($bits -shr 16)})
        $s.Add(@{Op='vsplat';d=$Vector;s=15})
    }
    # Use the existing V73 QFloat arithmetic and materialize FP32 after every operation.
    # This keeps the multiply/add rounding boundaries explicit in the register epilogue.
    $fp32 = {
        param([string]$Operation,[int]$Destination,[int]$Left,[int]$Right)
        $s.Add(@{Op=$Operation;d=$Destination;s=$Left;t=$Right})
        $s.Add(@{Op='vconv-qf32-sf';d=$Destination;s=$Destination})
    }
    $fromHalf = {
        param([int]$Source,[int]$Destination)
        & $splat 3 0x3c003c00L
        $s.Add(@{Op='vmpy-hf-qf32';d=$Destination;s=$Source;t=3})
        $s.Add(@{Op='vconv-qf32-sf';d=$Destination;s=$Destination})
        $s.Add(@{Op='vconv-qf32-sf';d=($Destination+1);s=($Destination+1)})
    }
    $toHalf = {
        param([int]$Source,[int]$Destination)
        & $splat 3 0x3f800000L
        $s.Add(@{Op='vmpy-sf-qf32';d=$Source;s=$Source;t=3})
        $s.Add(@{Op='vmpy-sf-qf32';d=($Source+1);s=($Source+1);t=3})
        $s.Add(@{Op='vconv-qf32-hf';d=$Destination;s=$Source})
    }
    foreach ($constant in @(
        @(30,0x007fffffL),@(29,0x00800000L),@(28,255L),@(27,150L),
        @(26,31L),@(25,-31L),@(24,0x00ffffffL),@(23,0x01000000L),
        @(22,0x4b000000L),@(21,0xcb000000L),
        @(20,[BitConverter]::SingleToInt32Bits([float]($(if ($Smoothstep) { 2.0 } else { [Math]::PI })/16777216.0)))
    )) { & $splat $constant[0] $constant[1] }
    $s.Add(@{Op='imm';d=4;i=0})
    if (-not $PhaseLock) { $s.Add(@{Op='imm';d=5;i=1}) }
    if ($PhaseLock) { $s.Add(@{Op='imm';d=11;i=($InitialFrameOffset*$positions)}) }
    $s.Add(@{Op='label';Name="${LabelPrefix}_tile"})
    for ($block = 0; $block -lt $Channels/32; $block++) {
        if ($PhaseLock) {
            $s.Add(@{Op='addi';d=9;s=11;i=0})
            $s.Add(@{Op='imm';d=10;i=$positions})
            $s.Add(@{Op='label';Name="${LabelPrefix}_b${block}_seat"})
            $s.Add(@{Op='gtu';d=0;s=10;t=9})
            $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_b${block}_seat_ready"})
            $s.Add(@{Op='addi';d=9;s=9;i=(-$positions)})
            $s.Add(@{Op='gtu';d=0;s=5;t=4})
            $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_b${block}_seat"})
            $s.Add(@{Op='label';Name="${LabelPrefix}_b${block}_seat_ready"})
        }
        $s.Add(@{Op='imm';d=14;i=16})
        $s.Add(@{Op='label';Name="${LabelPrefix}_b${block}_pair"})
        $s.Add(@{Op='vload-post';d=2;s=0;i=1})
        & $fromHalf 2 0
        if ($AddResidual) {
            $s.Add(@{Op='vload-post';d=2;s=1;i=1})
            & $fromHalf 2 2
            & $fp32 'vadd-sf-qf32' 0 0 2
            & $fp32 'vadd-sf-qf32' 1 1 3
        }
        if ($AddThird) {
            $s.Add(@{Op='vload-post';d=2;s=6;i=1})
            & $fromHalf 2 2
            & $fp32 'vadd-sf-qf32' 0 0 2
            & $fp32 'vadd-sf-qf32' 1 1 3
        }
        if ($LeakySlope -ne 1.0) {
            & $splat 14 ([BitConverter]::SingleToInt32Bits([float]$LeakySlope))
            & $splat 15 0
            foreach ($row in 0,1) {
                $s.Add(@{Op='vmin-w';d=2;s=$row;t=15})
                $s.Add(@{Op='vmax-w';d=3;s=$row;t=15})
                & $fp32 'vmpy-sf-qf32' 2 2 14
                & $fp32 'vadd-sf-qf32' $row 3 2
            }
        }
        if ($StoreResidual) {
            & $toHalf 0 2
            $s.Add(@{Op='vstore-post';s=2;t=2;i=1})
            & $fromHalf 2 0
        }
        for ($branch = 0; $branch -lt $Branches; $branch++) {
            $offset = ($block*$Branches+$branch)*640
            $s.Add(@{Op='addi';d=8;s=12;i=$offset})
            for ($coefficient = 0; $coefficient -lt 5; $coefficient++) {
                $s.Add(@{Op='vload';d=(14+$coefficient);s=8;Offset=($coefficient*128)})
            }
            # Affine and periodic phase are independently evaluated from the same residual value.
            foreach ($row in 0,1) {
                & $fp32 'vmpy-sf-qf32' (8+$row) $row 14
                & $fp32 'vadd-sf-qf32' (8+$row) (8+$row) 15
                if ($PhaseLock) {
                    $s.Add(@{Op='asl-i';d=8;s=9;i=9})
                    $s.Add(@{Op='add';d=8;s=8;t=5})
                    $lockOffset = ($block*$Branches+$branch)*($positions/2*1024)
                    $s.Add(@{Op='lo';x=15;i=($lockOffset -band 65535)})
                    $s.Add(@{Op='hi';x=15;i=($lockOffset -shr 16)})
                    $s.Add(@{Op='add';d=8;s=8;t=15})
                    if ($InitialFrameOffset) {
                        # A fixed convolution context can begin inside a lock block.
                        # Select the next block for a pair that straddles the tile's epoch.
                        $s.Add(@{Op='imm';d=10;i=16})
                        $s.Add(@{Op='sub';d=10;s=10;t=14})
                        $s.Add(@{Op='asl-i';d=10;s=10;i=1})
                        $s.Add(@{Op='add';d=10;s=10;t=11})
                        $limit = $positions*$BlockFrames
                        $s.Add(@{Op='lo';x=15;i=($limit -band 65535)})
                        $s.Add(@{Op='hi';x=15;i=($limit -shr 16)})
                        $s.Add(@{Op='gtu';d=0;s=15;t=10})
                        $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_b${block}_br${branch}_row${row}_epoch"})
                        $s.Add(@{Op='lo';x=15;i=($lockStride -band 65535)})
                        $s.Add(@{Op='hi';x=15;i=($lockStride -shr 16)})
                        $s.Add(@{Op='add';d=8;s=8;t=15})
                        $s.Add(@{Op='label';Name="${LabelPrefix}_b${block}_br${branch}_row${row}_epoch"})
                    }
                    $s.Add(@{Op='vload';d=16;s=8;Offset=($row*128)})
                    $s.Add(@{Op='vload';d=17;s=8;Offset=(256+$row*128)})
                }
                & $fp32 'vmpy-sf-qf32' (2+$row) $row 16
                & $fp32 'vadd-sf-qf32' (2+$row) (2+$row) 17
            }
            # Convert the phase's IEEE significand/exponent to low integer bits. Clamping the
            # shift to [-31,31] preserves all low 24 bits, including negative phases, without
            # an input-magnitude-dependent range reduction or a sine call.
            foreach ($phase in 2,3) {
                $s.Add(@{Op='imm';d=10;i=31})
                $s.Add(@{Op='vasr-w';d=6;s=$phase;t=10})
                $s.Add(@{Op='imm';d=10;i=23})
                $s.Add(@{Op='vlsr-uw';d=4;s=$phase;t=10})
                $s.Add(@{Op='vand';d=4;s=4;t=28})
                $s.Add(@{Op='vsub-w';d=4;s=27;t=4})
                $s.Add(@{Op='vmax-w';d=4;s=4;t=25})
                $s.Add(@{Op='vmin-w';d=4;s=4;t=26})
                $s.Add(@{Op='vand';d=5;s=$phase;t=30})
                $s.Add(@{Op='vor';d=5;s=5;t=29})
                $s.Add(@{Op='vasr-wv';d=5;s=5;t=4})
                $s.Add(@{Op='vxor';d=5;s=5;t=6})
                $s.Add(@{Op='vsub-w';d=$phase;s=5;t=6})
            }
            & $splat 14 0x3f800000L
            foreach ($row in 0,1) {
                $phase = 2+$row
                $s.Add(@{Op='vand';d=4;s=$phase;t=24})
                $s.Add(@{Op='vsub-w';d=5;s=23;t=4})
                $s.Add(@{Op='vmin-w';d=4;s=4;t=5})
                $s.Add(@{Op='vadd-w';d=4;s=4;t=22})
                & $fp32 'vadd-sf-qf32' 4 4 21
                & $fp32 'vmpy-sf-qf32' 4 4 20
                if ($PhaseLock) {
                    $s.Add(@{Op='vload';d=5;s=8;Offset=(512+$row*128)})
                    $s.Add(@{Op='vload';d=6;s=8;Offset=(768+$row*128)})
                    & $fp32 'vmpy-sf-qf32' $phase 4 6
                    & $fp32 'vadd-sf-qf32' $phase $phase 5
                    # w is nonnegative FP32: integer min/max has the same order.
                    & $splat 5 0
                    & $splat 6 0x3f800000L
                    $s.Add(@{Op='vmax-w';d=$phase;s=$phase;t=5})
                    $s.Add(@{Op='vmin-w';d=$phase;s=$phase;t=6})
                } else {
                    & $fp32 'vmpy-sf-qf32' 5 4 4
                    # Folded s is in [0,1]. Evaluate s*s*(3-2*s) directly.
                    # No waveform lookup or sine evaluation in this build setting.
                    & $splat 6 0xc0000000L
                    & $fp32 'vmpy-sf-qf32' 6 4 6
                    & $splat 14 0x40400000L
                    & $fp32 'vadd-sf-qf32' 6 14 6
                    & $fp32 'vmpy-sf-qf32' $phase 5 6
                }
                & $fp32 'vmpy-sf-qf32' $phase $phase 18
                & $fp32 'vadd-sf-qf32' (8+$row) (8+$row) $phase
            }
            & $toHalf 8 2
            $destination = @(3,6,7)[$branch]
            $s.Add(@{Op='vstore-post';s=$destination;t=2;i=1})
        }
        if ($PhaseLock) {
            $s.Add(@{Op='addi';d=9;s=9;i=2})
            $s.Add(@{Op='imm';d=10;i=$positions})
            $s.Add(@{Op='gtu';d=0;s=10;t=9})
            $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_b${block}_seat_next"})
            $s.Add(@{Op='addi';d=9;s=9;i=(-$positions)})
            $s.Add(@{Op='label';Name="${LabelPrefix}_b${block}_seat_next"})
        }
        $s.Add(@{Op='addi';d=14;s=14;i=-1})
        $s.Add(@{Op='gtu';d=0;s=14;t=4})
        $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_b${block}_pair"})
    }
    if ($PhaseLock) {
        $s.Add(@{Op='addi';d=11;s=11;i=32})
        $s.Add(@{Op='imm';d=10;i=($positions*$BlockFrames)})
        $s.Add(@{Op='gtu';d=0;s=10;t=11})
        $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_lock_block_next"})
        & $splat 15 $lockStride
        $s.Add(@{Op='add';d=5;s=5;t=15})
        $s.Add(@{Op='addi';d=11;s=11;i=(-$positions*$BlockFrames)})
        $s.Add(@{Op='label';Name="${LabelPrefix}_lock_block_next"})
    }
    $s.Add(@{Op='addi';d=13;s=13;i=-1})
    $s.Add(@{Op='gtu';d=0;s=13;t=4})
    $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_tile"})
    $s.Add(@{Op='return'})
    $s.ToArray()
}

# Repack one 32-position tile per transposed-convolution phase into native
# chronological croutons. This is the fixed upsampler handoff, with no float
# arithmetic or utterance-length storage. r0 phases, r1 destination; consumes LC0.
function New-KokoroGeneratorUpsampleInterleaveSteps {
    param(
        [ValidateSet(128,256)][int] $Channels = 256,
        [ValidateSet(6,10)][int] $Stride = 10,
        [ValidateRange(1,5)][int] $PhaseTiles = 1,
        [string] $LabelPrefix = 'generator_ups_interleave'
    )
    if (($Channels -eq 256 -and $Stride -ne 10) -or ($Channels -eq 128 -and $Stride -ne 6)) {
        throw 'Upsampler channels and stride must describe the same generator stage.'
    }
    $tileBytes = 64*$Channels
    $tileShift = if ($Channels -eq 256) { 14 } else { 13 }
    $s = [Collections.Generic.List[hashtable]]::new()
    $s.Add(@{Op='lo';x=15;i=65535}); $s.Add(@{Op='hi';x=15;i=0}); $s.Add(@{Op='vsplat';d=4;s=15})
    $s.Add(@{Op='lo';x=15;i=0}); $s.Add(@{Op='hi';x=15;i=65535}); $s.Add(@{Op='vsplat';d=5;s=15})
    $s.Add(@{Op='imm';d=4;i=0}); $s.Add(@{Op='imm';d=5;i=16})
    $s.Add(@{Op='imm';d=6;i=31}); $s.Add(@{Op='imm';d=7;i=16})
    $s.Add(@{Op='loop0-r';s=5;Label="${LabelPrefix}_pair"})
    $s.Add(@{Op='label';Name="${LabelPrefix}_pair"})
    $storePair = {
        param([int]$Position,[int]$Block)
        $s.Add(@{Op='addi';d=8;s=4;i=$Position})
        $s.Add(@{Op='lsr-i';d=9;s=8;i=5})
        $s.Add(@{Op='asl-i';d=9;s=9;i=$tileShift})
        $s.Add(@{Op='and';d=10;s=8;t=6})
        $s.Add(@{Op='asl-i';d=10;s=10;i=6})
        $s.Add(@{Op='add';d=9;s=9;t=10})
        $s.Add(@{Op='addi';d=9;s=9;i=($Block*2048)})
        $s.Add(@{Op='add';d=8;s=1;t=9})
        $s.Add(@{Op='vstore';s=8;t=2;Offset=0})
    }
    for ($block=0; $block -lt $Channels/32; $block++) {
        for ($phase=0; $phase -lt $Stride; $phase+=2) {
            $sourceOffset=$phase*$PhaseTiles*$tileBytes+$block*2048
            $s.Add(@{Op='lo';x=15;i=($sourceOffset -band 65535)})
            $s.Add(@{Op='hi';x=15;i=($sourceOffset -shr 16)})
            $s.Add(@{Op='add';d=8;s=0;t=15})
            $phaseStride=$PhaseTiles*$tileBytes
            $s.Add(@{Op='lo';x=15;i=($phaseStride -band 65535)})
            $s.Add(@{Op='hi';x=15;i=($phaseStride -shr 16)})
            $s.Add(@{Op='add';d=9;s=8;t=15})
            $s.Add(@{Op='vload';d=0;s=8;Offset=0}); $s.Add(@{Op='vload';d=1;s=9;Offset=0})
            $s.Add(@{Op='vand';d=2;s=0;t=4}); $s.Add(@{Op='vand';d=3;s=1;t=4})
            $s.Add(@{Op='vasl-w';d=3;s=3;t=7}); $s.Add(@{Op='vor';d=2;s=2;t=3})
            & $storePair $phase $block
            $s.Add(@{Op='vlsr-uw';d=2;s=0;t=7}); $s.Add(@{Op='vand';d=3;s=1;t=5})
            $s.Add(@{Op='vor';d=2;s=2;t=3})
            & $storePair ($phase+$Stride) $block
        }
    }
    $s.Add(@{Op='addi';d=0;s=0;i=128})
    $s.Add(@{Op='addi';d=4;s=4;i=(2*$Stride)})
    $s.Add(@{Op='endloop0'}); $s.Add(@{Op='return'})
    $s.ToArray()
}

# Stage B's first chronological column is the reflection-pad value: copy the
# second unpadded sample (column 2 in this shifted phase output) into column 0.
# r0 native output; fixed first-block prologue, not a runtime-length variant.
function New-KokoroGeneratorLeadingReflectionSteps {
    param([ValidateSet(128)][int]$Channels=128)
    $s = [Collections.Generic.List[hashtable]]::new()
    $s.Add(@{Op='lo';x=15;i=65535}); $s.Add(@{Op='hi';x=15;i=0}); $s.Add(@{Op='vsplat';d=2;s=15})
    $s.Add(@{Op='lo';x=15;i=0}); $s.Add(@{Op='hi';x=15;i=65535}); $s.Add(@{Op='vsplat';d=3;s=15})
    for ($block=0; $block -lt $Channels/32; $block++) {
        $s.Add(@{Op='addi';d=8;s=0;i=($block*2048)})
        $s.Add(@{Op='vload';d=0;s=8;Offset=0}); $s.Add(@{Op='vload';d=1;s=8;Offset=128})
        $s.Add(@{Op='vand';d=0;s=0;t=3}); $s.Add(@{Op='vand';d=1;s=1;t=2})
        $s.Add(@{Op='vor';d=0;s=0;t=1}); $s.Add(@{Op='vstore';s=8;t=0;Offset=0})
    }
    $s.ToArray()
}
