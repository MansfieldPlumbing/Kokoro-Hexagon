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

# Attention: q and k rescaled per channel in place (New-KokoroScaleConvert16Steps, Kokoro.Decoder16.ps1): k to one LSB per head, q so q'_c k_c has one LSB
# per head, then New-KokoroAttention16Steps. Buffers: config, input (q, k, v: biased u16 croutons, 768 wide, one after
# another), weights (unused, >= 128 B), tables (q conversion 384 B per 32-channel block, then the attention constants),
# output: the context tensor at 256 (rows past T hold 0x8000). Tables: q conversion, k conversion (384 B per block each).
function Get-KokoroAlbertAttention16Layout {
    param([ValidateRange(1,512)][int]$Tokens=16)
    . (Join-Path $PSScriptRoot '../kernels/Kokoro.Attention16.ps1')
    $tiles=[int][math]::Ceiling($Tokens/32); $bytes=$tiles*64L*768; $convertBytes=2*384L*24; $constBytes=256L+256L*$tiles
    $scratch=Get-KokoroAttention16Scratch -Tokens $Tokens
    $al={param([long]$v) [long]([math]::Ceiling($v/65536)*65536)}
    $regions=[ordered]@{}; $at=0L
    foreach($r in @(@('Q',$bytes),@('K',$bytes),@('V',$bytes),@('Context',$bytes),@('Tables',($convertBytes+$constBytes)),@('Scratch',$scratch.Bytes))){ $regions[$r[0]]=[ordered]@{Offset=$at;Bytes=[long]$r[1]}; $at+=& $al $r[1] }
    if($at -gt 8388608){throw "ALBERT attention needs $at bytes of VTCM (8 MiB available)"}
    [pscustomobject]@{Tokens=$Tokens;Tiles=$tiles;TensorBytes=$bytes;InputBytes=(3*$bytes);WeightBytes=128L;ConvertBytes=$convertBytes;ConstantBytes=$constBytes
        ParameterBytes=($convertBytes+$constBytes);OutputOffset=256L;OutputBytes=(256L+$bytes);VtcmBytes=$at;Regions=$regions}
}

function New-KokoroAlbertAttention16RunSteps {
    param([ValidateRange(1,512)][int]$Tokens=16)
    foreach($file in '../kernels/Kokoro.Attention16.ps1','../kernels/Kokoro.Decoder16.ps1') { . (Join-Path $PSScriptRoot $file) }
    $L=Get-KokoroAlbertAttention16Layout -Tokens $Tokens
    $reg=$L.Regions
    $job={
        & $dma 18 $reg.Q.Offset 20 0 $L.TensorBytes
        & $dma 18 $reg.K.Offset 20 $L.TensorBytes $L.TensorBytes
        & $dma 18 $reg.V.Offset 20 (2*$L.TensorBytes) $L.TensorBytes
        & $dma 18 $reg.Tables.Offset 22 0 $L.ParameterBytes
        & $ptr 0 18 $reg.Q.Offset; & $ptr 1 18 $reg.Tables.Offset; & $imm 2 $L.Tiles
        & $call 'albert_qconvert'; & $sync
        & $ptr 0 18 $reg.K.Offset; & $ptr 1 18 ($reg.Tables.Offset+$L.ConvertBytes/2); & $imm 2 $L.Tiles
        & $call 'albert_qconvert'; & $sync
        # Context rows the attention does not write (past T) hold the 16-bit zero.
        & $ptr 4 18 $reg.Context.Offset; & $imm 6 0x80008000L; $s.Add(@{Op='vsplat';d=0;s=6}); & $imm 5 ($L.TensorBytes/128); $s.Add(@{Op='imm';d=7;i=0})
        $s.Add(@{Op='label';Name='albattn_fill'}); $s.Add(@{Op='vstore';s=4;t=0;Offset=0}); $s.Add(@{Op='addi';d=4;s=4;i=128})
        $s.Add(@{Op='addi';d=5;s=5;i=-1}); $s.Add(@{Op='gtu';d=0;s=5;t=7}); $s.Add(@{Op='jump-p';u=0;Label='albattn_fill'})
        & $ptr 0 18 $reg.Q.Offset; & $ptr 1 18 $reg.K.Offset; & $ptr 2 18 $reg.V.Offset; & $ptr 3 18 $reg.Context.Offset
        & $ptr 4 18 ($reg.Tables.Offset+$L.ConvertBytes); & $ptr 5 18 $reg.Scratch.Offset
        & $call 'albert_attention'; & $sync
        & $dma 23 $L.OutputOffset 18 $reg.Context.Offset $L.TensorBytes
    }
    $bodies=@(
        @('albert_qconvert',@(New-KokoroScaleConvert16Steps -Channels 768 -LabelPrefix 'albqconv')),
        @('albert_attention',@(New-KokoroAttention16Steps -Tokens $Tokens -LabelPrefix 'albattn')))
    $steps=New-KokoroWrappedJobSteps -Minimum @(4,$L.InputBytes,$L.WeightBytes,$L.ParameterBytes,$L.OutputBytes) -VtcmBytes $L.VtcmBytes -Tiles $L.Tiles -Job $job -Bodies $bodies
    [pscustomobject]@{Steps=$steps;Layout=[ordered]@{Tokens=$Tokens;Tiles=$L.Tiles;InputBytes=$L.InputBytes;WeightBytes=$L.WeightBytes;ParameterBytes=$L.ParameterBytes
        ConvertBytes=$L.ConvertBytes;OutputBytes=$L.OutputBytes;OutputOffset=$L.OutputOffset;PcmOffset=$L.OutputOffset;Samples=1;VtcmBytes=$L.VtcmBytes;Regions=$L.Regions}}
}

# Embeddings: New-KokoroEmbed16Steps (gather + position/type) then New-KokoroLayerNorm16Steps over 128 channels, in place.
# Buffers: config, input (token ids int32[T] padded to 128 B, then posType croutons 128 wide), weights (word rows,
# Vocab * 512 B), tables (LayerNorm constants for 128 channels), output: the embedding output (128 wide) at 256.
# Vocab = config n_token (lib/kokoro-v1_0.config.json: 178).
function Get-KokoroAlbertEmbed16Layout {
    param([ValidateRange(1,512)][int]$Tokens=16,[ValidateRange(1,65536)][int]$Vocab=178)
    $tiles=[int][math]::Ceiling($Tokens/32); $bytes=$tiles*64L*128; $idBytes=[long]([math]::Ceiling(4*$Tokens/128)*128)
    $tableBytes=[long]([math]::Ceiling((256L*4+8)/128)*128); $wordBytes=512L*$Vocab
    $al={param([long]$v) [long]([math]::Ceiling($v/65536)*65536)}
    $regions=[ordered]@{}; $at=0L
    foreach($r in @(@('Ids',$idBytes),@('PosType',$bytes),@('X',$bytes),@('Word',$wordBytes),@('Tables',$tableBytes),@('Scratch',1024L))){ $regions[$r[0]]=[ordered]@{Offset=$at;Bytes=[long]$r[1]}; $at+=& $al $r[1] }
    [pscustomobject]@{Tokens=$Tokens;Vocab=$Vocab;Tiles=$tiles;IdBytes=$idBytes;TensorBytes=$bytes;InputBytes=($idBytes+$bytes);WeightBytes=$wordBytes;ParameterBytes=$tableBytes
        OutputOffset=256L;OutputBytes=(256L+$bytes);VtcmBytes=$at;Regions=$regions}
}

function New-KokoroAlbertEmbed16RunSteps {
    param([ValidateRange(1,512)][int]$Tokens=16,[ValidateRange(1,65536)][int]$Vocab=178)
    foreach($file in '../kernels/Kokoro.Embed16.ps1','../kernels/Kokoro.LayerNorm16.ps1') { . (Join-Path $PSScriptRoot $file) }
    $L=Get-KokoroAlbertEmbed16Layout -Tokens $Tokens -Vocab $Vocab
    $reg=$L.Regions
    $job={
        & $dma 18 $reg.Ids.Offset 20 0 $L.IdBytes
        & $dma 18 $reg.PosType.Offset 20 $L.IdBytes $L.TensorBytes
        & $dma 18 $reg.Word.Offset 21 0 $L.WeightBytes
        & $dma 18 $reg.Tables.Offset 22 0 $L.ParameterBytes
        & $ptr 0 18 $reg.Ids.Offset; & $ptr 1 18 $reg.Word.Offset; & $ptr 2 18 $reg.PosType.Offset; & $ptr 3 18 $reg.X.Offset; & $imm 4 $Tokens
        & $call 'albert_embed'; & $sync
        & $ptr 0 18 $reg.X.Offset; & $ptr 1 18 $reg.X.Offset; & $ptr 2 18 $reg.Tables.Offset; & $ptr 3 18 $reg.Scratch.Offset; & $imm 4 $L.Tiles
        & $call 'albert_embed_layernorm'; & $sync
        & $dma 23 $L.OutputOffset 18 $reg.X.Offset $L.TensorBytes
    }
    $bodies=@(
        @('albert_embed',@(New-KokoroEmbed16Steps -Blocks 4 -Vocab $Vocab -Tokens $Tokens -LabelPrefix 'albembed')),
        @('albert_embed_layernorm',@(New-KokoroLayerNorm16Steps -Channels 128 -LabelPrefix 'albembln')))
    $steps=New-KokoroWrappedJobSteps -Minimum @(4,$L.InputBytes,$L.WeightBytes,$L.ParameterBytes,$L.OutputBytes) -VtcmBytes $L.VtcmBytes -Tiles $L.Tiles -Job $job -Bodies $bodies
    [pscustomobject]@{Steps=$steps;Layout=[ordered]@{Tokens=$Tokens;Vocab=$Vocab;Tiles=$L.Tiles;InputBytes=$L.InputBytes;WeightBytes=$L.WeightBytes;ParameterBytes=$L.ParameterBytes
        OutputBytes=$L.OutputBytes;OutputOffset=$L.OutputOffset;PcmOffset=$L.OutputOffset;Samples=1;VtcmBytes=$L.VtcmBytes;Regions=$L.Regions}}
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
