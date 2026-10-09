#requires -Version 7.4
# One stock ALBERT nn.Linear at 16 bits on the DSP: a stored token tensor -> identity windows -> HMX conv (kernel 1)
# -> combine -> biased 16-bit output tensor. Kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec model.py (bert,
# bert_encoder); transformers modeling_albert.py AlbertLayer (query, key, value, dense, ffn, ffn_output). A linear over
# tokens is a kernel-1 Conv1d with tokens as frames, so it reuses the decoder's bodies unchanged:
#   New-KokoroAdaInLeaky16Steps -Identity (stored tensor -> conv-input windows, per-channel Q15 rescale),
#   New-KokoroHmxConvPlanesLoopSteps -Kernel 1 (W8, one weight plane), New-KokoroPlaneCombineLoopSteps -Mode Conv.
# Packing (weights, identity constants, conv tables): Invoke-KokoroHexagon.ps1 ConvertTo-KokoroConvPack.
#
# Method 2, five buffers: config (u32 tiles), input (biased u16 croutons, Cin wide, tiles of 32 tokens), weights
# (Cout * Cin bytes, HMX order), tables (identity constants 256 B per input block, then conv tables 1024 B per output
# block), output: [0] start ticks, [8] end ticks, [36] wrapper stage, [44] 1 when done, the output tensor (biased u16
# croutons, Cout wide) at 256.

function Get-KokoroAlbertLinear16Layout {
    param([ValidateRange(32,2048)][int]$InputChannels=768,[ValidateRange(64,2048)][int]$OutputChannels=768,[ValidateRange(1,512)][int]$Tokens=16)
    if($InputChannels % 32){throw 'Input channels must be whole 32-channel blocks'}
    if($OutputChannels % 64){throw 'Output channels must be whole 64-channel groups'}
    $tiles=[int][math]::Ceiling($Tokens/32); $ib=$InputChannels/32; $ob=$OutputChannels/32
    $al={param([long]$v) [long]([math]::Ceiling($v/65536)*65536)}
    $inBytes=$tiles*64L*$InputChannels; $outBytes=$tiles*64L*$OutputChannels; $planeStride=$tiles*$ob*2048L
    $identityBytes=256L*$ib; $tableBytes=$identityBytes+1024L*$ob; $weightBytes=[long]$OutputChannels*$InputChannels
    # HMX activation reads span a crouton plus the next tile: each window region keeps that extent inside one 1 MiB page
    # (as Get-KokoroDecoder16Layout).
    $page=1048576L; $slack=64L*$InputChannels+2048
    $regions=[ordered]@{}; $at=0L
    foreach($r in @(@('WinHi',$inBytes,$true),@('WinLo',$inBytes,$true),@('X',$inBytes,$false),@('Planes',(4*$planeStride),$false),@('Out',$outBytes,$false),@('Tables',$tableBytes,$false),@('Weights',$weightBytes,$false))){
        if($r[2] -and [math]::Floor($at/$page) -ne [math]::Floor(($at+$r[1]+$slack-1)/$page)){ $at=[long]([math]::Ceiling($at/$page)*$page) }
        if($r[2] -and [math]::Floor($at/$page) -ne [math]::Floor(($at+$r[1]+$slack-1)/$page)){ throw "$($r[0]) and its read extent exceed one 1 MiB VTCM page" }
        $regions[$r[0]]=[ordered]@{Offset=$at;Bytes=[long]$r[1]}; $at+=& $al $r[1]
    }
    if($at -gt 8388608){throw "ALBERT linear needs $at bytes of VTCM (8 MiB available)"}
    [pscustomobject]@{InputChannels=$InputChannels;OutputChannels=$OutputChannels;Tokens=$Tokens;Tiles=$tiles;PlaneStride=$planeStride
        InputBytes=$inBytes;WeightBytes=$weightBytes;ParameterBytes=$tableBytes;IdentityBytes=$identityBytes;OutputOffset=256L
        OutputBytes=(256L+$outBytes);VtcmBytes=$at;Regions=$regions}
}

function New-KokoroAlbertLinear16RunSteps {
    param([ValidateRange(32,2048)][int]$InputChannels=768,[ValidateRange(64,2048)][int]$OutputChannels=768,[ValidateRange(1,512)][int]$Tokens=16)
    . (Join-Path $PSScriptRoot 'Kokoro.ResBlockRun.ps1')
    foreach($file in '../kernels/Kokoro.HmxConvPlanes.ps1','../kernels/Kokoro.PlaneCombine.ps1','../kernels/Kokoro.AdaInLeaky16.ps1','../hexagon/Kokoro.DmaCopy.ps1') { . (Join-Path $PSScriptRoot $file) }
    $L=Get-KokoroAlbertLinear16Layout -InputChannels $InputChannels -OutputChannels $OutputChannels -Tokens $Tokens
    $reg=$L.Regions
    $s=[Collections.Generic.List[hashtable]]::new()
    $calls=[Collections.Generic.List[object]]::new()
    $imm={param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL);$s.Add(@{Op='lo';x=$r;i=($u -band 65535)});$s.Add(@{Op='hi';x=$r;i=($u -shr 16)})}

    # Checked resource wrapper of the frozen K=11 resblock runner (as Kokoro.GeneratorTail16Run.ps1): buffer admission
    # patched to this job's minimum lengths, the VTCM request and its check to this layout. The wrapper admits only the
    # config tile count it was built for (ceil(Frames / 32)), so it is built for this job's tiles.
    $wrapperSource=New-KokoroResBlockRunSteps -Frames ($L.Tiles*32) -Kernel 11
    $base=@($wrapperSource.Steps);$start=-1
    for($i=0;$i -lt $base.Count;$i++){if($base[$i].Op -eq 'label' -and $base[$i].Name -eq 'connected_job'){$start=$i;break}}
    if($start -lt 0){throw 'Connected wrapper anchor changed'}
    $minimum=@(4,$L.InputBytes,$L.WeightBytes,$L.ParameterBytes,$L.OutputBytes)
    $oldVtcm=[long]$wrapperSource.Layout.VtcmBytes; $patched=@{request=0;check=0}
    for($i=0;$i -lt $start;$i++){
        $step=$base[$i].Clone()
        if($step.Op -eq 'lo' -and $step.x -eq 1 -and $i -ge 2 -and $base[$i-1].Op -eq 'load' -and $base[$i-1].s -eq 3){$a=[int](($base[$i-1].Offset-4)/8);$v=$minimum[$a]-1;$step.i=$v -band 65535;$base[$i+1]=$base[$i+1].Clone();$base[$i+1].i=$v -shr 16}
        elseif($step.Op -eq 'lo' -and $i+1 -lt $start -and $base[$i+1].Op -eq 'hi' -and $base[$i+1].x -eq $step.x){
            $value=[long]$step.i -bor ([long]$base[$i+1].i -shl 16); $new=$null
            if($step.x -eq 1 -and $value -eq $oldVtcm){$new=$L.VtcmBytes;$patched.request++}
            elseif($step.x -eq 15 -and $value -eq $oldVtcm-1){$new=$L.VtcmBytes-1;$patched.check++}
            if($null -ne $new){$step.i=$new -band 65535;$base[$i+1]=$base[$i+1].Clone();$base[$i+1].i=$new -shr 16}
        }
        $s.Add($step)
    }
    if($patched.request -ne 1 -or $patched.check -ne 1){throw "VTCM size anchors changed ($($patched.request),$($patched.check))"}

    # Job. r18 VTCM, r20 input, r21 weights, r22 tables, r23 output, r24 DMA descriptors, r26:27 start ticks.
    $s.Add(@{Op='label';Name='connected_job'});$s.Add(@{Op='allocframe';Bytes=256})
    foreach($r in 16,18,20,22,24,26){$s.Add(@{Op='store-d';s=29;t=$r;Offset=(($r-16)*4)})}
    $s.Add(@{Op='addi';d=24;s=29;i=(64+63)}); & $imm 0 -64; $s.Add(@{Op='and';d=24;s=24;t=0})
    $s.Add(@{Op='hwticks';d=26})
    $ptr={param([int]$r,[int]$baseReg,[long]$offset) $offsetReg=if($r -eq $baseReg){15}else{$r}; & $imm $offsetReg $offset;$s.Add(@{Op='add';d=$r;s=$baseReg;t=$offsetReg}) }
    $call={param([string]$label) $pc=@{Op='add-pc';d=14;i=0};$lo=@{Op='lo';x=15;i=0};$hi=@{Op='hi';x=15;i=0};$s.Add($pc);$s.Add($lo);$s.Add($hi);$s.Add(@{Op='add';d=14;s=14;t=15});$s.Add(@{Op='callr';s=14});$calls.Add(@{pc=$pc;low=$lo;high=$hi;label=$label})}
    $sync={ $s.Add(@{Op='syncht'}) }
    $dma={param([int]$destBase,[long]$destOff,[int]$srcBase,[long]$srcOff,[long]$length)
        if($length -lt 2 -or $length -ge 2*16777215){throw 'DMA length out of range'}
        & $ptr 1 $srcBase $srcOff; & $ptr 2 $destBase $destOff; & $imm 3 $length; $s.Add(@{Op='addi';d=0;s=24;i=0})
        foreach($step in @(New-KokoroDmaCopySteps -NoReturn)){$s.Add($step)} }
    & $dma 18 $reg.X.Offset 20 0 $L.InputBytes
    & $dma 18 $reg.Weights.Offset 21 0 $L.WeightBytes
    & $dma 18 $reg.Tables.Offset 22 0 $L.ParameterBytes
    & $ptr 0 18 $reg.X.Offset; & $ptr 1 18 $reg.WinHi.Offset; & $ptr 2 18 $reg.WinLo.Offset; & $ptr 3 18 $reg.Tables.Offset; & $imm 4 $L.Tiles
    & $call 'albert_identity'; & $sync
    & $ptr 0 18 $reg.WinHi.Offset; & $ptr 1 18 $reg.WinLo.Offset; & $ptr 2 18 $reg.Weights.Offset; & $ptr 3 18 ($reg.Tables.Offset+$L.IdentityBytes); & $imm 4 $L.Tiles; & $ptr 5 18 $reg.Planes.Offset
    & $call 'albert_conv'; & $sync
    & $ptr 0 18 $reg.Planes.Offset; & $ptr 1 18 $reg.Out.Offset; & $ptr 2 18 $reg.Tables.Offset; & $imm 3 $L.Tiles
    & $call 'albert_combine'; & $sync
    & $dma 23 $L.OutputOffset 18 $reg.Out.Offset ($L.OutputBytes-$L.OutputOffset)
    $s.Add(@{Op='hwticks';d=0});$s.Add(@{Op='store-d';s=23;t=26;Offset=0});$s.Add(@{Op='store-d';s=23;t=0;Offset=8})
    $s.Add(@{Op='imm';d=0;i=1});$s.Add(@{Op='store';s=23;t=0;Offset=44})
    foreach($r in 16,18,20,22,24,26){$s.Add(@{Op='load-d';d=$r;s=29;Offset=(($r-16)*4)})}
    $s.Add(@{Op='dealloc-return'})

    $bodies=@(
        @('albert_identity',@(New-KokoroAdaInLeaky16Steps -Channels $InputChannels -Output Windows -Identity -LabelPrefix 'albident')),
        @('albert_conv',@(New-KokoroHmxConvPlanesLoopSteps -InputChannels $InputChannels -OutputChannels $OutputChannels -Kernel 1 -WeightPlanes 1 -PlaneStride $L.PlaneStride -LabelPrefix 'albconv')),
        @('albert_combine',@(New-KokoroPlaneCombineLoopSteps -Mode Conv -Channels $OutputChannels -PlaneStride $L.PlaneStride -LabelPrefix 'albcombine')))
    foreach($pair in $bodies){$s.Add(@{Op='label';Name=$pair[0]});foreach($step in $pair[1]){$s.Add($step)}}
    $labels=@{};$pcs=[Collections.Generic.Dictionary[object,long]]::new();$pc=0L;$isa=Get-InstructionSet
    foreach($step in $s){if($step.Op -eq 'label'){if($labels.ContainsKey($step.Name)){throw "Duplicate label $($step.Name)"};$labels[$step.Name]=$pc};$pcs[$step]=$pc;$pc+=& $isa.Length $step}
    foreach($c in $calls){$delta=[uint32](($labels[$c.label]-$pcs[$c.pc]) -band 0xffffffffL);$c.low.i=$delta -band 65535;$c.high.i=$delta -shr 16}
    # Runner contract (tools/Invoke-GeneratorTailProbe.ps1): Samples=1 marks a diagnostic job (no playback).
    [pscustomobject]@{Steps=$s.ToArray();Layout=[ordered]@{InputChannels=$InputChannels;OutputChannels=$OutputChannels;Tokens=$Tokens;Tiles=$L.Tiles
        InputBytes=$L.InputBytes;WeightBytes=$L.WeightBytes;ParameterBytes=$L.ParameterBytes;IdentityBytes=$L.IdentityBytes;OutputBytes=$L.OutputBytes
        OutputOffset=$L.OutputOffset;PcmOffset=$L.OutputOffset;Samples=1;VtcmBytes=$L.VtcmBytes;PlaneStride=$L.PlaneStride;Regions=$L.Regions}}
}
