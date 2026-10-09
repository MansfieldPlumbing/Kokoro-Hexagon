#requires -Version 7.4
# Stock ALBERT operators at 16 bits on the DSP, one job per operator for checks against the stock capture. Kokoro
# dfb907a02bba8152ca444717ca5d78747ccb4bec model.py (bert, bert_encoder); transformers modeling_albert.py (AlbertLayer,
# AlbertEmbeddings). Each job runs inside New-KokoroWrappedJobSteps (Kokoro.WrappedJob.ps1). Host-side packing:
# Invoke-KokoroHexagon.ps1 (ConvertTo-KokoroConvPack, ConvertTo-KokoroLayerNormTable).
#
# Linear: one nn.Linear over tokens as a kernel-1 Conv1d with tokens as frames, reusing the decoder's bodies unchanged:
#   New-KokoroAdaInLeaky16Steps -Identity (stored tensor -> conv-input windows), New-KokoroHmxConvPlanesLoopSteps -Kernel 1
#   (W8, one weight plane), New-KokoroPlaneCombineLoopSteps -Mode Conv.
#   Buffers: config (u32 tiles), input (biased u16 croutons, Cin wide), weights (Cout * Cin bytes, HMX order), tables
#   (identity constants 256 B per input block, then conv tables 1024 B per output block), output: the tensor at 256.
# LayerNorm: New-KokoroLayerNorm16Steps over a stored tensor, in place.
#   Buffers: config, input (biased u16 croutons, C wide), weights (unused, >= 128 B), tables (Kokoro.LayerNorm16.ps1
#   constants: 256 B per 32-channel block, then epsD), output: the tensor at 256.
# Output buffer: [0] start ticks, [8] end ticks, [36] wrapper stage, [44] 1 when done, the tensor at 256.

. (Join-Path $PSScriptRoot 'Kokoro.WrappedJob.ps1')

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
    foreach($file in '../kernels/Kokoro.HmxConvPlanes.ps1','../kernels/Kokoro.PlaneCombine.ps1','../kernels/Kokoro.AdaInLeaky16.ps1') { . (Join-Path $PSScriptRoot $file) }
    $L=Get-KokoroAlbertLinear16Layout -InputChannels $InputChannels -OutputChannels $OutputChannels -Tokens $Tokens
    $reg=$L.Regions
    $job={
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
    }
    $bodies=@(
        @('albert_identity',@(New-KokoroAdaInLeaky16Steps -Channels $InputChannels -Output Windows -Identity -LabelPrefix 'albident')),
        @('albert_conv',@(New-KokoroHmxConvPlanesLoopSteps -InputChannels $InputChannels -OutputChannels $OutputChannels -Kernel 1 -WeightPlanes 1 -PlaneStride $L.PlaneStride -LabelPrefix 'albconv')),
        @('albert_combine',@(New-KokoroPlaneCombineLoopSteps -Mode Conv -Channels $OutputChannels -PlaneStride $L.PlaneStride -LabelPrefix 'albcombine')))
    $steps=New-KokoroWrappedJobSteps -Minimum @(4,$L.InputBytes,$L.WeightBytes,$L.ParameterBytes,$L.OutputBytes) -VtcmBytes $L.VtcmBytes -Tiles $L.Tiles -Job $job -Bodies $bodies
    # Runner contract (tools/Invoke-GeneratorTailProbe.ps1): Samples=1 marks a diagnostic job (no playback).
    [pscustomobject]@{Steps=$steps;Layout=[ordered]@{InputChannels=$InputChannels;OutputChannels=$OutputChannels;Tokens=$Tokens;Tiles=$L.Tiles
        InputBytes=$L.InputBytes;WeightBytes=$L.WeightBytes;ParameterBytes=$L.ParameterBytes;IdentityBytes=$L.IdentityBytes;OutputBytes=$L.OutputBytes
        OutputOffset=$L.OutputOffset;PcmOffset=$L.OutputOffset;Samples=1;VtcmBytes=$L.VtcmBytes;PlaneStride=$L.PlaneStride;Regions=$L.Regions}}
}

# Gelu: New-KokoroGelu16Steps over a stored tensor, in place. Buffers: config, input (biased u16 croutons, C wide), weights
# (unused, >= 128 B), tables (Kokoro.Gelu16.ps1 constants, 640 B), output: the tensor at 256.
function Get-KokoroAlbertGelu16Layout {
    param([ValidateRange(32,2048)][int]$Channels=2048,[ValidateRange(1,512)][int]$Tokens=16)
    if($Channels % 32){throw 'Channels must be whole 32-channel blocks'}
    $tiles=[int][math]::Ceiling($Tokens/32); $bytes=$tiles*64L*$Channels
    $al={param([long]$v) [long]([math]::Ceiling($v/65536)*65536)}
    $regions=[ordered]@{X=[ordered]@{Offset=0L;Bytes=$bytes};Tables=[ordered]@{Offset=(& $al $bytes);Bytes=640L}}
    [pscustomobject]@{Channels=$Channels;Tokens=$Tokens;Tiles=$tiles;Vectors=($bytes/128);InputBytes=$bytes;WeightBytes=128L;ParameterBytes=640L;OutputOffset=256L
        OutputBytes=(256L+$bytes);VtcmBytes=((& $al $bytes)+65536);Regions=$regions}
}

function New-KokoroAlbertGelu16RunSteps {
    param([ValidateRange(32,2048)][int]$Channels=2048,[ValidateRange(1,512)][int]$Tokens=16)
    . (Join-Path $PSScriptRoot '../kernels/Kokoro.Gelu16.ps1')
    $L=Get-KokoroAlbertGelu16Layout -Channels $Channels -Tokens $Tokens
    $reg=$L.Regions
    $job={
        & $dma 18 $reg.X.Offset 20 0 $L.InputBytes
        & $dma 18 $reg.Tables.Offset 22 0 $L.ParameterBytes
        & $ptr 0 18 $reg.X.Offset; & $ptr 1 18 $reg.X.Offset; & $ptr 2 18 $reg.Tables.Offset; & $imm 3 $L.Vectors
        & $call 'albert_gelu'; & $sync
        & $dma 23 $L.OutputOffset 18 $reg.X.Offset $L.InputBytes
    }
    $bodies=@(,@('albert_gelu',@(New-KokoroGelu16Steps -LabelPrefix 'albgelu')))
    $steps=New-KokoroWrappedJobSteps -Minimum @(4,$L.InputBytes,$L.WeightBytes,$L.ParameterBytes,$L.OutputBytes) -VtcmBytes $L.VtcmBytes -Tiles $L.Tiles -Job $job -Bodies $bodies
    [pscustomobject]@{Steps=$steps;Layout=[ordered]@{Channels=$Channels;Tokens=$Tokens;Tiles=$L.Tiles;InputBytes=$L.InputBytes;WeightBytes=$L.WeightBytes
        ParameterBytes=$L.ParameterBytes;OutputBytes=$L.OutputBytes;OutputOffset=$L.OutputOffset;PcmOffset=$L.OutputOffset;Samples=1;VtcmBytes=$L.VtcmBytes;Regions=$L.Regions}}
}

function Get-KokoroAlbertLayerNorm16Layout {
    param([ValidateRange(32,2048)][int]$Channels=768,[ValidateRange(1,512)][int]$Tokens=16)
    if($Channels % 32){throw 'Channels must be whole 32-channel blocks'}
    $tiles=[int][math]::Ceiling($Tokens/32)
    $al={param([long]$v) [long]([math]::Ceiling($v/65536)*65536)}
    $bytes=$tiles*64L*$Channels; $tableBytes=[long]([math]::Ceiling((256L*$Channels/32+8)/128)*128)
    $regions=[ordered]@{}; $at=0L
    foreach($r in @(@('X',$bytes),@('Tables',$tableBytes),@('Scratch',1024L))){ $regions[$r[0]]=[ordered]@{Offset=$at;Bytes=[long]$r[1]}; $at+=& $al $r[1] }
    [pscustomobject]@{Channels=$Channels;Tokens=$Tokens;Tiles=$tiles;InputBytes=$bytes;WeightBytes=128L;ParameterBytes=$tableBytes;OutputOffset=256L
        OutputBytes=(256L+$bytes);VtcmBytes=$at;Regions=$regions}
}

function New-KokoroAlbertLayerNorm16RunSteps {
    param([ValidateRange(32,2048)][int]$Channels=768,[ValidateRange(1,512)][int]$Tokens=16)
    . (Join-Path $PSScriptRoot '../kernels/Kokoro.LayerNorm16.ps1')
    $L=Get-KokoroAlbertLayerNorm16Layout -Channels $Channels -Tokens $Tokens
    $reg=$L.Regions
    $job={
        & $dma 18 $reg.X.Offset 20 0 $L.InputBytes
        & $dma 18 $reg.Tables.Offset 22 0 $L.ParameterBytes
        & $ptr 0 18 $reg.X.Offset; & $ptr 1 18 $reg.X.Offset; & $ptr 2 18 $reg.Tables.Offset; & $ptr 3 18 $reg.Scratch.Offset; & $imm 4 $L.Tiles
        & $call 'albert_layernorm'; & $sync
        & $dma 23 $L.OutputOffset 18 $reg.X.Offset $L.InputBytes
    }
    $bodies=@(,@('albert_layernorm',@(New-KokoroLayerNorm16Steps -Channels $Channels -LabelPrefix 'albln')))
    $steps=New-KokoroWrappedJobSteps -Minimum @(4,$L.InputBytes,$L.WeightBytes,$L.ParameterBytes,$L.OutputBytes) -VtcmBytes $L.VtcmBytes -Tiles $L.Tiles -Job $job -Bodies $bodies
    [pscustomobject]@{Steps=$steps;Layout=[ordered]@{Channels=$Channels;Tokens=$Tokens;Tiles=$L.Tiles;InputBytes=$L.InputBytes;WeightBytes=$L.WeightBytes
        ParameterBytes=$L.ParameterBytes;OutputBytes=$L.OutputBytes;OutputOffset=$L.OutputOffset;PcmOffset=$L.OutputOffset;Samples=1;VtcmBytes=$L.VtcmBytes;Regions=$L.Regions}}
}
