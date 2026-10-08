#requires -Version 7.4
# Stock generator tail at 16 bits: leaky_relu(0.01) -> conv_post -> exp / sin -> iSTFT -> PCM.
# Kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec istftnet.py Generator.forward and TorchSTFT.inverse; the integer
# contract and every constant: tools/New-KokoroGeneratorTail16Fixture.ps1.
#   per batch:  Kokoro.LeakyRelu16.ps1 (input -> conv_post input planes), HMX conv_post (three groups, 128 -> 64),
#               combine -> 16-bit logits (64 channels, magnitude bins in block 0, phase bins in block 1).
#   once:       Kokoro.TailSpectrum16.ps1 (logits -> Re/Im planes, resident with zero halo tiles).
#   per batch:  HMX iSTFT conv (64 -> 64, taps at frame shifts -1..2), combine -> PCM int16 (biased) in lanes
#               0..4 of each frame, scalar copy to DDR as sample 5m + r; the first and last five samples take
#               their envelope gains.
# Method 2, five buffers: config (tiles), input (128-channel biased u16 croutons), weights (conv_post Wh, Wl,
# iSTFT Wh, Wl), parameters (16384 B), output: [0] start ticks, [8] end ticks, [36] wrapper stage, [44] 1 when
# done, PCM int16 at 256 (5 * 32 * tiles samples written; the first 5 (frames - 1) are the audio).

function Get-KokoroGeneratorTail16Layout {
    param([ValidateRange(2,32768)][int]$Frames=7801,[ValidateRange(1,64)][int]$BatchTiles=16)
    $tiles=[int][math]::Ceiling($Frames/32)
    $al={param([long]$v) [long]([math]::Ceiling($v/65536)*65536)}
    $regions=[ordered]@{}; $at=0L
    # HMX activation sources first, none crossing a 4 MiB VTCM page.
    foreach($r in @(@('Window',(($BatchTiles+2)*8192)),@('WindowLow',(($BatchTiles+2)*8192)),@('Spectrum',(($tiles+2)*4096)),@('SpectrumLow',(($tiles+2)*4096)),
        @('Planes',(6L*$BatchTiles*4096)),@('Weights',172032),@('Tables',16384),@('Logits',($tiles*4096)),@('Pcm',($BatchTiles*4096)),@('Input',($tiles*8192)))){
        $regions[$r[0]]=[ordered]@{Offset=$at;Bytes=[long]$r[1]}; $at+=& $al $r[1]
    }
    $page=4194304
    foreach($name in 'Window','WindowLow','Spectrum','SpectrumLow'){ $w=$regions[$name]; if([math]::Floor($w.Offset/$page) -ne [math]::Floor(($w.Offset+$w.Bytes-1)/$page)){throw "$name crosses a 4 MiB VTCM boundary"} }
    $pcmBytes=[long]([math]::Ceiling(2*5*32*$tiles/256)*256)
    [pscustomobject]@{Frames=$Frames;Tiles=$tiles;InputBytes=($tiles*8192);BatchTiles=$BatchTiles;Regions=$regions;VtcmBytes=$at
        Samples=(5*($Frames-1));PcmOffset=256;OutputBytes=(256+$pcmBytes);PlaneStride=([long]$BatchTiles*4096)}
}

function New-KokoroGeneratorTail16RunSteps {
    param([ValidateRange(2,32768)][int]$Frames=7801,[ValidateRange(1,64)][int]$BatchTiles=16)
    . (Join-Path $PSScriptRoot 'Kokoro.ResBlockRun.ps1')
    foreach($file in 'Kokoro.HmxConvPlanes.ps1','Kokoro.PlaneCombine.ps1','Kokoro.LeakyRelu16.ps1','Kokoro.TailSpectrum16.ps1','Kokoro.DmaCopy.ps1') { . (Join-Path $PSScriptRoot $file) }
    $layout=Get-KokoroGeneratorTail16Layout -Frames $Frames -BatchTiles $BatchTiles
    $tiles=$layout.Tiles; $batch=$BatchTiles; $reg=$layout.Regions; $planeStride=$layout.PlaneStride
    $weightBytes=172032; $parameterBytes=16384
    $s=[Collections.Generic.List[hashtable]]::new()
    $calls=[Collections.Generic.List[object]]::new()
    $imm={param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL);$s.Add(@{Op='lo';x=$r;i=($u -band 65535)});$s.Add(@{Op='hi';x=$r;i=($u -shr 16)})}
    $ptr={param([int]$r,[int]$baseReg,[long]$offset) $offsetReg=if($r -eq $baseReg){15}else{$r}; & $imm $offsetReg $offset;$s.Add(@{Op='add';d=$r;s=$baseReg;t=$offsetReg}) }
    $call={param([string]$label) $pc=@{Op='add-pc';d=14;i=0};$lo=@{Op='lo';x=15;i=0};$hi=@{Op='hi';x=15;i=0};$s.Add($pc);$s.Add($lo);$s.Add($hi);$s.Add(@{Op='add';d=14;s=14;t=15});$s.Add(@{Op='callr';s=14});$calls.Add(@{pc=$pc;low=$lo;high=$hi;label=$label})}
    $script:__t16=0
    $label={ $script:__t16++; "t16_$($script:__t16)" }
    $dma={param([int]$destBase,[long]$destOff,[int]$srcBase,[long]$srcOff,[long]$length)
        if($length -lt 2 -or $length -ge 2*16777215){throw 'DMA length out of range'}
        & $ptr 1 $srcBase $srcOff; & $ptr 2 $destBase $destOff; & $imm 3 $length; $s.Add(@{Op='addi';d=0;s=24;i=0})
        foreach($step in @(New-KokoroDmaCopySteps -NoReturn)){$s.Add($step)}
    }
    # VTCM vectors <- one 32-bit pattern.
    $fill={param([long]$off,[int]$vectors,[long]$pattern)
        & $ptr 4 18 $off; & $imm 6 $pattern; $s.Add(@{Op='vsplat';d=0;s=6}); & $imm 5 $vectors; $s.Add(@{Op='imm';d=7;i=0})
        $n=& $label; $s.Add(@{Op='label';Name=$n});$s.Add(@{Op='vstore';s=4;t=0;Offset=0});$s.Add(@{Op='addi';d=4;s=4;i=128});$s.Add(@{Op='addi';d=5;s=5;i=-1});$s.Add(@{Op='gtu';d=0;s=5;t=7});$s.Add(@{Op='jump-p';u=0;Label=$n})
    }
    # Rows >= Frames of a 64-channel tile: every halfword <- value.
    $padRows={param([long]$tileOff,[long]$value)
        if($Frames%32 -eq 0){return}
        for($t=$Frames%32;$t -lt 32;$t++){
            for($block=0;$block -lt 2;$block++){
                $lane=$tileOff+$block*2048+[int][math]::Floor($t/2)*128
                & $ptr 4 18 $lane; & $imm 6 $(if($t%2){0x0000ffffL}else{0xffff0000L}); & $imm 8 $(if($t%2){$value -shl 16}else{$value})
                $s.Add(@{Op='imm';d=5;i=32});$s.Add(@{Op='imm';d=7;i=0});$n=& $label
                $s.Add(@{Op='label';Name=$n});$s.Add(@{Op='load';d=0;s=4;Offset=0});$s.Add(@{Op='and';d=0;s=0;t=6});$s.Add(@{Op='or';d=0;s=0;t=8});$s.Add(@{Op='store';s=4;t=0;Offset=0});$s.Add(@{Op='addi';d=4;s=4;i=4});$s.Add(@{Op='addi';d=5;s=5;i=-1});$s.Add(@{Op='gtu';d=0;s=5;t=7});$s.Add(@{Op='jump-p';u=0;Label=$n})
            }
        }
    }
    # One edge sample: halfword at VTCM offset (high half when $High) times gain g (Q14), stored as PCM sample t.
    $edgeSample={param([long]$vtcmOff,[bool]$High,[int]$gainIndex,[long]$sampleIndex)
        & $ptr 4 18 $vtcmOff; $s.Add(@{Op='load';d=8;s=4;Offset=0}); & $imm 9 0x80008000L; $s.Add(@{Op='xor';d=8;s=8;t=9})
        if(-not $High){ $s.Add(@{Op='asl-i';d=8;s=8;i=16}) }
        $s.Add(@{Op='asr-i';d=8;s=8;i=16})
        & $ptr 9 18 ($reg.Tables.Offset+14336+4*$gainIndex); $s.Add(@{Op='load';d=9;s=9;Offset=0})
        $s.Add(@{Op='mpy-d';d=10;s=8;t=9}); $s.Add(@{Op='imm';d=14;i=8192}); $s.Add(@{Op='imm';d=15;i=0})
        $s.Add(@{Op='add-d';d=10;s=10;t=14}); $s.Add(@{Op='asr-d-i';d=10;s=10;i=14})
        & $imm 12 -32768; & $imm 13 32767; $s.Add(@{Op='max';d=10;s=10;t=12}); $s.Add(@{Op='min';d=10;s=10;t=13})
        & $ptr 5 23 ($layout.PcmOffset+2*$sampleIndex); $s.Add(@{Op='store-h';s=5;t=10;Offset=0})
    }

    # Checked resource wrapper of the frozen K=11 resblock runner (as Kokoro.GeneratorTailRun.ps1).
    $wrapperSource=New-KokoroResBlockRunSteps -Frames $Frames -Kernel 11
    $base=@($wrapperSource.Steps);$start=-1
    for($i=0;$i -lt $base.Count;$i++){if($base[$i].Op -eq 'label' -and $base[$i].Name -eq 'connected_job'){$start=$i;break}}
    if($start -lt 0){throw 'Connected wrapper anchor changed'}
    $minimum=@(4,$layout.InputBytes,$weightBytes,$parameterBytes,$layout.OutputBytes)
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

    # Job. r18 VTCM, r20 input, r21 weights, r22 parameters, r23 output, r24 descriptors, r26:27 start ticks.
    $s.Add(@{Op='label';Name='connected_job'});$s.Add(@{Op='allocframe';Bytes=256})
    foreach($r in 16,18,20,22,24,26){$s.Add(@{Op='store-d';s=29;t=$r;Offset=(($r-16)*4)})}
    $s.Add(@{Op='addi';d=24;s=29;i=(64+63)}); & $imm 0 -64; $s.Add(@{Op='and';d=24;s=24;t=0})
    $s.Add(@{Op='hwticks';d=26})
    & $dma 18 $reg.Input.Offset 20 0 $layout.InputBytes
    & $dma 18 $reg.Weights.Offset 21 0 $weightBytes
    & $dma 18 $reg.Tables.Offset 22 0 $parameterBytes
    # conv_post per batch.
    for($startTile=0;$startTile -lt $tiles;$startTile+=$batch){
        $count=[math]::Min($batch,$tiles-$startTile)
        $first=[math]::Max(0,$startTile-1);$last=[math]::Min($tiles,$startTile+$count+1)
        if($startTile -eq 0){ & $fill $reg.Window.Offset 64 0x80008000L; & $fill $reg.WindowLow.Offset 64 0 }
        if($startTile+$count -eq $tiles){ & $fill ($reg.Window.Offset+($count+1)*8192) 64 0x80008000L; & $fill ($reg.WindowLow.Offset+($count+1)*8192) 64 0 }
        & $ptr 0 18 ($reg.Input.Offset+$first*8192); & $ptr 1 18 ($reg.Window.Offset+($first-$startTile+1)*8192); & $ptr 2 18 ($reg.WindowLow.Offset+($first-$startTile+1)*8192); & $imm 3 (64*($last-$first))
        & $call 'body_leaky'
        $s.Add(@{Op='syncht'})
        & $ptr 0 18 ($reg.Window.Offset+8192); & $ptr 1 18 ($reg.WindowLow.Offset+8192); & $ptr 2 18 $reg.Weights.Offset; & $ptr 3 18 $reg.Tables.Offset; & $imm 4 $count; & $ptr 5 18 $reg.Planes.Offset
        & $call 'body_conv_post'
        $s.Add(@{Op='syncht'})
        & $ptr 0 18 $reg.Planes.Offset; & $ptr 1 18 ($reg.Logits.Offset+$startTile*4096); & $imm 3 $count
        & $call 'body_combine'
    }
    # Spectrum, resident, with zero halo tiles and zero rows past the frames.
    & $fill $reg.Spectrum.Offset 32 0x80008000L; & $fill $reg.SpectrumLow.Offset 32 0
    & $fill ($reg.Spectrum.Offset+($tiles+1)*4096) 32 0x80008000L; & $fill ($reg.SpectrumLow.Offset+($tiles+1)*4096) 32 0
    & $ptr 0 18 $reg.Logits.Offset; & $ptr 1 18 ($reg.Spectrum.Offset+4096); & $ptr 2 18 ($reg.SpectrumLow.Offset+4096); & $ptr 3 18 ($reg.Tables.Offset+8192); & $imm 4 $tiles
    & $call 'body_spectrum'
    & $padRows ($reg.Spectrum.Offset+$tiles*4096) 0x8000; & $padRows ($reg.SpectrumLow.Offset+$tiles*4096) 0
    $s.Add(@{Op='syncht'})
    # iSTFT per batch, then PCM to DDR.
    $lastFrame=$Frames-2; $lastTile=[int][math]::Floor($lastFrame/32)
    for($startTile=0;$startTile -lt $tiles;$startTile+=$batch){
        $count=[math]::Min($batch,$tiles-$startTile)
        & $ptr 0 18 ($reg.Spectrum.Offset+($startTile+1)*4096); & $ptr 1 18 ($reg.SpectrumLow.Offset+($startTile+1)*4096); & $ptr 2 18 ($reg.Weights.Offset+114688); & $ptr 3 18 ($reg.Tables.Offset+4096); & $imm 4 $count; & $ptr 5 18 $reg.Planes.Offset
        & $call 'body_conv_istft'
        $s.Add(@{Op='syncht'})
        & $ptr 0 18 $reg.Planes.Offset; & $ptr 1 18 $reg.Pcm.Offset; & $imm 3 $count
        & $call 'body_combine'
        $s.Add(@{Op='syncht'})
        # Copy: frame m, lane r (word lane r of the row pair holds frames m (low) and m + 1 (high)) -> samples 5m + r.
        & $ptr 4 18 $reg.Pcm.Offset; & $ptr 5 23 ($layout.PcmOffset+320L*$startTile); & $imm 12 0x80008000L
        & $imm 6 $count; $s.Add(@{Op='imm';d=8;i=0})
        $tl=& $label; $pl=& $label
        $s.Add(@{Op='label';Name=$tl}); $s.Add(@{Op='imm';d=7;i=16})
        $s.Add(@{Op='label';Name=$pl})
        for($r=0;$r -lt 5;$r++){
            $s.Add(@{Op='load';d=0;s=4;Offset=(4*$r)}); $s.Add(@{Op='xor';d=0;s=0;t=12})
            $s.Add(@{Op='store-h';s=5;t=0;Offset=(2*$r)}); $s.Add(@{Op='asr-i';d=1;s=0;i=16}); $s.Add(@{Op='store-h';s=5;t=1;Offset=(10+2*$r)})
        }
        $s.Add(@{Op='addi';d=4;s=4;i=128}); $s.Add(@{Op='addi';d=5;s=5;i=20})
        $s.Add(@{Op='addi';d=7;s=7;i=-1}); $s.Add(@{Op='gtu';d=0;s=7;t=8}); $s.Add(@{Op='jump-p';u=0;Label=$pl})
        $s.Add(@{Op='addi';d=4;s=4;i=2048})
        $s.Add(@{Op='addi';d=6;s=6;i=-1}); $s.Add(@{Op='gtu';d=0;s=6;t=8}); $s.Add(@{Op='jump-p';u=0;Label=$tl})
        if($startTile -eq 0){ for($r=0;$r -lt 5;$r++){ & $edgeSample ($reg.Pcm.Offset+4*$r) $false $r $r } }
        if($lastTile -ge $startTile -and $lastTile -lt $startTile+$count){
            $pairOff=($lastTile-$startTile)*4096+128*[int][math]::Floor(($lastFrame%32)/2)
            for($r=0;$r -lt 5;$r++){ & $edgeSample ($reg.Pcm.Offset+$pairOff+4*$r) ([bool]($lastFrame%2)) (5+$r) (5L*$lastFrame+$r) }
        }
    }
    $s.Add(@{Op='hwticks';d=0});$s.Add(@{Op='store-d';s=23;t=26;Offset=0});$s.Add(@{Op='store-d';s=23;t=0;Offset=8})
    $s.Add(@{Op='imm';d=0;i=1});$s.Add(@{Op='store';s=23;t=0;Offset=44})
    foreach($r in 16,18,20,22,24,26){$s.Add(@{Op='load-d';d=$r;s=29;Offset=(($r-16)*4)})}
    $s.Add(@{Op='dealloc-return'})

    $bodies=@(
        @('body_leaky',@(New-KokoroLeakyRelu16Steps)),
        @('body_conv_post',@(New-KokoroHmxConvPlanesSteps -InputChannels 128 -OutputChannels 64 -Kernel 7 -Dilation 1 -WeightPlanes 2 -PlaneStride $planeStride -LabelPrefix 't16post')),
        @('body_combine',@(New-KokoroPlaneCombineSteps -Mode Conv -Channels 64 -Groups 3 -PlaneStride $planeStride -LabelPrefix 't16combine')),
        @('body_spectrum',@(New-KokoroTailSpectrum16Steps)),
        @('body_conv_istft',@(New-KokoroHmxConvPlanesSteps -InputChannels 64 -OutputChannels 64 -Kernel 7 -Dilation 1 -WeightPlanes 2 -PlaneStride $planeStride -LabelPrefix 't16istft')))
    foreach($pair in $bodies){$s.Add(@{Op='label';Name=$pair[0]});foreach($step in $pair[1]){$s.Add($step)}}
    $labels=@{};$pcs=[Collections.Generic.Dictionary[object,long]]::new();$pc=0L;$isa=Get-InstructionSet
    foreach($step in $s){if($step.Op -eq 'label'){if($labels.ContainsKey($step.Name)){throw "Duplicate label $($step.Name)"};$labels[$step.Name]=$pc};$pcs[$step]=$pc;$pc+=& $isa.Length $step}
    foreach($c in $calls){$delta=[uint32](($labels[$c.label]-$pcs[$c.pc]) -band 0xffffffffL);$c.low.i=$delta -band 65535;$c.high.i=$delta -shr 16}
    [pscustomobject]@{Steps=$s.ToArray();Layout=[ordered]@{Frames=$Frames;Tiles=$tiles;InputBytes=$layout.InputBytes;WeightBytes=$weightBytes;ParameterBytes=$parameterBytes;OutputBytes=$layout.OutputBytes;VtcmBytes=$layout.VtcmBytes;Samples=$layout.Samples;PcmOffset=$layout.PcmOffset;BatchTiles=$batch;Regions=$reg}}
}
