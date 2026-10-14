#requires -Version 7.4
# Template-1 correctness gate under the existing checked job/skel wrapper.
# Output: 256 B telemetry, convolution croutons, optional residual croutons,
# each branch's activated operand croutons, then a second FP16 HMX identity convolution.
# The second convolution consumes the epilogue's first operand without any rearrangement.
function New-KokoroGeneratorTemplate1RunSteps {
    param(
        [ValidateSet(128,256)][int] $Channels = 128,
        [ValidateSet(3,7,11)][int] $Kernel = 3,
        [ValidateSet(1,3,5)][int] $Dilation = 1,
        [ValidateRange(1,60)][int] $Tiles = 60,
        [ValidateSet(1,3)][int] $Branches = 1,
        [switch] $AddResidual,
        [switch] $StoreResidual
    )
    . (Join-Path $PSScriptRoot '../kernels/Kokoro.HmxConv.ps1')
    . (Join-Path $PSScriptRoot '../kernels/Kokoro.GeneratorEpilogue.ps1')
    . (Join-Path $PSScriptRoot 'Kokoro.WrappedJob.ps1')
    $blocks = $Channels/32
    $tileBytes = $blocks*2048L
    $activationBytes = ($Tiles+2)*$tileBytes
    $resultBytes = $Tiles*$tileBytes
    $conversionBytes = $blocks*256L
    $epilogueBytes = (128L + $blocks*$Branches*640L + 255L) -band -256L
    $convolutionWeightBytes = 2L*$Channels*$Channels*$Kernel
    $identityWeightBytes = 6L*$Channels*$Channels
    $weightBytes = $convolutionWeightBytes+$identityWeightBytes
    $tableBytes = 2*$conversionBytes+$epilogueBytes
    $inputBytes = $activationBytes + $(if ($AddResidual) { $resultBytes } else { 0L })
    $keepResidual = $StoreResidual -or $AddResidual -or $Branches -eq 3
    $regions = [ordered]@{}
    $cursor = 0L
    $declarations = [Collections.Generic.List[object]]::new()
    $declarations.Add(@('Input',$inputBytes)); $declarations.Add(@('Weights',$weightBytes))
    $declarations.Add(@('Tables',$tableBytes)); $declarations.Add(@('Convolution',$resultBytes))
    if ($keepResidual) { $declarations.Add(@('Residual',$resultBytes)) }
    for ($branch=0; $branch -lt $Branches; $branch++) { $declarations.Add(@("Operand$branch",$activationBytes)) }
    $declarations.Add(@('Consumer',$resultBytes))
    foreach ($declaration in $declarations) {
        $regions[$declaration[0]] = [pscustomobject]@{Offset=$cursor;Bytes=[long]$declaration[1]}
        $cursor += ([long]$declaration[1]+65535L) -band -65536L
    }
    $layout = [pscustomobject]@{PSTypeName='Kokoro.GeneratorTemplate1.Layout';Channels=$Channels;
        Kernel=$Kernel;Dilation=$Dilation;Tiles=$Tiles;Frames=(32*$Tiles);Branches=$Branches;
        AddResidual=[bool]$AddResidual;StoreResidual=[bool]$keepResidual;
        InputBytes=$inputBytes;WeightBytes=$weightBytes;TableBytes=$tableBytes;
        ActivationBytes=$activationBytes;ResultBytes=$resultBytes;TileBytes=$tileBytes;
        ConversionBytes=$conversionBytes;EpilogueBytes=$epilogueBytes;ConvolutionWeightBytes=$convolutionWeightBytes;
        OutputBytes=(256L+$resultBytes*(2+$Branches+[int]$keepResidual));Samples=1;PcmOffset=256;
        VtcmBytes=$cursor;Regions=$regions}
    $job = {
        & $dma 18 $regions.Input.Offset 20 0 $inputBytes
        & $dma 18 $regions.Weights.Offset 21 0 $weightBytes
        & $dma 18 $regions.Tables.Offset 22 0 $tableBytes
        # Initialize linear before/after croutons from the already packed input, then overwrite
        # every live output row in the epilogue. This is initialization, not a layout conversion.
        for ($branch=0; $branch -lt $Branches; $branch++) {
            & $dma 18 $regions["Operand$branch"].Offset 20 0 $activationBytes
        }
        & $ptr 0 18 ($regions.Input.Offset+$tileBytes)
        & $ptr 1 18 $regions.Weights.Offset
        & $ptr 2 18 $regions.Convolution.Offset
        & $ptr 3 18 $regions.Tables.Offset
        & $imm 4 $Tiles
        & $sync
        $s.Add(@{Op='hwticks';d=8}); $s.Add(@{Op='store-d';s=23;t=8;Offset=48})
        & $call 'template1_convolution'
        & $sync
        $s.Add(@{Op='hwticks';d=8}); $s.Add(@{Op='store-d';s=23;t=8;Offset=56})
        & $ptr 0 18 $regions.Convolution.Offset
        if ($AddResidual) { & $ptr 1 18 ($regions.Input.Offset+$activationBytes) }
        if ($keepResidual) { & $ptr 2 18 $regions.Residual.Offset }
        & $ptr 3 18 ($regions.Operand0.Offset+$tileBytes)
        if ($Branches -eq 3) {
            & $ptr 6 18 ($regions.Operand1.Offset+$tileBytes)
            & $ptr 7 18 ($regions.Operand2.Offset+$tileBytes)
        }
        & $ptr 12 18 ($regions.Tables.Offset+$conversionBytes)
        & $imm 13 $Tiles
        & $call 'template1_epilogue'
        & $sync
        & $ptr 0 18 ($regions.Operand0.Offset+$tileBytes)
        & $ptr 1 18 ($regions.Weights.Offset+$convolutionWeightBytes)
        & $ptr 2 18 $regions.Consumer.Offset
        & $ptr 3 18 ($regions.Tables.Offset+$conversionBytes+$epilogueBytes)
        & $imm 4 $Tiles
        & $call 'template1_consumer'
        & $sync
        $outputOffset = 256L
        $outputs = [Collections.Generic.List[string]]::new(); $outputs.Add('Convolution')
        if ($keepResidual) { $outputs.Add('Residual') }
        for ($branch=0; $branch -lt $Branches; $branch++) { $outputs.Add("Operand$branch") }
        $outputs.Add('Consumer')
        foreach ($name in $outputs) {
            $sourceOffset = $regions[$name].Offset
            if ($name.StartsWith('Operand',[StringComparison]::Ordinal)) { $sourceOffset += $tileBytes }
            & $dma 23 $outputOffset 18 $sourceOffset $resultBytes
            $outputOffset += $resultBytes
        }
    }
    $bodies = @(
        @('template1_convolution',@(New-KokoroHmxConvSteps -InputChannels $Channels -OutputChannels $Channels -Kernel $Kernel -Dilation $Dilation -Fp16 -LabelPrefix 'template1_conv')),
        @('template1_epilogue',@(New-KokoroGeneratorEpilogueSteps -Channels $Channels -Branches $Branches -AddResidual:$AddResidual -StoreResidual:$keepResidual)),
        @('template1_consumer',@(New-KokoroHmxConvSteps -InputChannels $Channels -OutputChannels $Channels -Kernel 3 -Dilation 1 -Fp16 -LabelPrefix 'template1_consumer'))
    )
    $steps = New-KokoroWrappedJobSteps -Minimum @(4L,$inputBytes,$weightBytes,$tableBytes,$layout.OutputBytes) -VtcmBytes $cursor -Tiles $Tiles -Job $job -Bodies $bodies
    [pscustomobject]@{Layout=$layout;Steps=$steps}
}
