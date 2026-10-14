#requires -Version 7.4
# Generator register epilogue, design authority Kokoro_Generator_Register_Datapath.md sections 3, 4, 6a.
# Native FP16 croutons throughout: one vector is two time rows interleaved by channel.
# r0 convolution output; r1 residual input; r2 updated residual output;
# r3 first activated operand; r6/r7 second/third activated operands when Branches=3;
# r12 constants; r13 tile count. All pointers are linear VTCM addresses, never :circ HMX operands.
# Constants: 128 B wave table (32 Q14 values in the low half of each word), followed by
# [channel block][branch][A, B, K, PHI, Height], each coefficient a 128 B float32 vector.
# K = alpha*A/pi*65536, PHI = alpha*B/pi*65536, Height = 1/alpha (zero for alpha=0).
# Each convolution crouton is loaded once; optional residual and up to three operands are stored
# from that register pass. Arithmetic is unbundled until whole-generator correctness passes.
function New-KokoroGeneratorEpilogueSteps {
    param(
        [ValidateSet(128,256)][int] $Channels = 128,
        [ValidateSet(1,3)][int] $Branches = 1,
        [switch] $AddResidual,
        [switch] $StoreResidual,
        [string] $LabelPrefix = 'generator_epilogue'
    )
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
    # V73 HVX PRM Rev AB pp.227-229: control 0/1 matches index bytes 0..15/16..31.
    # The even byte of each native halfword selects into the low half of the table word;
    # vlut16's even destination vector therefore has exactly the original row/channel order.
    $s.Add(@{Op='vload';d=31;s=12;Offset=0})
    foreach ($constant in @(
        @(30,0x007fffffL),@(29,0x00800000L),@(28,255L),@(27,150L),
        @(26,31L),@(25,-31L),@(24,0x001f001fL),@(23,0x07ff07ffL),
        @(22,0x00010001L),@(21,0x4b000000L),@(20,0x38800000L),@(19,0xcb000000L)
    )) { & $splat $constant[0] $constant[1] }
    $s.Add(@{Op='imm';d=4;i=0})
    $s.Add(@{Op='imm';d=5;i=1})
    $s.Add(@{Op='label';Name="${LabelPrefix}_tile"})
    for ($block = 0; $block -lt $Channels/32; $block++) {
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
        if ($StoreResidual) {
            & $toHalf 0 2
            $s.Add(@{Op='vstore-post';s=2;t=2;i=1})
            & $fromHalf 2 0
        }
        for ($branch = 0; $branch -lt $Branches; $branch++) {
            $offset = 128 + ($block*$Branches+$branch)*640
            $s.Add(@{Op='addi';d=8;s=12;i=$offset})
            for ($coefficient = 0; $coefficient -lt 5; $coefficient++) {
                $s.Add(@{Op='vload';d=(14+$coefficient);s=8;Offset=($coefficient*128)})
            }
            # Affine and periodic phase are independently evaluated from the same residual value.
            foreach ($row in 0,1) {
                & $fp32 'vmpy-sf-qf32' (8+$row) $row 14
                & $fp32 'vadd-sf-qf32' (8+$row) (8+$row) 15
                & $fp32 'vmpy-sf-qf32' (2+$row) $row 16
                & $fp32 'vadd-sf-qf32' (2+$row) (2+$row) 17
            }
            # Convert the phase's IEEE significand/exponent to low integer bits. Clamping the
            # shift to [-31,31] preserves all low 16 bits, including negative phases, without
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
            $s.Add(@{Op='vshuffe-h';d=2;s=3;t=2})
            $s.Add(@{Op='imm';d=10;i=11})
            $s.Add(@{Op='vlsr-uw';d=4;s=2;t=10})
            $s.Add(@{Op='vand';d=4;s=4;t=24})
            $s.Add(@{Op='vadd-h';d=5;s=4;t=22})
            $s.Add(@{Op='vand';d=5;s=5;t=24})
            $s.Add(@{Op='vand';d=6;s=2;t=23})
            $s.Add(@{Op='imm';d=10;i=4})
            $s.Add(@{Op='vasl-h';d=6;s=6;t=10})
            $s.Add(@{Op='vlut16';d=10;s=4;v=31;x=4})
            $s.Add(@{Op='vlut16-or';d=10;s=4;v=31;x=5})
            $s.Add(@{Op='vlut16';d=12;s=5;v=31;x=4})
            $s.Add(@{Op='vlut16-or';d=12;s=5;v=31;x=5})
            $s.Add(@{Op='vsub-h';d=12;s=12;t=10})
            $s.Add(@{Op='vmpy-h-rnd-sat';d=12;s=12;t=6})
            $s.Add(@{Op='vadd-h';d=10;s=10;t=12})
            # Exact Q14 integer -> FP32 conversion through the 2^23 mantissa offset.
            # This keeps the interpolation in registers and avoids another FP16 rounding.
            $s.Add(@{Op='imm';d=10;i=16})
            $s.Add(@{Op='vlsr-uw';d=11;s=10;t=10})
            $s.Add(@{Op='vasl-w';d=10;s=10;t=10})
            $s.Add(@{Op='vlsr-uw';d=10;s=10;t=10})
            foreach ($row in 0,1) {
                $s.Add(@{Op='vadd-w';d=(10+$row);s=(10+$row);t=21})
                & $fp32 'vadd-sf-qf32' (10+$row) (10+$row) 19
            }
            foreach ($row in 0,1) {
                & $fp32 'vmpy-sf-qf32' (10+$row) (10+$row) 20
                & $fp32 'vmpy-sf-qf32' (10+$row) (10+$row) 18
                & $fp32 'vadd-sf-qf32' (8+$row) (8+$row) (10+$row)
            }
            & $toHalf 8 2
            $destination = @(3,6,7)[$branch]
            $s.Add(@{Op='vstore-post';s=$destination;t=2;i=1})
        }
        $s.Add(@{Op='addi';d=14;s=14;i=-1})
        $s.Add(@{Op='gtu';d=0;s=14;t=4})
        $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_b${block}_pair"})
    }
    $s.Add(@{Op='addi';d=13;s=13;i=-1})
    $s.Add(@{Op='gtu';d=0;s=13;t=4})
    $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_tile"})
    $s.Add(@{Op='return'})
    $s.ToArray()
}
