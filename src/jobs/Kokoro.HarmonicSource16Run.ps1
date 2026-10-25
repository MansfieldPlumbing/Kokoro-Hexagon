#requires -Version 7.4
# Stock harmonic source and its STFT at 16 bits, from the frame-rate f0 to har (Kokoro.HarmonicSource16.ps1, then
# Kokoro.HarmonicStft16Run.ps1 on the signal written in VTCM). The integer contract: tools/New-KokoroHarmonicSource16Fixture.ps1.
# Method 2, five buffers: config (tiles), input (f0 as int32 Q16 Hz, L frames, padded to 128 bytes; then z = sum_h w_h g_h
# as Q12 halfwords, 64 per block), weights (STFT Wh, Wl), parameters (the STFT's 16384 B, then the source constants, 4096 B),
# output: [0] start ticks, [8] end ticks, [36] wrapper stage, [44] 1 when done; har high plane at 256 and low plane after it
# (tiles * 4096 B each), then the signal buffer (sample j at halfword 64 + j, Q15).

function Get-KokoroHarmonicSource16Layout {
    param([ValidateRange(2,1048576)][int]$Frames=7801,[ValidateRange(2,64)][int]$BatchTiles=16,
        # ChunkTiles > 0: the VTCM buffers hold one chunk of that many har tiles (see Add-KokoroHarmonicSource16JobSteps).
        [ValidateRange(0,4096)][int]$ChunkTiles=0)
    $stft=Get-KokoroHarmonicStft16Layout -Frames $Frames -BatchTiles $BatchTiles
    $samples=5*($Frames-1); if($samples%300){throw 'Samples are not 300 L'}
    $f0Frames=$samples/300; $blocks=[int][math]::Ceiling($samples/64); $hb=128L*$blocks
    $f0Bytes=[long]([math]::Ceiling(4*$f0Frames/128)*128)
    $al={param([long]$v) [long]([math]::Ceiling($v/65536)*65536)}
    $chunkHb=0L; $noiseBytes=$hb; $regionSource=$stft
    if($ChunkTiles){
        if($ChunkTiles%$BatchTiles){ throw 'ChunkTiles is a multiple of BatchTiles' }
        # A chunk's samples run from 64 before its first tile to 64 after its last (the windows' reach); the phase and
        # voicing arrays keep 320 samples of slack each side for the segments and frames that straddle the chunk's ends.
        $chunkHb=320L*$ChunkTiles+1536; $noiseBytes=320L*$ChunkTiles+256; $regionSource=Get-KokoroHarmonicStft16Layout -Frames (32*$ChunkTiles) -BatchTiles $BatchTiles
        $hb=$chunkHb
    }
    $regions=[ordered]@{}; foreach($k in $regionSource.Regions.Keys){ $regions[$k]=$regionSource.Regions[$k] }; $at=[long]$regionSource.VtcmBytes
    foreach($r in @(@('PsiEven',$hb),@('PsiOdd',$hb),@('Masks',(3*$hb)),@('Noise',$noiseBytes),@('F0',$f0Bytes),@('SourceConstants',4096),@('Carry',128))){
        if($r[0] -eq 'Carry' -and -not $ChunkTiles){ continue }
        $regions[$r[0]]=[ordered]@{Offset=$at;Bytes=[long]$r[1]}; $at+=& $al $r[1]
    }
    $harBytes=2L*$stft.Tiles*4096; $hb=128L*$blocks
    [pscustomobject]@{Frames=$Frames;Tiles=$stft.Tiles;Samples=$samples;F0Frames=$f0Frames;Blocks=$blocks;HalfwordBytes=$hb;F0Bytes=$f0Bytes;Stft=$stft;ChunkTiles=$ChunkTiles;ChunkHalfwordBytes=$chunkHb
        InputBytes=($f0Bytes+$hb);WeightBytes=$stft.WeightBytes;ParameterBytes=($stft.ParameterBytes+4096);Regions=$regions;VtcmBytes=$at
        HarOffset=256;SignalOutOffset=(256+$harBytes);OutputBytes=(256+$harBytes+$stft.SignalBytes)}
}

# The source job portion: f0, z and the source constants into VTCM, phase, voicing, merge, reflect, then the STFT portion on
# the signal in VTCM. Uses r0..r15 only; the caller provides r18 and r24. With -SignalOut the signal buffer also goes to
# SignalBase + SignalOffset.
function Add-KokoroHarmonicSource16JobSteps {
    param([Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[hashtable]]$Steps,[Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Calls,
        [ValidateRange(2,1048576)][int]$Frames=7801,[ValidateRange(2,64)][int]$BatchTiles=16,
        [int]$InputBase=20,[long]$InputOffset=0,[int]$WeightsBase=21,[long]$WeightsOffset=0,[int]$TablesBase=22,[long]$TablesOffset=0,
        [int]$HarBase=23,[long]$HarOffset=256,[int]$SignalBase=-1,[long]$SignalOffset=0,
        # -SeededNoise: the input holds the noise seed (uint32) and scale (int32) where z would be; the noise is generated on
        # the DSP (New-KokoroSourceNoiseSteps) into the same VTCM region, from sample 0.
        [switch]$SeededNoise,
        # ChunkTiles > 0: the source runs in chunks of that many har tiles, each from 64 samples before its first tile to
        # 64 after its last, so VTCM holds one chunk at any length. P_k crosses chunks in the Carry word; the bodies are
        # Get-KokoroHarmonicSource16Bodies -Chunked.
        [ValidateRange(0,4096)][int]$ChunkTiles=0)
    $layout=Get-KokoroHarmonicSource16Layout -Frames $Frames -BatchTiles $BatchTiles -ChunkTiles $ChunkTiles
    $reg=$layout.Regions
    $s=$Steps; $calls=$Calls
    $imm={param([int]$r,[long]$v) $u=[long]([uint32]($v -band 0xffffffffL));$s.Add(@{Op='lo';x=$r;i=($u -band 65535)});$s.Add(@{Op='hi';x=$r;i=($u -shr 16)})}
    $ptr={param([int]$r,[int]$baseReg,[long]$offset) $offsetReg=if($r -eq $baseReg){15}else{$r}; & $imm $offsetReg $offset;$s.Add(@{Op='add';d=$r;s=$baseReg;t=$offsetReg}) }
    $call={param([string]$label) $pc=@{Op='add-pc';d=14;i=0};$lo=@{Op='lo';x=15;i=0};$hi=@{Op='hi';x=15;i=0};$s.Add($pc);$s.Add($lo);$s.Add($hi);$s.Add(@{Op='add';d=14;s=14;t=15});$s.Add(@{Op='callr';s=14});$calls.Add(@{pc=$pc;low=$lo;high=$hi;label=$label})}
    $dma={param([int]$destBase,[long]$destOff,[int]$srcBase,[long]$srcOff,[long]$length)
        if($length -lt 2 -or $length -ge 2*16777215){throw 'DMA length out of range'}
        & $ptr 1 $srcBase $srcOff; & $ptr 2 $destBase $destOff; & $imm 3 $length; $s.Add(@{Op='addi';d=0;s=24;i=0})
        foreach($step in @(New-KokoroDmaCopySteps -NoReturn)){$s.Add($step)}
    }
    if($ChunkTiles){
        if($SignalBase -ge 0){ throw 'A chunked source keeps no whole signal to write out' }
        $stftArgs=@{Steps=$s;Calls=$calls;Frames=$Frames;BatchTiles=$BatchTiles;WeightsBase=$WeightsBase;WeightsOffset=$WeightsOffset;TablesBase=$TablesBase;TablesOffset=$TablesOffset;HarBase=$HarBase;HarOffset=$HarOffset;SignalInVtcm=$true;Regions=$reg}
        & $dma 18 $reg.F0.Offset $InputBase $InputOffset $layout.F0Bytes
        & $dma 18 $reg.SourceConstants.Offset $TablesBase ($TablesOffset+$layout.Stft.ParameterBytes) 4096
        Add-KokoroHarmonicStft16JobSteps @stftArgs -Setup Only
        $L=$layout.F0Frames; $samplesN=$layout.Samples; $tiles=$layout.Tiles; $chb=$layout.ChunkHalfwordBytes; $tailAt=300L*($L-1)+150
        $carry={param([string]$op) & $ptr 10 18 $reg.Carry.Offset; if($op -eq 'load'){ $s.Add(@{Op='load';d=9;s=10;Offset=0}) } else { $s.Add(@{Op='store';s=10;t=9;Offset=0}) } }
        # Phase arrays at sample j: base + 2 (j - B0); r2..r4 and r5, r6 for a phase piece starting at sample j.
        $phaseBases={param([long]$j) & $ptr 2 18 ($psiE+2*$j); & $ptr 3 18 ($psiO+2*$j); & $ptr 4 18 ($masks+2*$j); & $imm 5 $chb; & $ptr 6 18 $reg.SourceConstants.Offset }
        $carryK=-1
        for($t0=0;$t0 -lt $tiles;$t0+=$ChunkTiles){
            $t1=[math]::Min($tiles,$t0+$ChunkTiles); $last=$t1 -eq $tiles
            $m0=[math]::Max(0L,160L*$t0-64); $m1=[math]::Min(64L*$layout.Blocks,160L*$t1+64); $b0=$m0-320
            $psiE=$reg.PsiEven.Offset-2*$b0; $psiO=$reg.PsiOdd.Offset-2*$b0; $masks=$reg.Masks.Offset-2*$b0
            $signalAt=$reg.Signal.Offset-320L*$t0
            if($SeededNoise){
                & $ptr 5 $InputBase ($InputOffset+$layout.F0Bytes); $s.Add(@{Op='load';d=2;s=5;Offset=0}); $s.Add(@{Op='load';d=3;s=5;Offset=4})
                & $ptr 0 18 $reg.Noise.Offset; & $imm 1 ($m1-$m0); & $imm 4 $m0
                & $call 'body_source_noise'
            }
            else { & $dma 18 $reg.Noise.Offset $InputBase ($InputOffset+$layout.F0Bytes+2*$m0) (2*($m1-$m0)) }
            # Phase: the head, segments k (300 k + 150 .. 300 k + 449) that reach [m0, m1), the tail. Segments before the next
            # chunk's first are run first, so that the Carry holds that chunk's starting P.
            # $heldK: the k of the P left in r9 by the last phase piece.
            $heldK=-1
            if($m0 -lt 150){ & $ptr 0 18 $reg.F0.Offset; & $phaseBases 0; & $call 'body_source_phase_head'; & $carry 'store'; $carryK=0; $heldK=0 }
            $kA=if($m0 -lt 150){0}else{[int][math]::Floor(($m0-150)/300)}; $kB=if($m1-1 -lt 150){-1}else{[math]::Min($L-2,[int][math]::Floor(($m1-1-150)/300))}
            if($kB -ge $kA){
                if($carryK -ne $kA){ throw "Chunk at tile $t0 starts at segment $kA but the carry holds P_$carryK" }
                $kNext=if($last){$kB+1}else{[math]::Min($kB+1,[int][math]::Floor((160L*$t1-64-150)/300))}
                foreach($run in @(@($kA,$kNext),@($kNext,($kB+1)))){
                    if($run[1] -le $run[0]){ continue }
                    & $ptr 0 18 ($reg.F0.Offset+4L*$run[0]); & $imm 1 ($run[1]-$run[0]); & $phaseBases (300L*$run[0]+150); & $carry 'load'
                    & $call 'body_source_phase_segments'; $heldK=$run[1]
                    if($run[1] -eq $kNext){ & $carry 'store'; $carryK=$kNext }
                }
            }
            if($m1 -gt $tailAt){
                if($heldK -ne $L-1 -and $carryK -ne $L-1){ throw "The tail needs P_$($L-1) but the carry holds P_$carryK" }
                & $phaseBases $tailAt; if($heldK -ne $L-1){ & $carry 'load' }; & $call 'body_source_phase_tail'
            }
            $fA=[int][math]::Floor($m0/300); $fB=[math]::Min($L-1,[int][math]::Floor(($m1-1)/300))
            & $ptr 0 18 ($reg.F0.Offset+4L*$fA); & $imm 1 ($fB-$fA+1); & $ptr 4 18 ($masks+600L*$fA); & $imm 5 $chb; & $ptr 6 18 $reg.SourceConstants.Offset
            & $call 'body_source_voicing'
            $s.Add(@{Op='syncht'})
            & $ptr 0 18 ($psiE+2*$m0); & $ptr 1 18 ($psiO+2*$m0); & $ptr 2 18 ($masks+2*$m0); & $imm 3 $chb; & $ptr 4 18 $reg.Noise.Offset
            & $ptr 5 18 ($signalAt+2*(64+$m0)); & $ptr 6 18 $reg.SourceConstants.Offset; & $imm 7 (($m1-$m0)/64)
            & $call 'body_source_merge'
            $s.Add(@{Op='syncht'})
            if($t0 -eq 0){ & $ptr 0 18 $signalAt; & $call 'body_source_reflect_front' }
            if($last){ & $ptr 0 18 $signalAt; & $imm 1 $samplesN; & $call 'body_source_reflect_back' }
            $s.Add(@{Op='syncht'})
            Add-KokoroHarmonicStft16JobSteps @stftArgs -Setup Skip -FirstTile $t0 -EndTile $t1 -SignalOffset $signalAt
        }
        return
    }
    & $dma 18 $reg.F0.Offset $InputBase $InputOffset $layout.F0Bytes
    if($SeededNoise){
        & $ptr 5 $InputBase ($InputOffset+$layout.F0Bytes); $s.Add(@{Op='load';d=2;s=5;Offset=0}); $s.Add(@{Op='load';d=3;s=5;Offset=4})
        & $ptr 0 18 $reg.Noise.Offset; & $imm 1 ($layout.HalfwordBytes/2); $s.Add(@{Op='imm';d=4;i=0})
        & $call 'body_source_noise'
    }
    else { & $dma 18 $reg.Noise.Offset $InputBase ($InputOffset+$layout.F0Bytes) $layout.HalfwordBytes }
    & $dma 18 $reg.SourceConstants.Offset $TablesBase ($TablesOffset+$layout.Stft.ParameterBytes) 4096
    $s.Add(@{Op='syncht'})
    & $ptr 0 18 $reg.F0.Offset; & $imm 1 $layout.F0Frames; & $ptr 2 18 $reg.PsiEven.Offset; & $ptr 3 18 $reg.PsiOdd.Offset; & $ptr 4 18 $reg.Masks.Offset; & $imm 5 $layout.HalfwordBytes; & $ptr 6 18 $reg.SourceConstants.Offset
    & $call 'body_source_phase'
    & $ptr 0 18 $reg.F0.Offset; & $imm 1 $layout.F0Frames; & $ptr 4 18 $reg.Masks.Offset; & $imm 5 $layout.HalfwordBytes; & $ptr 6 18 $reg.SourceConstants.Offset
    & $call 'body_source_voicing'
    $s.Add(@{Op='syncht'})
    & $ptr 0 18 $reg.PsiEven.Offset; & $ptr 1 18 $reg.PsiOdd.Offset; & $ptr 2 18 $reg.Masks.Offset; & $imm 3 $layout.HalfwordBytes; & $ptr 4 18 $reg.Noise.Offset
    & $ptr 5 18 ($reg.Signal.Offset+128); & $ptr 6 18 $reg.SourceConstants.Offset; & $imm 7 $layout.Blocks
    & $call 'body_source_merge'
    $s.Add(@{Op='syncht'})
    & $ptr 0 18 $reg.Signal.Offset; & $imm 1 $layout.Samples
    & $call 'body_source_reflect'
    $s.Add(@{Op='syncht'})
    if($SignalBase -ge 0){ & $dma $SignalBase $SignalOffset 18 $reg.Signal.Offset $layout.Stft.SignalBytes }
    Add-KokoroHarmonicStft16JobSteps -Steps $s -Calls $calls -Frames $Frames -BatchTiles $BatchTiles -WeightsBase $WeightsBase -WeightsOffset $WeightsOffset -TablesBase $TablesBase -TablesOffset $TablesOffset -HarBase $HarBase -HarOffset $HarOffset -SignalInVtcm
}

function Get-KokoroHarmonicSource16Bodies {
    param([Parameter(Mandatory)][long]$PlaneStride,[switch]$SeededNoise,[switch]$Chunked)
    $noise=@(); if($SeededNoise){ $noise=@(,@('body_source_noise',@(New-KokoroSourceNoiseSteps))) }
    if($Chunked){
        foreach($part in 'Head','Segments','Tail'){ $noise+=@(,@("body_source_phase_$($part.ToLower())",@(New-KokoroSourcePhaseSteps -Part $part -LabelPrefix "sourcephase$($part.ToLower())"))) }
        foreach($end in 'Front','Back'){ $noise+=@(,@("body_source_reflect_$($end.ToLower())",@(New-KokoroSourceReflectSteps -Ends $end))) }
    }
    @(
        @('body_source_phase',@(New-KokoroSourcePhaseSteps)),
        @('body_source_voicing',@(New-KokoroSourceVoicingSteps)),
        @('body_source_merge',@(New-KokoroSourceMergeSteps)),
        @('body_source_reflect',@(New-KokoroSourceReflectSteps))) + $noise + @(Get-KokoroHarmonicStft16Bodies -PlaneStride $PlaneStride)
}

function New-KokoroHarmonicSource16RunSteps {
    param([ValidateRange(2,1048576)][int]$Frames=7801,[ValidateRange(2,64)][int]$BatchTiles=16,[switch]$SeededNoise)
    . (Join-Path $PSScriptRoot 'Kokoro.ResBlockRun.ps1')
    foreach($file in '../kernels/Kokoro.HmxConvPlanes.ps1','../kernels/Kokoro.PlaneCombine.ps1','../kernels/Kokoro.StftWindow16.ps1','../kernels/Kokoro.StftPolar16.ps1','Kokoro.HarmonicStft16Run.ps1','../kernels/Kokoro.HarmonicSource16.ps1','../hexagon/Kokoro.DmaCopy.ps1') { . (Join-Path $PSScriptRoot $file) }
    $layout=Get-KokoroHarmonicSource16Layout -Frames $Frames -BatchTiles $BatchTiles
    $s=[Collections.Generic.List[hashtable]]::new()
    $calls=[Collections.Generic.List[object]]::new()
    $imm={param([int]$r,[long]$v) $u=[long]([uint32]($v -band 0xffffffffL));$s.Add(@{Op='lo';x=$r;i=($u -band 65535)});$s.Add(@{Op='hi';x=$r;i=($u -shr 16)})}
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
    $s.Add(@{Op='label';Name='connected_job'});$s.Add(@{Op='allocframe';Bytes=256})
    foreach($r in 16,18,20,22,24,26){$s.Add(@{Op='store-d';s=29;t=$r;Offset=(($r-16)*4)})}
    $s.Add(@{Op='addi';d=24;s=29;i=(64+63)}); & $imm 0 -64; $s.Add(@{Op='and';d=24;s=24;t=0})
    $s.Add(@{Op='hwticks';d=26})
    Add-KokoroHarmonicSource16JobSteps -Steps $s -Calls $calls -Frames $Frames -BatchTiles $BatchTiles -SignalBase 23 -SignalOffset $layout.SignalOutOffset -SeededNoise:$SeededNoise
    $s.Add(@{Op='hwticks';d=0});$s.Add(@{Op='store-d';s=23;t=26;Offset=0});$s.Add(@{Op='store-d';s=23;t=0;Offset=8})
    $s.Add(@{Op='imm';d=0;i=1});$s.Add(@{Op='store';s=23;t=0;Offset=44})
    foreach($r in 16,18,20,22,24,26){$s.Add(@{Op='load-d';d=$r;s=29;Offset=(($r-16)*4)})}
    $s.Add(@{Op='dealloc-return'})
    foreach($pair in (Get-KokoroHarmonicSource16Bodies -PlaneStride $layout.Stft.PlaneStride -SeededNoise:$SeededNoise)){$s.Add(@{Op='label';Name=$pair[0]});foreach($step in $pair[1]){$s.Add($step)}}
    $labels=@{};$pcs=[Collections.Generic.Dictionary[object,long]]::new();$pc=0L;$isa=Get-InstructionSet
    foreach($step in $s){if($step.Op -eq 'label'){if($labels.ContainsKey($step.Name)){throw "Duplicate label $($step.Name)"};$labels[$step.Name]=$pc};$pcs[$step]=$pc;$pc+=& $isa.Length $step}
    foreach($c in $calls){$delta=[long]([uint32](($labels[$c.label]-$pcs[$c.pc]) -band 0xffffffffL));$c.low.i=$delta -band 65535;$c.high.i=$delta -shr 16}
    [pscustomobject]@{Steps=$s.ToArray();Layout=[ordered]@{Frames=$Frames;Tiles=$layout.Tiles;InputBytes=$layout.InputBytes;WeightBytes=$layout.WeightBytes;ParameterBytes=$layout.ParameterBytes;OutputBytes=$layout.OutputBytes;VtcmBytes=$layout.VtcmBytes;Samples=1;PcmOffset=256;HarOffset=$layout.HarOffset;SignalOutOffset=$layout.SignalOutOffset;BatchTiles=$BatchTiles;Regions=$layout.Regions}}
}
