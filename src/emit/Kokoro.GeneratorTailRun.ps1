#requires -Version 7.4
# Stock generator tail: leaky_relu(0.01) -> conv_post -> exp / sin -> 20-point iSTFT -> PCM.
# Source: hexgrad/kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec istftnet.py:309-314 and
# TorchSTFT.inverse; iSTFT semantics PyTorch v2.14.0 2b3ec34829036a65cd9d1398ea72a0167dc37470
# aten/src/ATen/native/SpectralOps.cpp istft. Integer contract and every constant:
# tools/New-KokoroGeneratorTailFixture.ps1.
#
# Method 2: config {tiles}, input = generator 60x output (native u8 croutons), conv_post
# weights (HMX order, 2 x 7 x 4 x 2048 B), parameters (fixture layout, 73,856 B), output:
#   [0] start ticks, [8] end ticks, [36] wrapper stage, [40] codes offset, [44] 1 when done;
#   PCM int16 at 256; overlap-add accumulator (int32, Q24) at 78,336; at the codes offset
#   the coarse then the fine conv_post output tensors (native u8 croutons), written by DMA.
# DDR regions read or written by scalar code (parameters, accumulator, PCM) are never
# touched by DMA; the codes region is written only by DMA.
function Get-KokoroGeneratorTailLayout {
    param([ValidateRange(2,32768)][int]$Frames=7801,[ValidateRange(1,64)][int]$BatchTiles=16)
    $tiles=[int][math]::Ceiling($Frames/32); $bytes=$tiles*8192
    $al={param([long]$v) [long]([math]::Ceiling($v/65536)*65536)}
    $regions=[ordered]@{}; $at=0L
    # The conv-input window comes first so no HMX activation read crosses a 4 MiB boundary.
    foreach($r in @(@('Window',(($BatchTiles+2)*8192)),@('CodesCoarse',($BatchTiles*8192)),@('CodesFine',($BatchTiles*8192)),@('Weights',114688),@('ColumnTables',2048),@('Input',$bytes))){
        $regions[$r[0]]=[ordered]@{Offset=$at;Bytes=[long]$r[1]}; $at+=& $al $r[1]
    }
    if($regions.Window.Offset+$regions.Window.Bytes -gt 4194304){throw 'Conv-input window crosses a 4 MiB VTCM boundary'}
    $samples=5*($Frames-1); $accumulator=20+5*($Frames-1)
    $pcmOffset=256; $accOffset=$pcmOffset+[long]([math]::Ceiling(2*$samples/256)*256)
    $codesFloor=$accOffset+[long]([math]::Ceiling(4*$accumulator/256)*256)
    [pscustomobject]@{Frames=$Frames;Tiles=$tiles;TensorBytes=$bytes;BatchTiles=$BatchTiles;Regions=$regions;VtcmBytes=$at
        Samples=$samples;AccumulatorWords=$accumulator;PcmOffset=$pcmOffset;AccumulatorOffset=$accOffset;CodesFloor=$codesFloor
        OutputBytes=$codesFloor+256+2*$bytes}
}

# One frame: r0 coarse code pointer, r1 fine code pointer (byte 1 of the frame's lane, channel 0),
# r2 accumulator at 5*frame, r3 coarse table block, r4 fine table block, r5 coefficients A,
# r6 coefficients B. Caller-saved registers only.
function New-KokoroTailFrameSteps {
    param([string]$LabelPrefix='tailframe')
    $s=[Collections.Generic.List[hashtable]]::new()
    $imm={param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL);$s.Add(@{Op='lo';x=$r;i=($u -band 65535)});$s.Add(@{Op='hi';x=$r;i=($u -shr 16)})}
    $s.Add(@{Op='allocframe';Bytes=88})
    $s.Add(@{Op='imm';d=7;i=253}); $s.Add(@{Op='imm';d=12;i=16384}); $s.Add(@{Op='imm';d=13;i=0})
    # Pick the fine code unless it saturated, and the matching table block.
    $pick={param([int]$channel,[string]$name)
        $s.Add(@{Op='load-ub';d=14;s=1;Offset=(4*$channel)}); $s.Add(@{Op='addi';d=15;s=14;i=-1})
        $s.Add(@{Op='gtu';d=0;s=15;t=7}); $s.Add(@{Op='jump-p';u=0;Label="${name}_coarse"})
        $s.Add(@{Op='addi';d=15;s=4;i=0}); $s.Add(@{Op='eq';d=0;s=7;t=7}); $s.Add(@{Op='jump-p';u=0;Label="${name}_picked"})
        $s.Add(@{Op='label';Name="${name}_coarse"}); $s.Add(@{Op='load-ub';d=14;s=0;Offset=(4*$channel)}); $s.Add(@{Op='addi';d=15;s=3;i=0})
        $s.Add(@{Op='label';Name="${name}_picked"}); $s.Add(@{Op='asl-i';d=14;s=14;i=2}); $s.Add(@{Op='add';d=14;s=14;t=15})
    }
    for($k=0;$k -lt 11;$k++){
        & $pick $k "${LabelPrefix}_m$k"
        $s.Add(@{Op='addi';d=14;s=14;i=($k*1024)}); $s.Add(@{Op='load';d=10;s=14;Offset=0})          # exp
        & $pick (11+$k) "${LabelPrefix}_p$k"
        $s.Add(@{Op='addi';d=14;s=14;i=(11264+$k*1024)}); $s.Add(@{Op='load';d=11;s=14;Offset=0})  # cos(sin)
        $s.Add(@{Op='addi';d=14;s=14;i=11264}); $s.Add(@{Op='load';d=15;s=14;Offset=0})             # sin(sin)
        $s.Add(@{Op='mpy-d';d=8;s=10;t=11}); $s.Add(@{Op='add-d';d=8;s=8;t=12}); $s.Add(@{Op='asr-d-i';d=8;s=8;i=15})
        $s.Add(@{Op='store';s=29;t=8;Offset=(4*$k)})
        $s.Add(@{Op='mpy-d';d=8;s=10;t=15}); $s.Add(@{Op='add-d';d=8;s=8;t=12}); $s.Add(@{Op='asr-d-i';d=8;s=8;i=15})
        $s.Add(@{Op='store';s=29;t=8;Offset=(44+4*$k)})
    }
    for($n=0;$n -lt 20;$n++){
        & $imm 8 2097152; $s.Add(@{Op='imm';d=9;i=0})
        for($k=0;$k -lt 11;$k++){
            $s.Add(@{Op='load';d=10;s=5;Offset=(4*(11*$n+$k))}); $s.Add(@{Op='load';d=11;s=29;Offset=(4*$k)})
            $s.Add(@{Op='mpy-d';d=14;s=10;t=11}); $s.Add(@{Op='add-d';d=8;s=8;t=14})
            if($k -ge 1 -and $k -le 9){
                $s.Add(@{Op='load';d=10;s=6;Offset=(4*(11*$n+$k))}); $s.Add(@{Op='load';d=11;s=29;Offset=(44+4*$k)})
                $s.Add(@{Op='mpy-d';d=14;s=10;t=11}); $s.Add(@{Op='add-d';d=8;s=8;t=14})
            }
        }
        $s.Add(@{Op='asr-d-i';d=8;s=8;i=22})
        $s.Add(@{Op='load';d=10;s=2;Offset=(4*$n)}); $s.Add(@{Op='add';d=10;s=10;t=8}); $s.Add(@{Op='store';s=2;t=10;Offset=(4*$n)})
    }
    $s.Add(@{Op='dealloc-return'})
    $s.ToArray()
}

function New-KokoroGeneratorTailRunSteps {
    param([ValidateRange(2,32768)][int]$Frames=7801,[ValidateRange(1,64)][int]$BatchTiles=16)
    . (Join-Path $PSScriptRoot 'Kokoro.ResBlockRun.ps1')
    foreach($file in 'Kokoro.HmxConv.ps1','Kokoro.LeakyReluInteger.ps1','Kokoro.DmaCopy.ps1') { . (Join-Path $PSScriptRoot $file) }
    $layout=Get-KokoroGeneratorTailLayout -Frames $Frames -BatchTiles $BatchTiles
    $tiles=$layout.Tiles; $tensorBytes=$layout.TensorBytes; $batch=$BatchTiles
    $offWindow=$layout.Regions.Window.Offset; $offCoarse=$layout.Regions.CodesCoarse.Offset; $offFine=$layout.Regions.CodesFine.Offset
    $offWeights=$layout.Regions.Weights.Offset; $offTables=$layout.Regions.ColumnTables.Offset; $offInput=$layout.Regions.Input.Offset
    $weightBytes=114688; $parameterBytes=73856
    $param=[ordered]@{Leaky=0;ColumnCoarse=1024;PassCoarse=4096;PassFine=37888;CoefA=71680;CoefB=72704;EdgeGain=73728}

    $s=[Collections.Generic.List[hashtable]]::new()
    $calls=[Collections.Generic.List[object]]::new()
    $imm={param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL);$s.Add(@{Op='lo';x=$r;i=($u -band 65535)});$s.Add(@{Op='hi';x=$r;i=($u -shr 16)})}
    $ptr={param([int]$r,[int]$baseReg,[long]$offset) $offsetReg=if($r -eq $baseReg){15}else{$r}; & $imm $offsetReg $offset;$s.Add(@{Op='add';d=$r;s=$baseReg;t=$offsetReg}) }
    $call={param([string]$label) $pc=@{Op='add-pc';d=14;i=0};$lo=@{Op='lo';x=15;i=0};$hi=@{Op='hi';x=15;i=0};$s.Add($pc);$s.Add($lo);$s.Add($hi);$s.Add(@{Op='add';d=14;s=14;t=15});$s.Add(@{Op='callr';s=14});$calls.Add(@{pc=$pc;low=$lo;high=$hi;label=$label})}
    $script:__tailLabel=0
    $label={ $script:__tailLabel++; "tail_$($script:__tailLabel)" }
    $dma={param([int]$destBase,[long]$destOff,[int]$srcBase,[long]$srcOff,[long]$length)
        & $ptr 1 $srcBase $srcOff; & $ptr 2 $destBase $destOff; & $imm 3 $length; $s.Add(@{Op='addi';d=0;s=24;i=0})
        foreach($step in @(New-KokoroDmaCopySteps -NoReturn)){$s.Add($step)}
    }
    $fill={param([long]$off)
        & $ptr 4 18 $off; & $imm 6 0x80008000L; $s.Add(@{Op='vsplat';d=0;s=6}); $s.Add(@{Op='imm';d=5;i=64}); $s.Add(@{Op='imm';d=7;i=0})
        $n=& $label; $s.Add(@{Op='label';Name=$n});$s.Add(@{Op='vstore';s=4;t=0;Offset=0});$s.Add(@{Op='addi';d=4;s=4;i=128});$s.Add(@{Op='addi';d=5;s=5;i=-1});$s.Add(@{Op='gtu';d=0;s=5;t=7});$s.Add(@{Op='jump-p';u=0;Label=$n})
    }
    # Frozen conv-input edge (Kokoro.ResBlockRun.ps1): rows >= Frames become zero point 128.
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

    # Checked resource wrapper of the frozen K=11 resblock runner with this job's admission
    # sizes and VTCM request (same patching as Kokoro.Generator60xResidentRun.ps1).
    $wrapperSource=New-KokoroResBlockRunSteps -Frames $Frames -Kernel 11
    $base=@($wrapperSource.Steps);$start=-1
    for($i=0;$i -lt $base.Count;$i++){if($base[$i].Op -eq 'label' -and $base[$i].Name -eq 'connected_job'){$start=$i;break}}
    if($start -lt 0){throw 'Connected wrapper anchor changed'}
    $minimum=@(4,$tensorBytes,$weightBytes,$parameterBytes,$layout.OutputBytes)
    $oldVtcm=[long]$wrapperSource.Layout.VtcmBytes; $patched=@{request=0;check=0}
    for($i=0;$i -lt $start;$i++){
        $step=$base[$i].Clone()
        if($step.Op -eq 'lo' -and $step.x -eq 1 -and $i -ge 2 -and $base[$i-1].Op -eq 'load' -and $base[$i-1].s -eq 3){$a=[int](($base[$i-1].Offset-4)/8);$v=$minimum[$a]-1;$step.i=$v -band 65535;$base[$i+1]=$base[$i+1].Clone();$base[$i+1].i=$v -shr 16}
        elseif($step.Op -eq 'lo' -and $i+1 -lt $start -and $base[$i+1].Op -eq 'hi' -and $base[$i+1].x -eq $step.x){
            $value=[long]$step.i -bor ([long]$base[$i+1].i -shl 16); $new=$null
            if($step.x -eq 1 -and $value -eq $oldVtcm){$new=$layout.VtcmBytes;$patched.request++}
            elseif($step.x -eq 15 -and $value -eq $oldVtcm-1){$new=$layout.VtcmBytes-1;$patched.check++}
            if($null -ne $new){$step.i=$new -band 65535;$base[$i+1]=$base[$i+1].Clone();$base[$i+1].i=$new -shr 16}
        }
        $s.Add($step)
    }
    if($patched.request -ne 1 -or $patched.check -ne 1){throw "VTCM size anchors changed ($($patched.request),$($patched.check))"}

    # Job. r18 VTCM, r20 input, r21 weights, r22 parameters, r23 output; r24 descriptors,
    # r25 codes region (128-aligned), r26:27 start ticks, r16/r17 frame loop.
    $s.Add(@{Op='label';Name='connected_job'});$s.Add(@{Op='allocframe';Bytes=256})
    foreach($r in 16,18,20,22,24,26){$s.Add(@{Op='store-d';s=29;t=$r;Offset=(($r-16)*4)})}
    $s.Add(@{Op='addi';d=24;s=29;i=(64+63)}); & $imm 0 -64; $s.Add(@{Op='and';d=24;s=24;t=0})
    & $ptr 25 23 ($layout.CodesFloor+127); & $imm 0 -128; $s.Add(@{Op='and';d=25;s=25;t=0})
    $s.Add(@{Op='hwticks';d=26})
    & $dma 18 $offInput 20 0 $tensorBytes
    & $dma 18 $offWeights 21 0 $weightBytes
    & $dma 18 $offTables 22 $param.ColumnCoarse 2048
    # Zero the overlap-add accumulator.
    & $ptr 4 23 $layout.AccumulatorOffset; & $imm 5 $layout.AccumulatorWords; $s.Add(@{Op='imm';d=6;i=0}); $s.Add(@{Op='imm';d=7;i=0})
    $s.Add(@{Op='label';Name='tail_zero'}); $s.Add(@{Op='store';s=4;t=6;Offset=0}); $s.Add(@{Op='addi';d=4;s=4;i=4}); $s.Add(@{Op='addi';d=5;s=5;i=-1}); $s.Add(@{Op='gtu';d=0;s=5;t=7}); $s.Add(@{Op='jump-p';u=0;Label='tail_zero'})
    for($startTile=0;$startTile -lt $tiles;$startTile+=$batch){
        $count=[math]::Min($batch,$tiles-$startTile)
        $first=[math]::Max(0,$startTile-1);$last=[math]::Min($tiles,$startTile+$count+1)
        if($startTile -eq 0){ & $fill $offWindow }
        if($startTile+$count -eq $tiles){ & $fill ($offWindow+($count+1)*8192) }
        & $ptr 0 18 ($offInput+$first*8192); & $ptr 1 18 ($offWindow+($first-$startTile+1)*8192); & $ptr 2 22 $param.Leaky; & $imm 3 ($last-$first)
        & $call 'body_leaky'
        if($last -eq $tiles -and $Frames%32){ & $edge ($offWindow+($tiles-$startTile)*8192) }
        foreach($pass in @(@($offCoarse,0),@($offFine,1024))){
            & $ptr 0 18 ($offWindow+8192); & $ptr 1 18 $offWeights; & $ptr 2 18 $pass[0]; & $ptr 3 18 ($offTables+$pass[1]); & $imm 4 $count
            & $call 'body_conv'
        }
        $s.Add(@{Op='syncht'})
        & $dma 25 ($startTile*8192) 18 $offCoarse ($count*8192)
        & $dma 25 ($tensorBytes+$startTile*8192) 18 $offFine ($count*8192)
        # Frames of this batch through the iSTFT body.
        $frameEnd=[math]::Min($Frames,($startTile+$count)*32)
        & $imm 16 ($startTile*32); & $imm 17 $frameEnd
        $loop=& $label; $s.Add(@{Op='label';Name=$loop})
        $s.Add(@{Op='lsr-i';d=0;s=16;i=5}); & $imm 14 (-$startTile); $s.Add(@{Op='add';d=0;s=0;t=14}); $s.Add(@{Op='asl-i';d=0;s=0;i=13})
        $s.Add(@{Op='imm';d=1;i=31}); $s.Add(@{Op='and';d=1;s=16;t=1})
        $s.Add(@{Op='lsr-i';d=14;s=1;i=1}); $s.Add(@{Op='asl-i';d=14;s=14;i=7}); $s.Add(@{Op='add';d=0;s=0;t=14})
        $s.Add(@{Op='imm';d=15;i=1}); $s.Add(@{Op='and';d=15;s=1;t=15}); $s.Add(@{Op='asl-i';d=15;s=15;i=1}); $s.Add(@{Op='add';d=0;s=0;t=15})
        & $imm 14 ($offCoarse+1); $s.Add(@{Op='add';d=0;s=0;t=14}); $s.Add(@{Op='add';d=0;s=0;t=18})
        & $imm 14 ($offFine-$offCoarse); $s.Add(@{Op='add';d=1;s=0;t=14})
        $s.Add(@{Op='asl-i';d=14;s=16;i=4}); $s.Add(@{Op='asl-i';d=15;s=16;i=2}); $s.Add(@{Op='add';d=14;s=14;t=15})
        & $ptr 2 23 $layout.AccumulatorOffset; $s.Add(@{Op='add';d=2;s=2;t=14})
        & $ptr 3 22 $param.PassCoarse; & $ptr 4 22 $param.PassFine; & $ptr 5 22 $param.CoefA; & $ptr 6 22 $param.CoefB
        & $call 'body_frame'
        $s.Add(@{Op='addi';d=16;s=16;i=1}); $s.Add(@{Op='gtu';d=0;s=17;t=16}); $s.Add(@{Op='jump-p';u=0;Label=$loop})
    }
    # PCM: v = accumulator[j + 10]; the first and last five samples take their envelope gain;
    # pcm = clamp((v + 256) >> 9) as int16.
    & $ptr 4 23 ($layout.AccumulatorOffset+40); & $ptr 5 23 $layout.PcmOffset
    & $imm 12 -32768; & $imm 13 32767
    $sample={param([bool]$Edge,[int]$Index)
        $s.Add(@{Op='load';d=8;s=4;Offset=0})
        if($Edge){
            & $ptr 9 22 ($param.EdgeGain+4*$Index); $s.Add(@{Op='load';d=9;s=9;Offset=0})
            $s.Add(@{Op='mpy-d';d=10;s=8;t=9}); $s.Add(@{Op='imm';d=14;i=8192}); $s.Add(@{Op='imm';d=15;i=0})
            $s.Add(@{Op='add-d';d=10;s=10;t=14}); $s.Add(@{Op='asr-d-i';d=10;s=10;i=14}); $s.Add(@{Op='addi';d=8;s=10;i=0})
        }
        $s.Add(@{Op='addi';d=8;s=8;i=256}); $s.Add(@{Op='asr-i';d=8;s=8;i=9})
        $s.Add(@{Op='max';d=8;s=8;t=12}); $s.Add(@{Op='min';d=8;s=8;t=13}); $s.Add(@{Op='store-h';s=5;t=8;Offset=0})
        $s.Add(@{Op='addi';d=4;s=4;i=4}); $s.Add(@{Op='addi';d=5;s=5;i=2})
    }
    for($j=0;$j -lt 5;$j++){ & $sample $true $j }
    & $imm 6 ($layout.Samples-10); $s.Add(@{Op='imm';d=7;i=0})
    $s.Add(@{Op='label';Name='tail_pcm'}); & $sample $false 0
    $s.Add(@{Op='addi';d=6;s=6;i=-1}); $s.Add(@{Op='gtu';d=0;s=6;t=7}); $s.Add(@{Op='jump-p';u=0;Label='tail_pcm'})
    for($j=5;$j -lt 10;$j++){ & $sample $true $j }
    $s.Add(@{Op='hwticks';d=0});$s.Add(@{Op='store-d';s=23;t=26;Offset=0});$s.Add(@{Op='store-d';s=23;t=0;Offset=8})
    $s.Add(@{Op='sub';d=0;s=25;t=23});$s.Add(@{Op='store';s=23;t=0;Offset=40})
    $s.Add(@{Op='imm';d=0;i=1});$s.Add(@{Op='store';s=23;t=0;Offset=44})
    foreach($r in 16,18,20,22,24,26){$s.Add(@{Op='load-d';d=$r;s=29;Offset=(($r-16)*4)})}
    $s.Add(@{Op='dealloc-return'})

    foreach($pair in @(@('body_leaky',@(New-KokoroLeakyReluIntegerSteps)),@('body_conv',@(New-KokoroHmxConvSteps -Kernel 7 -Dilation 1 -LabelPrefix 'tailconv')),@('body_frame',@(New-KokoroTailFrameSteps)))){
        $s.Add(@{Op='label';Name=$pair[0]});foreach($step in $pair[1]){$s.Add($step)}
    }
    $labels=@{};$pcs=[Collections.Generic.Dictionary[object,long]]::new();$pc=0L;$isa=Get-InstructionSet
    foreach($step in $s){if($step.Op -eq 'label'){if($labels.ContainsKey($step.Name)){throw "Duplicate label $($step.Name)"};$labels[$step.Name]=$pc};$pcs[$step]=$pc;$pc+=& $isa.Length $step}
    foreach($c in $calls){$delta=[uint32](($labels[$c.label]-$pcs[$c.pc]) -band 0xffffffffL);$c.low.i=$delta -band 65535;$c.high.i=$delta -shr 16}
    [pscustomobject]@{Steps=$s.ToArray();Layout=[ordered]@{Frames=$Frames;Tiles=$tiles;InputBytes=$tensorBytes;WeightBytes=$weightBytes;ParameterBytes=$parameterBytes;OutputBytes=$layout.OutputBytes;VtcmBytes=$layout.VtcmBytes;Samples=$layout.Samples;PcmOffset=$layout.PcmOffset;AccumulatorOffset=$layout.AccumulatorOffset;CodesFloor=$layout.CodesFloor;BatchTiles=$batch;Regions=$layout.Regions}}
}
