#requires -Version 7.4
# Stock harmonic source and its STFT at 16 bits, from the frame-rate f0 to har (Kokoro.HarmonicSource16.ps1, then
# Kokoro.HarmonicStft16Run.ps1 on the signal written in VTCM). The integer contract: tools/New-KokoroHarmonicSource16Fixture.ps1.
# Method 2, five buffers: config (tiles), input (f0 as int32 Q16 Hz, L frames, padded to 128 bytes; then z = sum_h w_h g_h
# as Q12 halfwords, 64 per block), weights (STFT Wh, Wl), parameters (the STFT's 16384 B, then the source constants, 4096 B),
# output: [0] start ticks, [8] end ticks, [36] wrapper stage, [44] 1 when done; har high plane at 256 and low plane after it
# (tiles * 4096 B each), then the signal buffer (sample j at halfword 64 + j, Q15).

function Get-KokoroHarmonicSource16Layout {
    param([ValidateRange(2,32768)][int]$Frames=7801,[ValidateRange(2,64)][int]$BatchTiles=16)
    $stft=Get-KokoroHarmonicStft16Layout -Frames $Frames -BatchTiles $BatchTiles
    $samples=5*($Frames-1); if($samples%300){throw 'Samples are not 300 L'}
    $f0Frames=$samples/300; $blocks=[int][math]::Ceiling($samples/64); $hb=128L*$blocks
    $f0Bytes=[long]([math]::Ceiling(4*$f0Frames/128)*128)
    $al={param([long]$v) [long]([math]::Ceiling($v/65536)*65536)}
    $regions=[ordered]@{}; foreach($k in $stft.Regions.Keys){ $regions[$k]=$stft.Regions[$k] }; $at=[long]$stft.VtcmBytes
    foreach($r in @(@('PsiEven',$hb),@('PsiOdd',$hb),@('Masks',(3*$hb)),@('Noise',$hb),@('F0',$f0Bytes),@('SourceConstants',4096))){
        $regions[$r[0]]=[ordered]@{Offset=$at;Bytes=[long]$r[1]}; $at+=& $al $r[1]
    }
    $harBytes=2L*$stft.Tiles*4096
    [pscustomobject]@{Frames=$Frames;Tiles=$stft.Tiles;Samples=$samples;F0Frames=$f0Frames;Blocks=$blocks;HalfwordBytes=$hb;F0Bytes=$f0Bytes;Stft=$stft
        InputBytes=($f0Bytes+$hb);WeightBytes=$stft.WeightBytes;ParameterBytes=($stft.ParameterBytes+4096);Regions=$regions;VtcmBytes=$at
        HarOffset=256;SignalOutOffset=(256+$harBytes);OutputBytes=(256+$harBytes+$stft.SignalBytes)}
}

# The source job portion: f0, z and the source constants into VTCM, phase, voicing, merge, reflect, then the STFT portion on
# the signal in VTCM. Uses r0..r15 only; the caller provides r18 and r24. With -SignalOut the signal buffer also goes to
# SignalBase + SignalOffset.
function Add-KokoroHarmonicSource16JobSteps {
    param([Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[hashtable]]$Steps,[Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Calls,
        [ValidateRange(2,32768)][int]$Frames=7801,[ValidateRange(2,64)][int]$BatchTiles=16,
        [int]$InputBase=20,[long]$InputOffset=0,[int]$WeightsBase=21,[long]$WeightsOffset=0,[int]$TablesBase=22,[long]$TablesOffset=0,
        [int]$HarBase=23,[long]$HarOffset=256,[int]$SignalBase=-1,[long]$SignalOffset=0)
    $layout=Get-KokoroHarmonicSource16Layout -Frames $Frames -BatchTiles $BatchTiles
    $reg=$layout.Regions
    $s=$Steps; $calls=$Calls
    $imm={param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL);$s.Add(@{Op='lo';x=$r;i=($u -band 65535)});$s.Add(@{Op='hi';x=$r;i=($u -shr 16)})}
    $ptr={param([int]$r,[int]$baseReg,[long]$offset) $offsetReg=if($r -eq $baseReg){15}else{$r}; & $imm $offsetReg $offset;$s.Add(@{Op='add';d=$r;s=$baseReg;t=$offsetReg}) }
    $call={param([string]$label) $pc=@{Op='add-pc';d=14;i=0};$lo=@{Op='lo';x=15;i=0};$hi=@{Op='hi';x=15;i=0};$s.Add($pc);$s.Add($lo);$s.Add($hi);$s.Add(@{Op='add';d=14;s=14;t=15});$s.Add(@{Op='callr';s=14});$calls.Add(@{pc=$pc;low=$lo;high=$hi;label=$label})}
    $dma={param([int]$destBase,[long]$destOff,[int]$srcBase,[long]$srcOff,[long]$length)
        if($length -lt 2 -or $length -ge 2*16777215){throw 'DMA length out of range'}
        & $ptr 1 $srcBase $srcOff; & $ptr 2 $destBase $destOff; & $imm 3 $length; $s.Add(@{Op='addi';d=0;s=24;i=0})
        foreach($step in @(New-KokoroDmaCopySteps -NoReturn)){$s.Add($step)}
    }
    & $dma 18 $reg.F0.Offset $InputBase $InputOffset $layout.F0Bytes
    & $dma 18 $reg.Noise.Offset $InputBase ($InputOffset+$layout.F0Bytes) $layout.HalfwordBytes
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
    param([Parameter(Mandatory)][long]$PlaneStride)
    @(
        @('body_source_phase',@(New-KokoroSourcePhaseSteps)),
        @('body_source_voicing',@(New-KokoroSourceVoicingSteps)),
        @('body_source_merge',@(New-KokoroSourceMergeSteps)),
        @('body_source_reflect',@(New-KokoroSourceReflectSteps))) + @(Get-KokoroHarmonicStft16Bodies -PlaneStride $PlaneStride)
}

function New-KokoroHarmonicSource16RunSteps {
    param([ValidateRange(2,32768)][int]$Frames=7801,[ValidateRange(2,64)][int]$BatchTiles=16)
    . (Join-Path $PSScriptRoot 'Kokoro.ResBlockRun.ps1')
    foreach($file in '../kernels/Kokoro.HmxConvPlanes.ps1','../kernels/Kokoro.PlaneCombine.ps1','../kernels/Kokoro.StftWindow16.ps1','../kernels/Kokoro.StftPolar16.ps1','Kokoro.HarmonicStft16Run.ps1','../kernels/Kokoro.HarmonicSource16.ps1','../hexagon/Kokoro.DmaCopy.ps1') { . (Join-Path $PSScriptRoot $file) }
    $layout=Get-KokoroHarmonicSource16Layout -Frames $Frames -BatchTiles $BatchTiles
    $s=[Collections.Generic.List[hashtable]]::new()
    $calls=[Collections.Generic.List[object]]::new()
    $imm={param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL);$s.Add(@{Op='lo';x=$r;i=($u -band 65535)});$s.Add(@{Op='hi';x=$r;i=($u -shr 16)})}
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
    Add-KokoroHarmonicSource16JobSteps -Steps $s -Calls $calls -Frames $Frames -BatchTiles $BatchTiles -SignalBase 23 -SignalOffset $layout.SignalOutOffset
    $s.Add(@{Op='hwticks';d=0});$s.Add(@{Op='store-d';s=23;t=26;Offset=0});$s.Add(@{Op='store-d';s=23;t=0;Offset=8})
    $s.Add(@{Op='imm';d=0;i=1});$s.Add(@{Op='store';s=23;t=0;Offset=44})
    foreach($r in 16,18,20,22,24,26){$s.Add(@{Op='load-d';d=$r;s=29;Offset=(($r-16)*4)})}
    $s.Add(@{Op='dealloc-return'})
    foreach($pair in (Get-KokoroHarmonicSource16Bodies -PlaneStride $layout.Stft.PlaneStride)){$s.Add(@{Op='label';Name=$pair[0]});foreach($step in $pair[1]){$s.Add($step)}}
    $labels=@{};$pcs=[Collections.Generic.Dictionary[object,long]]::new();$pc=0L;$isa=Get-InstructionSet
    foreach($step in $s){if($step.Op -eq 'label'){if($labels.ContainsKey($step.Name)){throw "Duplicate label $($step.Name)"};$labels[$step.Name]=$pc};$pcs[$step]=$pc;$pc+=& $isa.Length $step}
    foreach($c in $calls){$delta=[uint32](($labels[$c.label]-$pcs[$c.pc]) -band 0xffffffffL);$c.low.i=$delta -band 65535;$c.high.i=$delta -shr 16}
    [pscustomobject]@{Steps=$s.ToArray();Layout=[ordered]@{Frames=$Frames;Tiles=$layout.Tiles;InputBytes=$layout.InputBytes;WeightBytes=$layout.WeightBytes;ParameterBytes=$layout.ParameterBytes;OutputBytes=$layout.OutputBytes;VtcmBytes=$layout.VtcmBytes;Samples=1;PcmOffset=256;HarOffset=$layout.HarOffset;SignalOutOffset=$layout.SignalOutOffset;BatchTiles=$BatchTiles;Regions=$layout.Regions}}
}
