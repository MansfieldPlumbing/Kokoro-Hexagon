#requires -Version 7.4
# Stock generator resblocks.3/4/5 and their three-way mean with the activations resident
# in VTCM. Source: hexgrad/kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec, istftnet.py
# AdaINResBlock1.forward and Generator.forward. Design: docs/generator60x-resident-design.md.
#
# Same method-2 contract and output layout as Kokoro.Generator60xRun.ps1, so the frozen
# fixture, simulator runner and device harness apply unchanged. DDR is touched only by
# user DMA (descriptors in DDR, the job's own frame): the stage input in, per-stage weights
# and parameter records in, branch 0/1 outputs out and back, the final tensor and the
# coefficients out. Every HVX pass runs on VTCM.
#
# Per branch (kernel 3, 7, 11), per dilation pair (1, 3, 5):
#   first half:  coefficients from R moments; per batch fused AdaIN+Snake R -> window,
#                HMX conv window -> C; epilogue: moments of C.
#   second half: coefficients from C moments; per batch fused AdaIN+Snake C -> window,
#                HMX conv window -> O; epilogue: residual R += O, moments of the new R.
# Rows past the frame count follow the frozen worker exactly: zero for moments, zero point
# 128 at the conv input, and the residual skip keeps its unmasked padded rows (saved tile S).
function Get-KokoroGenerator60xResidentLayout {
    param([ValidateRange(2,32768)][int]$Frames=7801,[ValidateRange(1,64)][int]$BatchTiles=16,[ValidateSet(2048,65536)][int]$RegionAlign=65536)
    $tiles=[int][math]::Ceiling($Frames/32); $bytes=$tiles*8192
    $al={param([long]$v) [long]([math]::Ceiling($v/$RegionAlign)*$RegionAlign)}
    $small=[ordered]@{Parameters=0;Moments=8192;InputMoments=9216;MeanParameters=10240;SavedTile=16384;Coefficients=24576}
    $smallBytes=24576+18432
    $regions=[ordered]@{}
    $at=0L
    # HMX activation reads span a crouton and the next tile; in the V73 simulator a read that
    # straddles a 4 MiB VTCM boundary faults (exception 0x26), while HMX output stores and
    # weight reads across it do not. The conv-input window therefore sits inside one 4 MiB
    # page: small regions first, then the two resident tensors (HVX-only reads).
    foreach($r in @(@('Window',(($BatchTiles+2)*8192)),@('Staging',($BatchTiles*8192)),@('Weights',180224),@('Small',$smallBytes),@('Residual',$bytes),@('ConvOutput',$bytes))){
        $regions[$r[0]]=[ordered]@{Offset=$at;Bytes=[long]$r[1]}; $at+=& $al $r[1]
    }
    $page=4194304; $window=$regions.Window
    if([math]::Floor($window.Offset/$page) -ne [math]::Floor(($window.Offset+$window.Bytes-1)/$page)){throw 'Conv-input window crosses a 4 MiB VTCM boundary'}
    [pscustomobject]@{Frames=$Frames;Tiles=$tiles;TensorBytes=$bytes;BatchTiles=$BatchTiles;RegionAlign=$RegionAlign;Regions=$regions;Small=$small;VtcmBytes=$at}
}

function New-KokoroGenerator60xResidentRunSteps {
    param([ValidateRange(2,32768)][int]$Frames=7801,[ValidateRange(1,64)][int]$BatchTiles=16)
    . (Join-Path $PSScriptRoot 'Kokoro.ResBlockRun.ps1')
    foreach($file in 'Kokoro.HmxConv.ps1','Kokoro.AdaInInteger.ps1','Kokoro.ResidualInteger.ps1','Kokoro.AdaInSnakeInteger.ps1','Kokoro.AdaInStatisticsAccumulate.ps1','Kokoro.DmaCopy.ps1','Kokoro.BranchAverageInteger.ps1') { . (Join-Path $PSScriptRoot $file) }
    $layout=Get-KokoroGenerator60xResidentLayout -Frames $Frames -BatchTiles $BatchTiles
    $tiles=$layout.Tiles; $tensorBytes=$layout.TensorBytes; $batch=$BatchTiles
    $offResidual=$layout.Regions.Residual.Offset; $offConvOutput=$layout.Regions.ConvOutput.Offset; $offWindow=$layout.Regions.Window.Offset; $offStaging=$layout.Regions.Staging.Offset; $offWeights=$layout.Regions.Weights.Offset
    $offSmall=$layout.Regions.Small.Offset
    $offParameters=$offSmall+$layout.Small.Parameters; $offMoments=$offSmall+$layout.Small.Moments; $offInputMoments=$offSmall+$layout.Small.InputMoments; $offMeanParameters=$offSmall+$layout.Small.MeanParameters; $offSaved=$offSmall+$layout.Small.SavedTile; $offCoefficients=$offSmall+$layout.Small.Coefficients
    # Frozen output contract (Kokoro.Generator60xRun.ps1).
    $branchOutputBytes=192+5*$tensorBytes+6144
    $stride=[int]([math]::Ceiling($branchOutputBytes/128)*128)
    $finalOffset=3*$stride
    $outputBytes=192+$finalOffset+$tensorBytes+18432
    $weightOffsets=@(0,294912,983040);$weightBytes=2064384;$parameterBytes=147472
    $kernels=@(3,7,11)

    $s=[Collections.Generic.List[hashtable]]::new()
    $calls=[Collections.Generic.List[object]]::new()
    $imm={param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL);$s.Add(@{Op='lo';x=$r;i=($u -band 65535)});$s.Add(@{Op='hi';x=$r;i=($u -shr 16)})}
    $ptr={param([int]$r,[int]$baseReg,[long]$offset)
        $offsetReg=if($r -eq $baseReg){15}else{$r}
        & $imm $offsetReg $offset;$s.Add(@{Op='add';d=$r;s=$baseReg;t=$offsetReg})
    }
    $call={param([string]$label) $pc=@{Op='add-pc';d=14;i=0};$lo=@{Op='lo';x=15;i=0};$hi=@{Op='hi';x=15;i=0};$s.Add($pc);$s.Add($lo);$s.Add($hi);$s.Add(@{Op='add';d=14;s=14;t=15});$s.Add(@{Op='callr';s=14});$calls.Add(@{pc=$pc;low=$lo;high=$hi;label=$label})}
    $uid=0
    $label={ $script:__u++; "r60_$($script:__u)" }
    $script:__u=0
    # DMA dest <- src, length bytes; r24 holds two 64-byte aligned descriptor slots in DDR.
    $dma={param([int]$destBase,[long]$destOff,[int]$srcBase,[long]$srcOff,[long]$length)
        if($length -lt 2 -or $length -ge 2*16777215){throw 'DMA length out of range'}
        & $ptr 1 $srcBase $srcOff; & $ptr 2 $destBase $destOff; & $imm 3 $length; $s.Add(@{Op='addi';d=0;s=24;i=0})
        foreach($step in @(New-KokoroDmaCopySteps -NoReturn)){$s.Add($step)}
    }
    # HVX stores and HMX output stores complete before DMA or another unit reads them.
    $sync={ $s.Add(@{Op='syncht'}) }
    $fill={param([long]$off,[int]$count) # VTCM tiles <- zero point 128 in every odd byte
        & $ptr 4 18 $off; & $imm 6 0x80008000L; $s.Add(@{Op='vsplat';d=0;s=6}); & $imm 5 ($count*64); $s.Add(@{Op='imm';d=7;i=0})
        $n=& $label; $s.Add(@{Op='label';Name=$n});$s.Add(@{Op='vstore';s=4;t=0;Offset=0});$s.Add(@{Op='addi';d=4;s=4;i=128});$s.Add(@{Op='addi';d=5;s=5;i=-1});$s.Add(@{Op='gtu';d=0;s=5;t=7});$s.Add(@{Op='jump-p';u=0;Label=$n})
    }
    $copyTile={param([long]$destOff,[long]$srcOff)
        & $ptr 4 18 $srcOff; & $ptr 5 18 $destOff; $s.Add(@{Op='imm';d=6;i=64}); $s.Add(@{Op='imm';d=7;i=0})
        $n=& $label; $s.Add(@{Op='label';Name=$n});$s.Add(@{Op='vload';d=0;s=4;Offset=0});$s.Add(@{Op='vstore';s=5;t=0;Offset=0})
        $s.Add(@{Op='addi';d=4;s=4;i=128});$s.Add(@{Op='addi';d=5;s=5;i=128});$s.Add(@{Op='addi';d=6;s=6;i=-1});$s.Add(@{Op='gtu';d=0;s=6;t=7});$s.Add(@{Op='jump-p';u=0;Label=$n})
    }
    $zeroMoments={param([long]$off) & $ptr 4 18 $off; $s.Add(@{Op='vxor';d=0;s=0;t=0}); for($k=0;$k -lt 8;$k++){$s.Add(@{Op='vstore';s=4;t=0;Offset=(128*$k)})} }
    $copyMoments={param([long]$destOff,[long]$srcOff) & $ptr 4 18 $srcOff; & $ptr 5 18 $destOff; for($k=0;$k -lt 8;$k++){$s.Add(@{Op='vload';d=$k;s=4;Offset=(128*$k)})}; for($k=0;$k -lt 8;$k++){$s.Add(@{Op='vstore';s=5;t=$k;Offset=(128*$k)})} }
    # Frozen padded-row mask (Kokoro.ResBlockRun.ps1): rows >= Frames of the tile at
    # VTCM offset tileOff become u8 zero; the other row sharing each word is preserved.
    $mask={param([long]$tileOff)
        for($t=$Frames;$t -lt $tiles*32;$t++){
            for($block=0;$block -lt 4;$block++){
                $lane=$tileOff+$block*2048+[int][math]::Floor(($t%32)/2)*128
                & $ptr 4 18 $lane
                & $imm 6 $(if($t%2){0x0000ffffL}else{0xffff0000L})
                $s.Add(@{Op='imm';d=5;i=32});$s.Add(@{Op='imm';d=7;i=0})
                $n=& $label
                $s.Add(@{Op='label';Name=$n});$s.Add(@{Op='load';d=0;s=4;Offset=0});$s.Add(@{Op='and';d=0;s=0;t=6});$s.Add(@{Op='store';s=4;t=0;Offset=0})
                $s.Add(@{Op='addi';d=4;s=4;i=4});$s.Add(@{Op='addi';d=5;s=5;i=-1});$s.Add(@{Op='gtu';d=0;s=5;t=7});$s.Add(@{Op='jump-p';u=0;Label=$n})
            }
        }
    }
    # Frozen conv-input edge (Kokoro.ResBlockRun.ps1): rows >= Frames of the window tile at
    # tileOff become zero point 128.
    $edge={param([long]$tileOff)
        for($t=$Frames%32;$t -lt 32;$t++){
            for($block=0;$block -lt 4;$block++){
                $lane=$tileOff+$block*2048+[int][math]::Floor($t/2)*128
                & $ptr 4 18 $lane; & $imm 6 $(if($t%2){0x0000ffffL}else{0xffff0000L}); & $imm 8 $(if($t%2){0x80000000L}else{0x00008000L})
                $s.Add(@{Op='imm';d=5;i=32});$s.Add(@{Op='imm';d=7;i=0});$n=& $label
                $s.Add(@{Op='label';Name=$n});$s.Add(@{Op='load';d=0;s=4;Offset=0});$s.Add(@{Op='and';d=0;s=0;t=6});$s.Add(@{Op='or';d=0;s=0;t=8});$s.Add(@{Op='store';s=4;t=0;Offset=0});$s.Add(@{Op='addi';d=4;s=4;i=4});$s.Add(@{Op='addi';d=5;s=5;i=-1});$s.Add(@{Op='gtu';d=0;s=5;t=7});$s.Add(@{Op='jump-p';u=0;Label=$n})
            }
        }
    }
    $statsAcc={param([long]$srcOff,[int]$count) & $ptr 0 18 $srcOff; & $ptr 1 18 $offMoments; & $imm 2 $count; & $call 'body_statsacc' }

    # Checked resource wrapper of the frozen K=11 resblock runner, with admission sizes and
    # the VTCM request changed. Its connected_job call target keeps its PC (same length).
    $wrapperSource=New-KokoroResBlockRunSteps -Frames $Frames -Kernel 11
    $base=@($wrapperSource.Steps);$start=-1
    for($i=0;$i -lt $base.Count;$i++){if($base[$i].Op -eq 'label' -and $base[$i].Name -eq 'connected_job'){$start=$i;break}}
    if($start -lt 0){throw 'Connected wrapper anchor changed'}
    $minimum=@(4,$tensorBytes,$weightBytes,$parameterBytes,$outputBytes)
    $oldVtcm=[long]$wrapperSource.Layout.VtcmBytes
    $patched=@{request=0;check=0}
    for($i=0;$i -lt $start;$i++){
        $step=$base[$i].Clone()
        if($step.Op -eq 'lo' -and $step.x -eq 1 -and $i -ge 2 -and $base[$i-1].Op -eq 'load' -and $base[$i-1].s -eq 3){$a=[int](($base[$i-1].Offset-4)/8);$v=$minimum[$a]-1;$step.i=$v -band 65535;$base[$i+1]=$base[$i+1].Clone();$base[$i+1].i=$v -shr 16}
        elseif($step.Op -eq 'lo' -and $i+1 -lt $start -and $base[$i+1].Op -eq 'hi' -and $base[$i+1].x -eq $step.x){
            $value=[long]$step.i -bor ([long]$base[$i+1].i -shl 16)
            $new=$null
            if($step.x -eq 1 -and $value -eq $oldVtcm){$new=$layout.VtcmBytes;$patched.request++}
            elseif($step.x -eq 15 -and $value -eq $oldVtcm-1){$new=$layout.VtcmBytes-1;$patched.check++}
            if($null -ne $new){$step.i=$new -band 65535;$base[$i+1]=$base[$i+1].Clone();$base[$i+1].i=$new -shr 16}
        }
        $s.Add($step)
    }
    if($patched.request -ne 1 -or $patched.check -ne 1){throw "VTCM size anchors changed ($($patched.request),$($patched.check))"}

    # Job. r18 VTCM, r20 input, r21 weights, r22 parameter records, r23 output/telemetry.
    # r24 descriptor slots, r25 aligned DDR workspace, r26:27 start ticks.
    $s.Add(@{Op='label';Name='connected_job'});$s.Add(@{Op='allocframe';Bytes=256})
    foreach($r in 16,18,20,22,24,26){$s.Add(@{Op='store-d';s=29;t=$r;Offset=(($r-16)*4)})}
    $s.Add(@{Op='addi';d=24;s=29;i=(64+63)}); & $imm 0 -64; $s.Add(@{Op='and';d=24;s=24;t=0})
    $s.Add(@{Op='addi';d=25;s=23;i=191}); & $imm 0 -128; $s.Add(@{Op='and';d=25;s=25;t=0})
    $s.Add(@{Op='hwticks';d=26})
    for($b=0;$b -lt 3;$b++){
        $kernel=$kernels[$b]
        & $dma 18 $offResidual 20 0 $tensorBytes
        for($p=0;$p -lt 3;$p++){
            $dilation=@(1,3,5)[$p]
            foreach($half in 0,1){
                $st=2*$p+$half
                & $dma 18 $offParameters 22 ($b*49152+$st*8192) 8192
                & $dma 18 $offWeights 21 ($weightOffsets[$b]+$st*16384*$kernel) (16384*$kernel)
                if($half -eq 0 -and $p -eq 0){
                    # Stage input: unmasked last tile kept for the residual skip, then masked.
                    & $copyTile $offSaved ($offResidual+($tiles-1)*8192)
                    & $mask ($offResidual+($tiles-1)*8192)
                    if($b -eq 0){ & $zeroMoments $offMoments; & $statsAcc $offResidual $tiles; & $copyMoments $offInputMoments $offMoments }
                    else { & $copyMoments $offMoments $offInputMoments }
                }
                & $ptr 0 18 $offMoments; & $ptr 1 18 $offParameters; & $ptr 2 18 ($offCoefficients+($b*6+$st)*1024); & $imm 3 $Frames; & $call 'body_coeff'
                if(-not ($half -eq 1 -and $p -eq 2)){ & $zeroMoments $offMoments }
                $source=if($half -eq 0){$offResidual}else{$offConvOutput}
                $convLabel="body_conv_b${b}_d$(if($half -eq 0){$dilation}else{1})"
                for($start=0;$start -lt $tiles;$start+=$batch){
                    $count=[math]::Min($batch,$tiles-$start)
                    $first=[math]::Max(0,$start-1);$last=[math]::Min($tiles,$start+$count+1)
                    if($start -eq 0){ & $fill $offWindow 1 }
                    if($start+$count -eq $tiles){ & $fill ($offWindow+($count+1)*8192) 1 }
                    & $ptr 0 18 ($source+$first*8192); & $ptr 1 18 ($offWindow+($first-$start+1)*8192); & $ptr 2 18 ($offCoefficients+($b*6+$st)*1024); & $ptr 3 18 ($offParameters+2048); & $imm 4 ($last-$first)
                    & $call 'body_fused'
                    if($last -eq $tiles -and $Frames%32){ & $edge ($offWindow+($tiles-$start)*8192) }
                    $output=if($half -eq 0){$offConvOutput+$start*8192}else{$offStaging}
                    & $ptr 0 18 ($offWindow+8192); & $ptr 1 18 $offWeights; & $ptr 2 18 $output; & $ptr 3 18 ($offParameters+4096); & $imm 4 $count
                    & $call $convLabel
                    & $sync
                    $hasLast=($start+$count -eq $tiles)
                    if($half -eq 0){
                        if($hasLast){ & $mask ($offConvOutput+($tiles-1)*8192) }
                        & $statsAcc ($offConvOutput+$start*8192) $count
                    } else {
                        $normal=if($hasLast){$count-1}else{$count}
                        if($normal -gt 0){
                            & $ptr 0 18 ($offResidual+$start*8192); & $ptr 1 18 $offStaging; & $ptr 2 18 ($offResidual+$start*8192); & $ptr 3 18 ($offParameters+5120); & $imm 4 $normal
                            & $call 'body_residual'
                        }
                        if($hasLast){
                            & $ptr 0 18 $offSaved; & $ptr 1 18 ($offStaging+($count-1)*8192); & $ptr 2 18 ($offResidual+($tiles-1)*8192); & $ptr 3 18 ($offParameters+5120); & $imm 4 1
                            & $call 'body_residual'
                        }
                        if($p -lt 2){
                            if($hasLast){ & $copyTile $offSaved ($offResidual+($tiles-1)*8192); & $mask ($offResidual+($tiles-1)*8192) }
                            & $statsAcc ($offResidual+$start*8192) $count
                        }
                    }
                }
            }
        }
        if($b -lt 2){ & $sync; & $dma 25 ($b*$stride) 18 $offResidual $tensorBytes }
    }
    # Three-branch mean in chunks: branch 0 and 1 come back from DDR into the free C region.
    & $sync
    & $dma 18 $offMeanParameters 22 147456 16
    $chunk=[int][math]::Ceiling($tiles/2)
    for($j=0;$j*$chunk -lt $tiles;$j++){
        $chunkTiles=[math]::Min($chunk,$tiles-$j*$chunk)
        & $dma 18 $offConvOutput 25 ($j*$chunk*8192) ($chunkTiles*8192)
        & $dma 18 ($offConvOutput+$chunk*8192) 25 ($stride+$j*$chunk*8192) ($chunkTiles*8192)
        & $ptr 0 18 $offConvOutput; & $ptr 1 18 ($offConvOutput+$chunk*8192); & $ptr 2 18 ($offResidual+$j*$chunk*8192); & $ptr 3 18 $offConvOutput; & $ptr 4 18 $offMeanParameters; & $imm 5 $chunkTiles
        & $call 'body_average'; & $sync
        & $dma 25 ($finalOffset+$j*$chunk*8192) 18 $offConvOutput ($chunkTiles*8192)
    }
    & $dma 25 ($finalOffset+$tensorBytes) 18 $offCoefficients 18432
    $s.Add(@{Op='hwticks';d=0});$s.Add(@{Op='store-d';s=23;t=26;Offset=0});$s.Add(@{Op='store-d';s=23;t=0;Offset=8})
    $s.Add(@{Op='sub';d=0;s=25;t=23});& $imm 1 $finalOffset;$s.Add(@{Op='add';d=0;s=0;t=1});$s.Add(@{Op='store';s=23;t=0;Offset=40})
    $s.Add(@{Op='imm';d=0;i=19});$s.Add(@{Op='store';s=23;t=0;Offset=44})
    foreach($r in 16,18,20,22,24,26){$s.Add(@{Op='load-d';d=$r;s=29;Offset=(($r-16)*4)})}
    $s.Add(@{Op='dealloc-return'})

    $bodies=[Collections.Generic.List[object]]::new()
    $bodies.Add(@('body_fused',@(New-KokoroAdaInSnakeIntegerSteps)))
    $bodies.Add(@('body_statsacc',@(New-KokoroAdaInStatisticsAccumulateSteps)))
    $bodies.Add(@('body_coeff',@(New-KokoroAdaInIntegerCoefficientsSteps)))
    $bodies.Add(@('body_residual',@(New-KokoroResidualIntegerSteps)))
    $bodies.Add(@('body_average',@(New-KokoroBranchAverageIntegerSteps)))
    for($b=0;$b -lt 3;$b++){foreach($d in 1,3,5){$bodies.Add(@("body_conv_b${b}_d$d",@(New-KokoroHmxConvSteps -Kernel $kernels[$b] -Dilation $d -LabelPrefix "resident_b${b}_d$d")))}}
    foreach($pair in $bodies){$s.Add(@{Op='label';Name=$pair[0]});foreach($step in $pair[1]){$s.Add($step)}}
    $labels=@{};$pcs=[Collections.Generic.Dictionary[object,long]]::new();$pc=0L;$isa=Get-InstructionSet
    foreach($step in $s){if($step.Op -eq 'label'){if($labels.ContainsKey($step.Name)){throw "Duplicate label $($step.Name)"};$labels[$step.Name]=$pc};$pcs[$step]=$pc;$pc+=& $isa.Length $step}
    foreach($c in $calls){$delta=[uint32](($labels[$c.label]-$pcs[$c.pc]) -band 0xffffffffL);$c.low.i=$delta -band 65535;$c.high.i=$delta -shr 16}
    [pscustomobject]@{Steps=$s.ToArray();Layout=[ordered]@{Frames=$Frames;Tiles=$tiles;InputBytes=$tensorBytes;WeightBytes=$weightBytes;ParameterBytes=$parameterBytes;OutputBytes=$outputBytes;WorkspaceBytes=$tensorBytes;VtcmBytes=$layout.VtcmBytes;BranchStride=$stride;FinalWorkspaceOffset=$finalOffset;CoefficientBytes=18432;CoefficientOffset=$tensorBytes;CompletedStages=19;BatchTiles=$batch;Regions=$layout.Regions}}
}
