#requires -Version 7.4
# Stock harmonic-source STFT at 16 bits: har = [|X|, angle(X)] of TorchSTFT.transform (torch.stft n_fft 20, hop 5, periodic
# Hann 20, centre with reflect padding; Kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec istftnet.py Generator.forward)
# of the merged harmonic source, written as har's two byte planes in 64-channel croutons (the 60x front's layout).
#   per batch:  Kokoro.StftWindow16.ps1 (padded signal -> frame windows, two planes), HMX STFT conv (64 -> 64, the centre
#               tap of K 3: input channel c = padded sample 5 t + c, outputs Re_k at channel k, Im_k at 32 + k), combine
#               -> 16-bit Re/Im, Kokoro.StftPolar16.ps1 (CORDIC -> har planes), DMA of both planes to DDR.
# The integer contract and every constant: tools/New-KokoroHarmonicStft16Fixture.ps1.
# Method 2, five buffers: config (tiles), input (the reflect-padded merge signal, int16 in the merge unit), weights (STFT
# conv Wh, Wl), parameters (16384 B: conv column tables at 0, group 3 shifts at 5120, polar constants at 8192), output:
# [0] start ticks, [8] end ticks, [36] wrapper stage, [44] 1 when done; har high plane at 256, low plane after it
# (tiles * 4096 B each).

function Get-KokoroHarmonicStft16Layout {
    param([ValidateRange(2,32768)][int]$Frames=7801,[ValidateRange(2,64)][int]$BatchTiles=16)
    if ($BatchTiles % 2) { throw 'Window preparation works on tile pairs: use an even batch' }
    $tiles=[int][math]::Ceiling($Frames/32); $pairs=[int][math]::Ceiling($tiles/2)
    $signalBytes=[long]($pairs*640+128)
    $al={param([long]$v) [long]([math]::Ceiling($v/65536)*65536)}
    $regions=[ordered]@{}; $at=0L
    foreach($r in @(@('Window',(($BatchTiles+2)*4096)),@('WindowLow',(($BatchTiles+2)*4096)),@('Planes',(6L*$BatchTiles*4096)),@('Weights',24576),@('Tables',16384),
        @('Signal',$signalBytes),@('Spectrum',($BatchTiles*4096)),@('HarHigh',($BatchTiles*4096)),@('HarLow',($BatchTiles*4096)))){
        $regions[$r[0]]=[ordered]@{Offset=$at;Bytes=[long]$r[1]}; $at+=& $al $r[1]
    }
    $page=4194304
    foreach($name in 'Window','WindowLow'){ $w=$regions[$name]; if([math]::Floor($w.Offset/$page) -ne [math]::Floor(($w.Offset+$w.Bytes-1)/$page)){throw "$name crosses a 4 MiB VTCM page"} }
    [pscustomobject]@{Frames=$Frames;Tiles=$tiles;Pairs=$pairs;Samples=(5*($Frames-1));SignalBytes=$signalBytes;InputBytes=$signalBytes;WeightBytes=24576;ParameterBytes=16384
        BatchTiles=$BatchTiles;Regions=$regions;VtcmBytes=$at;PlaneStride=([long]$BatchTiles*4096);HarOffset=256;OutputBytes=(256+2L*$tiles*4096)}
}

# The har job portion, appended to a caller's step list: DMA of the signal, weights and parameters into VTCM (r18) from the
# given base registers and offsets, then per batch window, conv, combine, polar, and both har planes to HarBase +
# HarOffset (high) and + tiles * 4096 (low). Uses r0..r15 only; the caller provides r18 and r24 (DMA descriptor slots).
function Add-KokoroHarmonicStft16JobSteps {
    param([Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[hashtable]]$Steps,[Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Calls,
        [ValidateRange(2,32768)][int]$Frames=7801,[ValidateRange(2,64)][int]$BatchTiles=16,
        [int]$InputBase=20,[long]$InputOffset=0,[int]$WeightsBase=21,[long]$WeightsOffset=0,[int]$TablesBase=22,[long]$TablesOffset=0,
        [int]$HarBase=23,[long]$HarOffset=256)
    $layout=Get-KokoroHarmonicStft16Layout -Frames $Frames -BatchTiles $BatchTiles
    $tiles=$layout.Tiles; $batch=$BatchTiles; $reg=$layout.Regions
    $s=$Steps; $calls=$Calls
    $imm={param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL);$s.Add(@{Op='lo';x=$r;i=($u -band 65535)});$s.Add(@{Op='hi';x=$r;i=($u -shr 16)})}
    $ptr={param([int]$r,[int]$baseReg,[long]$offset) $offsetReg=if($r -eq $baseReg){15}else{$r}; & $imm $offsetReg $offset;$s.Add(@{Op='add';d=$r;s=$baseReg;t=$offsetReg}) }
    $call={param([string]$label) $pc=@{Op='add-pc';d=14;i=0};$lo=@{Op='lo';x=15;i=0};$hi=@{Op='hi';x=15;i=0};$s.Add($pc);$s.Add($lo);$s.Add($hi);$s.Add(@{Op='add';d=14;s=14;t=15});$s.Add(@{Op='callr';s=14});$calls.Add(@{pc=$pc;low=$lo;high=$hi;label=$label})}
    $script:__h16=0
    $label={ $script:__h16++; "h16_$($script:__h16)" }
    $dma={param([int]$destBase,[long]$destOff,[int]$srcBase,[long]$srcOff,[long]$length)
        if($length -lt 2 -or $length -ge 2*16777215){throw 'DMA length out of range'}
        & $ptr 1 $srcBase $srcOff; & $ptr 2 $destBase $destOff; & $imm 3 $length; $s.Add(@{Op='addi';d=0;s=24;i=0})
        foreach($step in @(New-KokoroDmaCopySteps -NoReturn)){$s.Add($step)}
    }
    $fill={param([long]$off,[int]$vectors,[long]$pattern)
        & $ptr 4 18 $off; & $imm 6 $pattern; $s.Add(@{Op='vsplat';d=0;s=6}); & $imm 5 $vectors; $s.Add(@{Op='imm';d=7;i=0})
        $n=& $label; $s.Add(@{Op='label';Name=$n});$s.Add(@{Op='vstore';s=4;t=0;Offset=0});$s.Add(@{Op='addi';d=4;s=4;i=128});$s.Add(@{Op='addi';d=5;s=5;i=-1});$s.Add(@{Op='gtu';d=0;s=5;t=7});$s.Add(@{Op='jump-p';u=0;Label=$n})
    }
    # Rows >= Frames of the last tile, block 0: every halfword <- value (har x = 0: 0x8000 high, 0 low).
    $padRows={param([long]$tileOff,[long]$value)
        if($Frames%32 -eq 0){return}
        for($t=$Frames%32;$t -lt 32;$t++){
            $lane=$tileOff+[int][math]::Floor($t/2)*128
            & $ptr 4 18 $lane; & $imm 6 $(if($t%2){0x0000ffffL}else{0xffff0000L}); & $imm 8 $(if($t%2){$value -shl 16}else{$value})
            $s.Add(@{Op='imm';d=5;i=32});$s.Add(@{Op='imm';d=7;i=0});$n=& $label
            $s.Add(@{Op='label';Name=$n});$s.Add(@{Op='load';d=0;s=4;Offset=0});$s.Add(@{Op='and';d=0;s=0;t=6});$s.Add(@{Op='or';d=0;s=0;t=8});$s.Add(@{Op='store';s=4;t=0;Offset=0});$s.Add(@{Op='addi';d=4;s=4;i=4});$s.Add(@{Op='addi';d=5;s=5;i=-1});$s.Add(@{Op='gtu';d=0;s=5;t=7});$s.Add(@{Op='jump-p';u=0;Label=$n})
        }
    }
    & $dma 18 $reg.Signal.Offset $InputBase $InputOffset $layout.SignalBytes
    & $dma 18 $reg.Weights.Offset $WeightsBase $WeightsOffset 24576
    & $dma 18 $reg.Tables.Offset $TablesBase $TablesOffset 16384
    # har block 1 (channels 32..63) stays zero; block 0 is rewritten per batch.
    & $fill $reg.HarHigh.Offset ($batch*32) 0x80008000L; & $fill $reg.HarLow.Offset ($batch*32) 0
    $s.Add(@{Op='syncht'})
    for($startTile=0;$startTile -lt $tiles;$startTile+=$batch){
        $count=[math]::Min($batch,$tiles-$startTile)
        & $ptr 0 18 ($reg.Signal.Offset+320L*$startTile); & $ptr 1 18 ($reg.Window.Offset+4096); & $ptr 2 18 ($reg.WindowLow.Offset+4096); & $imm 3 ([math]::Ceiling($count/2))
        & $call 'body_stft_window'
        $s.Add(@{Op='syncht'})
        & $ptr 0 18 ($reg.Window.Offset+4096); & $ptr 1 18 ($reg.WindowLow.Offset+4096); & $ptr 2 18 $reg.Weights.Offset; & $ptr 3 18 $reg.Tables.Offset; & $imm 4 $count; & $ptr 5 18 $reg.Planes.Offset
        & $call 'body_conv_stft'
        $s.Add(@{Op='syncht'})
        & $ptr 0 18 $reg.Planes.Offset; & $ptr 1 18 $reg.Spectrum.Offset; & $ptr 2 18 ($reg.Tables.Offset+4096); & $imm 3 $count
        & $call 'body_combine_stft'
        $s.Add(@{Op='syncht'})
        & $ptr 0 18 $reg.Spectrum.Offset; & $ptr 1 18 $reg.HarHigh.Offset; & $ptr 2 18 $reg.HarLow.Offset; & $ptr 3 18 ($reg.Tables.Offset+8192); & $imm 4 $count
        & $call 'body_stft_polar'
        if($startTile+$count -eq $tiles){ & $padRows ($reg.HarHigh.Offset+($count-1)*4096L) 0x8000; & $padRows ($reg.HarLow.Offset+($count-1)*4096L) 0 }
        $s.Add(@{Op='syncht'})
        & $dma $HarBase ($HarOffset+4096L*$startTile) 18 $reg.HarHigh.Offset (4096L*$count)
        & $dma $HarBase ($HarOffset+4096L*$tiles+4096L*$startTile) 18 $reg.HarLow.Offset (4096L*$count)
    }
}

function Get-KokoroHarmonicStft16Bodies {
    param([Parameter(Mandatory)][long]$PlaneStride)
    @(
        @('body_stft_window',@(New-KokoroStftWindow16Steps)),
        @('body_conv_stft',@(New-KokoroHmxConvPlanesSteps -InputChannels 64 -OutputChannels 64 -Kernel 3 -Dilation 1 -WeightPlanes 2 -PlaneStride $PlaneStride -LabelPrefix 'h16stft')),
        @('body_combine_stft',@(New-KokoroPlaneCombineSteps -Mode Conv -Channels 64 -Groups 3 -Group3Shifts -PlaneStride $PlaneStride -LabelPrefix 'h16combine')),
        @('body_stft_polar',@(New-KokoroStftPolar16Steps)))
}

function New-KokoroHarmonicStft16RunSteps {
    param([ValidateRange(2,32768)][int]$Frames=7801,[ValidateRange(2,64)][int]$BatchTiles=16)
    . (Join-Path $PSScriptRoot 'Kokoro.ResBlockRun.ps1')
    foreach($file in 'Kokoro.HmxConvPlanes.ps1','Kokoro.PlaneCombine.ps1','Kokoro.StftWindow16.ps1','Kokoro.StftPolar16.ps1','Kokoro.DmaCopy.ps1') { . (Join-Path $PSScriptRoot $file) }
    $layout=Get-KokoroHarmonicStft16Layout -Frames $Frames -BatchTiles $BatchTiles
    $s=[Collections.Generic.List[hashtable]]::new()
    $calls=[Collections.Generic.List[object]]::new()
    $imm={param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL);$s.Add(@{Op='lo';x=$r;i=($u -band 65535)});$s.Add(@{Op='hi';x=$r;i=($u -shr 16)})}
    # Checked resource wrapper of the frozen K=11 resblock runner (as Kokoro.GeneratorTail16Run.ps1).
    $wrapperSource=New-KokoroResBlockRunSteps -Frames $Frames -Kernel 11
    $base=@($wrapperSource.Steps);$start=-1
    for($i=0;$i -lt $base.Count;$i++){if($base[$i].Op -eq 'label' -and $base[$i].Name -eq 'connected_job'){$start=$i;break}}
    if($start -lt 0){throw 'Connected wrapper anchor changed'}
    $minimum=@(4,$layout.InputBytes,$layout.WeightBytes,$layout.ParameterBytes,$layout.OutputBytes)
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
    Add-KokoroHarmonicStft16JobSteps -Steps $s -Calls $calls -Frames $Frames -BatchTiles $BatchTiles
    $s.Add(@{Op='hwticks';d=0});$s.Add(@{Op='store-d';s=23;t=26;Offset=0});$s.Add(@{Op='store-d';s=23;t=0;Offset=8})
    $s.Add(@{Op='imm';d=0;i=1});$s.Add(@{Op='store';s=23;t=0;Offset=44})
    foreach($r in 16,18,20,22,24,26){$s.Add(@{Op='load-d';d=$r;s=29;Offset=(($r-16)*4)})}
    $s.Add(@{Op='dealloc-return'})
    foreach($pair in (Get-KokoroHarmonicStft16Bodies -PlaneStride $layout.PlaneStride)){$s.Add(@{Op='label';Name=$pair[0]});foreach($step in $pair[1]){$s.Add($step)}}
    $labels=@{};$pcs=[Collections.Generic.Dictionary[object,long]]::new();$pc=0L;$isa=Get-InstructionSet
    foreach($step in $s){if($step.Op -eq 'label'){if($labels.ContainsKey($step.Name)){throw "Duplicate label $($step.Name)"};$labels[$step.Name]=$pc};$pcs[$step]=$pc;$pc+=& $isa.Length $step}
    foreach($c in $calls){$delta=[uint32](($labels[$c.label]-$pcs[$c.pc]) -band 0xffffffffL);$c.low.i=$delta -band 65535;$c.high.i=$delta -shr 16}
    [pscustomobject]@{Steps=$s.ToArray();Layout=[ordered]@{Frames=$Frames;Tiles=$layout.Tiles;InputBytes=$layout.InputBytes;WeightBytes=$layout.WeightBytes;ParameterBytes=$layout.ParameterBytes;OutputBytes=$layout.OutputBytes;VtcmBytes=$layout.VtcmBytes;Samples=1;PcmOffset=256;HarOffset=$layout.HarOffset;BatchTiles=$BatchTiles;Regions=$layout.Regions}}
}
