#requires -Version 7.4
# Fixed upsampler stamp: phase convolutions, then the native crouton handoff.
# Both phase and interleave loops use hardware loop 1; their callees use loop 0.
# No source branch, decoder, normalization statistics or runtime lengths.
function New-KokoroGeneratorUpsampleRunSteps {
    param([ValidateSet(128,256)][int]$Channels=256)
    . (Join-Path $PSScriptRoot '../kernels/Kokoro.HmxConv.ps1')
    . (Join-Path $PSScriptRoot '../kernels/Kokoro.GeneratorEpilogue.ps1')
    . (Join-Path $PSScriptRoot 'Kokoro.WrappedJob.ps1')
    $stage = if ($Channels -eq 256) { 0 } else { 1 }
    $inputChannels = 2*$Channels
    $stride = if ($stage -eq 0) { 10 } else { 6 }
    $phaseTiles = if ($stage -eq 0) { 1 } else { 5 }
    $tileBytes = 64L*$Channels
    $inputTileBytes = 64L*$inputChannels
    $inputBytes = ($phaseTiles+2)*$inputTileBytes
    $phaseBytes = $phaseTiles*$tileBytes
    $resultBytes = $stride*$phaseBytes
    $phaseWeightBytes = 6L*$inputChannels*$Channels
    $weightBytes = $stride*$phaseWeightBytes
    $tableBytes = 8L*$Channels
    $regions = [ordered]@{}
    $cursor = 0L
    foreach ($declaration in @(@('Input',$inputBytes),@('Weights',$phaseWeightBytes),@('Tables',$tableBytes),
        @('Phases',$resultBytes),@('Output',$resultBytes))) {
        $regions[$declaration[0]] = [pscustomobject]@{Offset=$cursor;Bytes=[long]$declaration[1]}
        $cursor += ($declaration[1]+65535L) -band -65536L
    }
    if ($inputBytes -gt 1048576L) { throw 'Upsampler input exceeds one HMX activation region.' }
    $layout = [pscustomobject]@{PSTypeName='Kokoro.GeneratorUpsample.Layout';Stage=$stage;Channels=$Channels;
        InputChannels=$inputChannels;Stride=$stride;PhaseTiles=$phaseTiles;InputFrames=(32*$phaseTiles);
        Frames=(32*$phaseTiles*$stride);Tiles=$phaseTiles;InputBytes=$inputBytes;InputTileBytes=$inputTileBytes;
        TileBytes=$tileBytes;WeightBytes=$weightBytes;PhaseWeightBytes=$phaseWeightBytes;TableBytes=$tableBytes;
        PhaseBytes=$phaseBytes;ResultBytes=$resultBytes;OutputBytes=(256L+2*$resultBytes);LeadingReflection=($stage -eq 1);
        Samples=1;PcmOffset=256;VtcmBytes=$cursor;Regions=$regions}
    $job = {
        & $dma 18 $regions.Input.Offset 20 0 $inputBytes
        & $dma 18 $regions.Tables.Offset 22 0 $tableBytes
        & $ptr 16 18 $regions.Phases.Offset
        & $imm 19 0
        & $imm 25 0
        & $imm 5 $stride
        $s.Add(@{Op='loop1-r';s=5;Label='ups_phase'})
        $s.Add(@{Op='label';Name='ups_phase'})
        & $dma 18 $regions.Weights.Offset 21 0 $phaseWeightBytes
        & $ptr 0 18 ($regions.Input.Offset+$inputTileBytes)
        & $ptr 1 18 $regions.Weights.Offset
        $s.Add(@{Op='addi';d=2;s=16;i=0})
        & $ptr 3 18 $regions.Tables.Offset
        & $imm 4 $phaseTiles
        $s.Add(@{Op='asl-i';d=17;s=19;i=4})
        $s.Add(@{Op='addi';d=17;s=17;i=96})
        $s.Add(@{Op='add';d=17;s=23;t=17})
        $s.Add(@{Op='hwticks';d=8}); $s.Add(@{Op='store-d';s=17;t=8;Offset=0})
        & $call 'ups_convolution'
        & $sync
        $s.Add(@{Op='hwticks';d=8}); $s.Add(@{Op='store-d';s=17;t=8;Offset=8})
        $s.Add(@{Op='load-d';d=10;s=17;Offset=0})
        $s.Add(@{Op='sub-d';d=8;s=8;t=10})
        $s.Add(@{Op='add';d=25;s=25;t=8})
        $s.Add(@{Op='addi';d=19;s=19;i=1})
        & $imm 15 $phaseWeightBytes
        $s.Add(@{Op='add';d=21;s=21;t=15})
        & $imm 15 $phaseBytes
        $s.Add(@{Op='add';d=16;s=16;t=15})
        $s.Add(@{Op='endloop1'})
        & $imm 8 0
        $s.Add(@{Op='store';s=23;t=8;Offset=48}); $s.Add(@{Op='store';s=23;t=8;Offset=52})
        $s.Add(@{Op='store';s=23;t=25;Offset=56}); $s.Add(@{Op='store';s=23;t=8;Offset=60})
        & $ptr 16 18 $regions.Phases.Offset
        & $ptr 17 18 $regions.Output.Offset
        & $imm 5 $phaseTiles
        $s.Add(@{Op='hwticks';d=8}); $s.Add(@{Op='store-d';s=23;t=8;Offset=64})
        $s.Add(@{Op='loop1-r';s=5;Label='ups_handoff'})
        $s.Add(@{Op='label';Name='ups_handoff'})
        $s.Add(@{Op='addi';d=0;s=16;i=0})
        $s.Add(@{Op='addi';d=1;s=17;i=0})
        & $call 'ups_interleave'
        & $imm 15 $tileBytes
        $s.Add(@{Op='add';d=16;s=16;t=15})
        & $imm 15 ($stride*$tileBytes)
        $s.Add(@{Op='add';d=17;s=17;t=15})
        $s.Add(@{Op='endloop1'})
        if ($stage -eq 1) {
            & $ptr 0 18 $regions.Output.Offset
            foreach ($step in @(New-KokoroGeneratorLeadingReflectionSteps)) { $s.Add($step) }
        }
        $s.Add(@{Op='hwticks';d=8}); $s.Add(@{Op='store-d';s=23;t=8;Offset=72})
        & $dma 23 256 18 $regions.Phases.Offset $resultBytes
        & $dma 23 (256+$resultBytes) 18 $regions.Output.Offset $resultBytes
    }
    $bodies = @(
        @('ups_convolution',@(New-KokoroHmxConvSteps -InputChannels $inputChannels -OutputChannels $Channels -Kernel 3 -Dilation 1 -Fp16 -LabelPrefix 'ups_conv')),
        @('ups_interleave',@(New-KokoroGeneratorUpsampleInterleaveSteps -Channels $Channels -Stride $stride -PhaseTiles $phaseTiles))
    )
    $steps = New-KokoroWrappedJobSteps -Minimum @(4L,$inputBytes,$weightBytes,$tableBytes,$layout.OutputBytes) -VtcmBytes $cursor -Tiles $phaseTiles -Job $job -Bodies $bodies
    [pscustomobject]@{Layout=$layout;Steps=$steps}
}
