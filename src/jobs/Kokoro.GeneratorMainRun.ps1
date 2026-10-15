#requires -Version 7.4
# Fixed first-block connection of both main stages. All handoffs stay in VTCM.
# Temporary integration wrapper: the tail will consume MeanB directly, and the
# frame loop will carry the admitted convolution history between blocks.
# No source synthesis, decoder, random generator or normalization statistics.
function New-KokoroGeneratorMainRunSteps {
    param([ValidateSet(16)][int]$BlockFrames=16)
    . (Join-Path $PSScriptRoot '../kernels/Kokoro.HmxConv.ps1')
    . (Join-Path $PSScriptRoot '../kernels/Kokoro.GeneratorEpilogue.ps1')
    . (Join-Path $PSScriptRoot 'Kokoro.WrappedJob.ps1')
    $stages=@(
        [pscustomobject]@{Index=0;Channels=256;Stride=10;Positions=10;RootRows=448;FinalRows=256;PhaseTiles=2;UpsTiles=2;Mean='MeanA'},
        [pscustomobject]@{Index=1;Channels=128;Stride=6;Positions=60;RootRows=1216;FinalRows=1024;PhaseTiles=7;UpsTiles=7;Mean='MeanB'}
    )
    $regions=[ordered]@{};$cursor=0L
    foreach($declaration in @(@('Decoder',131072L),@('Operand',319488L),@('MeanA',147456L),
        @('Root',311296L),@('Residual',311296L),@('Convolution',311296L),
        @('Branch0',262144L),@('Branch1',262144L),@('Branch2',262144L),
        @('MeanB',262144L),@('Phases',344064L),@('UpsOutput',344064L),
        @('Weights',1441792L),@('Conversion',2048L),@('Norm',249344L),@('Source',311296L))){
        $name=[string]$declaration[0];$bytes=[long]$declaration[1]
        if($name -in 'Decoder','Operand','MeanA' -and $cursor%1048576L+$bytes -gt 1048576L){$cursor=($cursor+1048575L) -band -1048576L}
        $regions[$name]=[pscustomobject]@{Offset=$cursor;Bytes=$bytes}
        $cursor+=($bytes+65535L) -band -65536L
    }
    if($cursor -gt 8388608L){throw 'Connected first-block working set exceeds the admitted SM8550 grant.'}
    $weightAt=0L;$tableAt=0L;$inputAt=131072L
    $layers=[Collections.Generic.List[object]]::new()
    foreach($stage in $stages){
        $c=$stage.Channels;$tileBytes=64L*$c
        $phaseBytes=$stage.PhaseTiles*$tileBytes
        $upsWeights=[Collections.Generic.List[long]]::new()
        for($phase=0;$phase -lt $stage.Stride;$phase++){$upsWeights.Add($weightAt);$weightAt+=12L*$c*$c}
        $stage | Add-Member -NotePropertyMembers @{TileBytes=$tileBytes;PhaseBytes=$phaseBytes;
            UpsWeights=$upsWeights.ToArray();UpsConversion=$tableAt;SourceOffset=$inputAt;SourceBytes=($stage.RootRows*2L*$c)}
        $tableAt+=8L*$c;$inputAt+=$stage.SourceBytes
        for($branch=0;$branch -lt 3;$branch++){
            $k=3+4*$branch;$block=3*$stage.Index+$branch
            for($layer=0;$layer -lt 6;$layer++){
                $normBlocks=[int][Math]::Ceiling($stage.RootRows/[double]($BlockFrames*$stage.Positions))
                $normBytes=20L*$c+$normBlocks*($c/32)*($stage.Positions/2)*1024L
                $record=[pscustomobject]@{Index=$layers.Count;Stage=$stage.Index;Block=$block;Branch=$branch;
                    Layer=$layer;Kernel=$k;Dilation=$(if($layer%2){1}else{1+2*[int][Math]::Floor($layer/2)});
                    InputRows=($stage.RootRows-32*$layer);OutputRows=($stage.RootRows-32*($layer+1));
                    WeightOffset=$weightAt;WeightBytes=(2L*$c*$c*$k);ConversionOffset=$tableAt;
                    NormOffset=($tableAt+8L*$c);NormBytes=$normBytes;
                    NormName="generator.resblocks.$block.adain$(1+$layer%2).$([int][Math]::Floor($layer/2))"}
                $layers.Add($record);$weightAt+=$record.WeightBytes;$tableAt+=8L*$c+$normBytes
            }
        }
    }
    $layout=[pscustomobject]@{PSTypeName='Kokoro.GeneratorMain.Layout';BlockFrames=$BlockFrames;Shape='Lock';
        FirstBlock=$true;Stages=$stages;Layers=$layers.ToArray();Regions=$regions;VtcmBytes=$cursor;
        InputBytes=$inputAt;WeightBytes=$weightAt;TableBytes=$tableAt;OutputBytes=(1024L+262144L);
        Samples=1;PcmOffset=1024;MeanOffset=1024;MeanRows=1024;Tiles=30}
    $job={
        & $imm 8 0x314e4547L
        $s.Add(@{Op='store';s=23;t=8;Offset=80})
        & $dma 18 $regions.Decoder.Offset 20 0 131072
        foreach($stage in $stages){
            $c=$stage.Channels;$tileBytes=$stage.TileBytes
            $upsInput=if($stage.Index -eq 0){$regions.Decoder.Offset+32768L}else{$regions.MeanA.Offset+$tileBytes*2}
            & $dma 18 $regions.Conversion.Offset 22 $stage.UpsConversion (8L*$c)
            # Phase calls are in program order; LC0 belongs to each convolution.
            # LC1 remains available for the final frame loop.
            for($phase=0;$phase -lt $stage.Stride;$phase++){
                & $dma 18 $regions.Weights.Offset 21 $stage.UpsWeights[$phase] (12L*$c*$c)
                & $ptr 0 18 $upsInput;& $ptr 1 18 $regions.Weights.Offset
                & $ptr 2 18 ($regions.Phases.Offset+$phase*$stage.PhaseBytes)
                & $ptr 3 18 $regions.Conversion.Offset;& $imm 4 $stage.UpsTiles
                & $call "main_ups_$($stage.Index)";& $sync
            }
            for($tile=0;$tile -lt $stage.PhaseTiles;$tile++){
                & $ptr 0 18 ($regions.Phases.Offset+$tile*$tileBytes)
                & $ptr 1 18 ($regions.UpsOutput.Offset+$tile*$stage.Stride*$tileBytes)
                & $call "main_interleave_$($stage.Index)"
            }
            if($stage.Index -eq 1){
                & $ptr 0 18 $regions.UpsOutput.Offset
                foreach($step in @(New-KokoroGeneratorLeadingReflectionSteps)){$s.Add($step)}
            }
            & $dma 18 $regions.Source.Offset 20 $stage.SourceOffset $stage.SourceBytes
            & $ptr 0 18 $regions.UpsOutput.Offset;& $ptr 1 18 $regions.Source.Offset
            & $ptr 2 18 $regions.Root.Offset;& $imm 13 ($stage.RootRows/32)
            & $call "main_add_$($stage.Index)"
            foreach($branch in 0,1,2){
                & $dma 18 $regions.Residual.Offset 18 $regions.Root.Offset $stage.SourceBytes
                $branchLayers=@($layers | Where-Object {$_.Stage -eq $stage.Index -and $_.Branch -eq $branch})
                $first=$branchLayers[0]
                & $dma 18 $regions.Norm.Offset 22 $first.NormOffset $first.NormBytes
                & $ptr 0 18 $regions.Operand.Offset;& $imm 4 ($tileBytes/128);& $call 'main_zero'
                & $ptr 0 18 $regions.Residual.Offset;& $ptr 3 18 ($regions.Operand.Offset+$tileBytes)
                & $ptr 12 18 $regions.Norm.Offset;& $ptr 5 18 ($regions.Norm.Offset+20L*$c)
                & $imm 13 ($stage.RootRows/32);& $call "main_norm_$($stage.Index)"
                foreach($layer in $branchLayers){
                    & $dma 18 $regions.Weights.Offset 21 $layer.WeightOffset $layer.WeightBytes
                    & $dma 18 $regions.Conversion.Offset 22 $layer.ConversionOffset (8L*$c)
                    & $ptr 0 18 ($regions.Operand.Offset+$tileBytes);& $ptr 1 18 $regions.Weights.Offset
                    & $ptr 2 18 $regions.Convolution.Offset;& $ptr 3 18 $regions.Conversion.Offset
                    & $imm 4 ($layer.OutputRows/32)
                    $clockOffset=96+16*$layer.Index
                    $s.Add(@{Op='hwticks';d=8});$s.Add(@{Op='store-d';s=23;t=8;Offset=$clockOffset})
                    & $call "main_c${c}_k$($layer.Kernel)_d$($layer.Dilation)";& $sync
                    $s.Add(@{Op='hwticks';d=8});$s.Add(@{Op='store-d';s=23;t=8;Offset=($clockOffset+8)})
                    if($layer.Layer -eq 5){
                        & $ptr 0 18 $regions.Convolution.Offset;& $ptr 1 18 $regions.Residual.Offset
                        & $ptr 2 18 $regions["Branch$branch"].Offset;& $imm 13 ($stage.FinalRows/32)
                        & $call "main_add_$($stage.Index)"
                    }else{
                        $next=$branchLayers[$layer.Layer+1]
                        & $dma 18 $regions.Norm.Offset 22 $next.NormOffset $next.NormBytes
                        & $ptr 0 18 $regions.Operand.Offset;& $imm 4 ($tileBytes/128);& $call 'main_zero'
                        & $ptr 0 18 $regions.Convolution.Offset;& $ptr 1 18 $regions.Residual.Offset
                        & $ptr 2 18 $regions.Residual.Offset;& $ptr 3 18 ($regions.Operand.Offset+$tileBytes)
                        & $ptr 12 18 $regions.Norm.Offset;& $ptr 5 18 ($regions.Norm.Offset+20L*$c)
                        & $imm 13 ($layer.OutputRows/32)
                        & $call $(if($layer.Layer%2){"main_resnorm_$($stage.Index)"}else{"main_norm_$($stage.Index)"})
                    }
                }
            }
            & $ptr 0 18 $regions.Branch0.Offset;& $ptr 1 18 $regions.Branch1.Offset;& $ptr 6 18 $regions.Branch2.Offset
            $meanOffset=if($stage.Index -eq 0){$regions.MeanA.Offset+$tileBytes}else{$regions.MeanB.Offset}
            & $ptr 2 18 $meanOffset;& $imm 13 ($stage.FinalRows/32)
            & $call "main_mean_$($stage.Index)"
            if($stage.Index -eq 0){& $ptr 0 18 $regions.MeanA.Offset;& $imm 4 ($tileBytes/128);& $call 'main_zero'}
        }
        & $dma 23 1024 18 $regions.MeanB.Offset 262144
    }
    $bodies=[Collections.Generic.List[object]]::new()
    $zero=@(@{Op='vxor';d=0;s=0;t=0},@{Op='loop0-r';s=4;Label='main_zero_loop'},
        @{Op='label';Name='main_zero_loop'},@{Op='vstore-post';s=0;t=0;i=1},@{Op='endloop0'},@{Op='return'})
    $bodies.Add(@('main_zero',$zero))
    foreach($stage in $stages){
        $c=$stage.Channels;$id=$stage.Index
        $bodies.Add(@("main_ups_$id",@(New-KokoroHmxConvSteps -InputChannels (2*$c) -OutputChannels $c -Kernel 3 -Dilation 1 -Fp16 -LabelPrefix "main_ups_$id")))
        $bodies.Add(@("main_interleave_$id",@(New-KokoroGeneratorUpsampleInterleaveSteps -Channels $c -Stride $stage.Stride -PhaseTiles $stage.PhaseTiles -LabelPrefix "main_interleave_$id")))
        foreach($k in 3,7,11){foreach($d in 1,3,5){
            $label="main_c${c}_k${k}_d$d"
            $bodies.Add(@($label,@(New-KokoroHmxConvSteps -InputChannels $c -OutputChannels $c -Kernel $k -Dilation $d -Fp16 -LabelPrefix $label)))
        }}
        foreach($kind in 'norm','resnorm','add','mean'){
            $settings=@{Channels=$c;Shape='Lock';BlockFrames=$BlockFrames;LabelPrefix="main_${kind}_$id"}
            if($kind -in 'resnorm','add','mean'){$settings.AddResidual=$true;$settings.StoreResidual=$true}
            if($kind -in 'add','mean'){$settings.ResidualOnly=$true}
            if($kind -eq 'mean'){$settings.AddThird=$true;$settings.ResidualScale=1.0/3;$settings.LeakySlope=$(if($id -eq 0){0.1}else{0.01})}
            $bodies.Add(@("main_${kind}_$id",@(New-KokoroGeneratorEpilogueSteps @settings)))
        }
    }
    $steps=New-KokoroWrappedJobSteps -Minimum @(4L,$inputAt,$weightAt,$tableAt,$layout.OutputBytes) -VtcmBytes $cursor -Tiles 30 -Job $job -Bodies $bodies.ToArray()
    [pscustomobject]@{Layout=$layout;Steps=$steps}
}
