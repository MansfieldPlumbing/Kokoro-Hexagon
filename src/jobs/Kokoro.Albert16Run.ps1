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

# The whole of stock ALBERT + bert_encoder in one job, token ids -> d_en (Kokoro model.py forward_with_tokens:
# bert(input_ids) then bert_encoder). Every operator is one of the single-operator jobs above:
#   embed + LayerNorm(128) -> mapping_in (combine Scale: the stream H, one LSB per tensor)
#   12 x [ q, k, v (Conv) -> k and q rescaled -> attention -> dense (Residual into H) -> LayerNorm H -> A1
#          -> ffn (Scale into F, one LSB) -> gelu_new in place -> ffn_output (Residual into A1) -> LayerNorm A1 -> H ]
#   bert_encoder (Conv) -> D (512 wide, per-channel LSB).
# The shared layer's W8 weights, mapping_in, bert_encoder and the word rows are DMAed into VTCM once; each operator's
# tables are DMAed from DDR before it runs (Get-KokoroAlbert16Layout .Tables: name -> offset, bytes). One tile (T <= 32).
# Buffers: config, input (token ids padded to 128 B, then posType 128 wide), weights (layout .Weights order), tables
# (layout .Tables), output: D at 256, then the stream H after mapping_in and after each repeat (13 tensors, 768 wide).
function Get-KokoroAlbert16Layout {
    param([ValidateRange(1,32)][int]$Tokens=16,[ValidateRange(1,65536)][int]$Vocab=178)
    . (Join-Path $PSScriptRoot '../kernels/Kokoro.Attention16.ps1')
    $tiles=1; $tb={param([int]$c) 64L*$tiles*$c}; $a128={param([long]$v) [long]([math]::Ceiling($v/128)*128)}
    # Weights in weights.bin order (also their VTCM order): offset within the weight region.
    # Each tensor starts 4 KB aligned: an HMX :deep weight load reads one 2 KB block, and a block that is not 2 KB aligned can
    # straddle a VTCM page (SM8550: coprocessor VMEM address error, cause 0x26, when the word rows left every later tensor at
    # 0x400 mod 0x800 and ffn's blocks crossed the 4 MiB boundary). The weight region itself is 4 KB aligned.
    $weights=[ordered]@{}; $w=0L
    foreach($p in @(@('word',(512L*$Vocab)),@('mapping',(768L*128)),@('q',(768L*768)),@('k',(768L*768)),@('v',(768L*768)),@('dense',(768L*768)),@('ffn',(2048L*768)),@('ffn_output',(768L*2048)),@('bert_encoder',(512L*768)))){ $weights[$p[0]]=[ordered]@{Offset=$w;Bytes=$p[1]}; $w+=[long]([math]::Ceiling($p[1]/4096)*4096) }
    # Tables in tables.bin order.
    $lin={param([int]$cin,[int]$cout,[string]$mode) 256L*$cin/32 + 1024L*$cout/32 + $(if($mode -eq 'Conv'){0}else{128L*$cout/32}) }
    $ln={param([int]$c) & $a128 (256L*$c/32+8)}
    $records=[Collections.Generic.List[object]]::new()
    $records.Add(@('embed.ln','LayerNorm',128,128,'',(& $ln 128))); $records.Add(@('mapping','Linear',128,768,'Scale',(& $lin 128 768 'Scale')))
    for($r=0;$r -lt 12;$r++){
        foreach($n in 'q','k','v'){ $records.Add(@("$n.$r",'Linear',768,768,'Conv',(& $lin 768 768 'Conv'))) }
        $records.Add(@("attention.$r",'Attention',768,768,'',(2L*384*24+256+256L*$tiles)))
        $records.Add(@("dense.$r",'Linear',768,768,'Residual',(& $lin 768 768 'Residual')))
        $records.Add(@("ln_attention.$r",'LayerNorm',768,768,'',(& $ln 768)))
        $records.Add(@("ffn.$r",'Linear',768,2048,'Scale',(& $lin 768 2048 'Scale')))
        $records.Add(@("gelu.$r",'Gelu',2048,2048,'',640L))
        $records.Add(@("ffn_output.$r",'Linear',2048,768,'Residual',(& $lin 2048 768 'Residual')))
        $records.Add(@("ln_full.$r",'LayerNorm',768,768,'',(& $ln 768)))
    }
    $records.Add(@('bert_encoder','Linear',768,512,'Conv',(& $lin 768 512 'Conv')))
    $tables=[ordered]@{}; $t=0L
    foreach($rec in $records){ $tables[$rec[0]]=[ordered]@{Offset=$t;Bytes=(& $a128 $rec[5]);Kind=$rec[1];Cin=$rec[2];Cout=$rec[3];Mode=$rec[4]}; $t+=& $a128 $rec[5] }
    $stage=($tables.Values | ForEach-Object { $_.Bytes } | Measure-Object -Maximum).Maximum
    $scratch=Get-KokoroAttention16Scratch -Tokens $Tokens
    $planeStride=$tiles*64L*2048
    # VTCM: the HMX window regions first (each with its read extent inside one 1 MiB page), then the rest, 4 KB aligned.
    $regions=[ordered]@{}; $at=0L; $a4k={param([long]$v) [long]([math]::Ceiling($v/4096)*4096)}
    foreach($r in @(@('WinHi',(& $tb 2048)),@('WinLo',(& $tb 2048)),@('Planes',(4*$planeStride)),@('H',(& $tb 768)),@('A1',(& $tb 768)),@('Q',(& $tb 768)),@('K',(& $tb 768)),
        @('V',(& $tb 768)),@('Context',(& $tb 768)),@('F',(& $tb 2048)),@('E',(& $tb 128)),@('PosType',(& $tb 128)),@('Ids',128L),@('D',(& $tb 512)),@('Stage',$stage),
        @('LnScratch',1024L),@('AttentionScratch',$scratch.Bytes),@('Weights',$w))){ $regions[$r[0]]=[ordered]@{Offset=$at;Bytes=[long]$r[1]}; $at+=& $a4k $r[1] }
    # Weight tensors (HMX :deep sources) do not straddle a 4 MiB VTCM boundary (as Get-KokoroGeneratorTail16Layout keeps
    # its HMX sources inside one 4 MiB page): a tensor that would cross one starts at it. The region grows accordingly.
    $page4=4194304L; $base=$regions.Weights.Offset; $w=0L
    foreach($k in @($weights.Keys)){
        $start=$base+$w; $end=$start+$weights[$k].Bytes
        if($k -ne 'word' -and [math]::Floor($start/$page4) -ne [math]::Floor(($end-1)/$page4)){ $w=[long]([math]::Ceiling($start/$page4)*$page4)-$base }
        $weights[$k].Offset=$w; $w+=[long]([math]::Ceiling($weights[$k].Bytes/4096)*4096)
    }
    $regions.Weights.Bytes=$w; $at=$base+(& $a4k $w)
    if($regions.WinLo.Offset+$regions.WinLo.Bytes+64L*2048+2048 -gt 1048576){throw 'Window regions exceed the first 1 MiB VTCM page'}
    if($at -gt 8388608){throw "ALBERT job needs $at bytes of VTCM (8 MiB available)"}
    foreach($k in $weights.Keys){ if($k -ne 'word' -and ($regions.Weights.Offset+$weights[$k].Offset) % 2048){ throw "HMX weights '$k' are not 2 KB aligned in VTCM" } }
    $hBytes=& $tb 768
    [pscustomobject]@{Tokens=$Tokens;Vocab=$Vocab;Tiles=$tiles;IdBytes=128L;PosTypeBytes=(& $tb 128);InputBytes=(128L+(& $tb 128));Weights=$weights;WeightBytes=$w
        Tables=$tables;ParameterBytes=$t;PlaneStride=$planeStride;Regions=$regions;VtcmBytes=$at;OutputOffset=256L;DBytes=(& $tb 512);HBytes=$hBytes
        DumpOffset=(256L+(& $tb 512));OutputBytes=(256L+(& $tb 512)+13*$hBytes)}
}

# -StopAfter <table record> (embed.ln, mapping, q.0 .. ln_full.11, bert_encoder): the job ends after that operator and
# dumps the tensor it wrote into dump slot 1 (diagnosis, as the decoder's -StopAfterBlock).
function New-KokoroAlbert16RunSteps {
    param([ValidateRange(1,32)][int]$Tokens=16,[ValidateRange(1,65536)][int]$Vocab=178,[string]$StopAfter)
    foreach($file in '../kernels/Kokoro.HmxConvPlanes.ps1','../kernels/Kokoro.PlaneCombine.ps1','../kernels/Kokoro.AdaInLeaky16.ps1','../kernels/Kokoro.LayerNorm16.ps1',
        '../kernels/Kokoro.Gelu16.ps1','../kernels/Kokoro.Attention16.ps1','../kernels/Kokoro.Decoder16.ps1','../kernels/Kokoro.Embed16.ps1') { . (Join-Path $PSScriptRoot $file) }
    $L=Get-KokoroAlbert16Layout -Tokens $Tokens -Vocab $Vocab
    if($StopAfter -and -not $L.Tables.Contains($StopAfter)){throw "No operator '$StopAfter' in the ALBERT job"}
    $reg=$L.Regions; $tiles=$L.Tiles; $W=$reg.Weights.Offset
    $job={
        # After operator $name wrote region $region: at the stop point, dump that region (up to one stream tensor of bytes)
        # into dump slot 1; the remaining operators are not emitted.
        $stopped=$false
        $stop={param([string]$name,[string]$region) if($StopAfter -eq $name){ & $dma 23 ($L.DumpOffset+$L.HBytes) 18 $reg[$region].Offset ([math]::Min($reg[$region].Bytes,$L.HBytes)); $true } else { $false } }
        $stageTables={param([string]$name) $rec=$L.Tables[$name]; & $dma 18 $reg.Stage.Offset 22 $rec.Offset $rec.Bytes }
        $linear={param([string]$name,[string]$weight,[string]$x,[string]$y)
            $rec=$L.Tables[$name]; $cin=$rec.Cin; $cout=$rec.Cout; $identity=256L*$cin/32; $conv=1024L*$cout/32
            & $stageTables $name
            & $ptr 0 18 $reg[$x].Offset; & $ptr 1 18 $reg.WinHi.Offset; & $ptr 2 18 $reg.WinLo.Offset; & $ptr 3 18 $reg.Stage.Offset; & $imm 4 $tiles
            & $call "albert_identity_$cin"; & $sync
            & $ptr 0 18 $reg.WinHi.Offset; & $ptr 1 18 $reg.WinLo.Offset; & $ptr 2 18 ($W+$L.Weights[$weight].Offset); & $ptr 3 18 ($reg.Stage.Offset+$identity); & $imm 4 $tiles; & $ptr 5 18 $reg.Planes.Offset
            & $call "albert_conv_${cin}_$cout"; & $sync
            & $ptr 0 18 $reg.Planes.Offset; & $ptr 1 18 $reg[$y].Offset; & $ptr 2 18 ($reg.Stage.Offset+$identity+$conv); & $imm 3 $tiles
            & $call "albert_combine_$($rec.Mode.ToLower())_$cout"; & $sync }
        $layerNorm={param([string]$name,[string]$x,[string]$y)
            $rec=$L.Tables[$name]; & $stageTables $name
            & $ptr 0 18 $reg[$x].Offset; & $ptr 1 18 $reg[$y].Offset; & $ptr 2 18 $reg.Stage.Offset; & $ptr 3 18 $reg.LnScratch.Offset; & $imm 4 $tiles
            & $call "albert_layernorm_$($rec.Cin)"; & $sync }
        $dump={param([int]$index) & $dma 23 ($L.DumpOffset+$index*$L.HBytes) 18 $reg.H.Offset $L.HBytes }
        & $dma 18 $reg.Ids.Offset 20 0 $L.IdBytes
        & $dma 18 $reg.PosType.Offset 20 $L.IdBytes $L.PosTypeBytes
        & $dma 18 $W 21 0 $L.WeightBytes
        # Context rows past T are never written by the attention: the 16-bit zero, once.
        & $ptr 4 18 $reg.Context.Offset; & $imm 6 0x80008000L; $s.Add(@{Op='vsplat';d=0;s=6}); & $imm 5 ($reg.Context.Bytes/128); $s.Add(@{Op='imm';d=7;i=0})
        $s.Add(@{Op='label';Name='albert_fill'}); $s.Add(@{Op='vstore';s=4;t=0;Offset=0}); $s.Add(@{Op='addi';d=4;s=4;i=128})
        $s.Add(@{Op='addi';d=5;s=5;i=-1}); $s.Add(@{Op='gtu';d=0;s=5;t=7}); $s.Add(@{Op='jump-p';u=0;Label='albert_fill'})
        & $ptr 0 18 $reg.Ids.Offset; & $ptr 1 18 ($W+$L.Weights.word.Offset); & $ptr 2 18 $reg.PosType.Offset; & $ptr 3 18 $reg.E.Offset; & $imm 4 $Tokens
        & $call 'albert_embed'; & $sync
        # The operators in order: name, the region it writes, its steps.
        $ops=[Collections.Generic.List[object]]::new()
        $ops.Add(@('embed.ln','E',{ & $layerNorm 'embed.ln' 'E' 'E' }))
        $ops.Add(@('mapping','H',{ & $linear 'mapping' 'mapping' 'E' 'H'; & $dump 0 }))
        for($r=0;$r -lt 12;$r++){
            $ops.Add(@("q.$r",'Q',[scriptblock]::Create("& `$linear 'q.$r' 'q' 'H' 'Q'")))
            $ops.Add(@("k.$r",'K',[scriptblock]::Create("& `$linear 'k.$r' 'k' 'H' 'K'")))
            $ops.Add(@("v.$r",'V',[scriptblock]::Create("& `$linear 'v.$r' 'v' 'H' 'V'")))
            $ops.Add(@("attention.$r",'Context',[scriptblock]::Create(@"
& `$stageTables 'attention.$r'
& `$ptr 0 18 `$reg.Q.Offset; & `$ptr 1 18 `$reg.Stage.Offset; & `$imm 2 `$tiles; & `$call 'albert_qconvert'; & `$sync
& `$ptr 0 18 `$reg.K.Offset; & `$ptr 1 18 (`$reg.Stage.Offset+384L*24); & `$imm 2 `$tiles; & `$call 'albert_qconvert'; & `$sync
& `$ptr 0 18 `$reg.Q.Offset; & `$ptr 1 18 `$reg.K.Offset; & `$ptr 2 18 `$reg.V.Offset; & `$ptr 3 18 `$reg.Context.Offset
& `$ptr 4 18 (`$reg.Stage.Offset+2L*384*24); & `$ptr 5 18 `$reg.AttentionScratch.Offset; & `$call 'albert_attention'; & `$sync
"@)))
            $ops.Add(@("dense.$r",'H',[scriptblock]::Create("& `$linear 'dense.$r' 'dense' 'Context' 'H'")))
            $ops.Add(@("ln_attention.$r",'A1',[scriptblock]::Create("& `$layerNorm 'ln_attention.$r' 'H' 'A1'")))
            $ops.Add(@("ffn.$r",'F',[scriptblock]::Create("& `$linear 'ffn.$r' 'ffn' 'A1' 'F'")))
            $ops.Add(@("gelu.$r",'F',[scriptblock]::Create("& `$stageTables 'gelu.$r'; & `$ptr 0 18 `$reg.F.Offset; & `$ptr 1 18 `$reg.F.Offset; & `$ptr 2 18 `$reg.Stage.Offset; & `$imm 3 (`$reg.F.Bytes/128); & `$call 'albert_gelu'; & `$sync")))
            $ops.Add(@("ffn_output.$r",'A1',[scriptblock]::Create("& `$linear 'ffn_output.$r' 'ffn_output' 'F' 'A1'")))
            $ops.Add(@("ln_full.$r",'H',[scriptblock]::Create("& `$layerNorm 'ln_full.$r' 'A1' 'H'; & `$dump $($r+1)")))
        }
        $ops.Add(@('bert_encoder','D',{ & $linear 'bert_encoder' 'bert_encoder' 'H' 'D' }))
        foreach($op in $ops){ & $op[2]; if(& $stop $op[0] $op[1]){ $stopped=$true; break } }
        & $dma 23 $L.OutputOffset 18 $reg.D.Offset $L.DBytes
    }
    $ps=$L.PlaneStride
    $bodies=[Collections.Generic.List[object]]::new()
    foreach($c in 128,768,2048){ $bodies.Add(@("albert_identity_$c",@(New-KokoroAdaInLeaky16Steps -Channels $c -Output Windows -Identity -LabelPrefix "albident$c"))) }
    foreach($p in @(@(128,768),@(768,768),@(768,2048),@(2048,768),@(768,512))){ $bodies.Add(@("albert_conv_$($p[0])_$($p[1])",@(New-KokoroHmxConvPlanesLoopSteps -InputChannels $p[0] -OutputChannels $p[1] -Kernel 1 -WeightPlanes 1 -PlaneStride $ps -LabelPrefix "albconv$($p[0])x$($p[1])"))) }
    foreach($p in @(@('Conv',768),@('Conv',512),@('Scale',768),@('Scale',2048),@('Residual',768))){ $bodies.Add(@("albert_combine_$($p[0].ToLower())_$($p[1])",@(New-KokoroPlaneCombineLoopSteps -Mode $p[0] -Channels $p[1] -PlaneStride $ps -LabelPrefix "albcomb$($p[0].ToLower())$($p[1])"))) }
    foreach($c in 128,768){ $bodies.Add(@("albert_layernorm_$c",@(New-KokoroLayerNorm16Steps -Channels $c -LabelPrefix "albln$c"))) }
    $bodies.Add(@('albert_qconvert',@(New-KokoroScaleConvert16Steps -Channels 768 -LabelPrefix 'albqconv')))
    $bodies.Add(@('albert_attention',@(New-KokoroAttention16Steps -Tokens $Tokens -LabelPrefix 'albattn')))
    $bodies.Add(@('albert_gelu',@(New-KokoroGelu16Steps -LabelPrefix 'albgelu')))
    $bodies.Add(@('albert_embed',@(New-KokoroEmbed16Steps -Blocks 4 -Vocab $Vocab -Tokens $Tokens -LabelPrefix 'albembed')))
    $steps=New-KokoroWrappedJobSteps -Minimum @(4,$L.InputBytes,$L.WeightBytes,$L.ParameterBytes,$L.OutputBytes) -VtcmBytes $L.VtcmBytes -Tiles $tiles -Job $job -Bodies $bodies.ToArray()
    [pscustomobject]@{Steps=$steps;Layout=[ordered]@{Tokens=$Tokens;Vocab=$Vocab;Tiles=$tiles;InputBytes=$L.InputBytes;WeightBytes=$L.WeightBytes;ParameterBytes=$L.ParameterBytes
        OutputBytes=$L.OutputBytes;OutputOffset=$L.OutputOffset;PcmOffset=$L.OutputOffset;Samples=1;VtcmBytes=$L.VtcmBytes;DumpOffset=$L.DumpOffset;HBytes=$L.HBytes;DBytes=$L.DBytes}}
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
