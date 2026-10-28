#requires -Version 7.4
# Stock Kokoro decoder front on the DSP at 16 bits: captured asr, F0_curve, N_curve -> the decoder
# output x (512 channels, 2F frames) that the generator takes. Source: hexgrad/kokoro
# dfb907a02bba8152ca444717ca5d78747ccb4bec istftnet.py AdaIN1d, AdainResBlk1d, Decoder.forward.
#
# Tensors are biased u16 native croutons (tile stride 64 * width). Block inputs are 1120 channels wide: the block's
# 1024 outputs at 0..1023, then asr_res (64), F0, N at 1024..1089, zero channels to 1119 (encode: asr 512, F0, N, zero to
# 543). Each block: shortcut conv1x1 on its raw input (per-channel input scales folded into the weights) into the output in
# Scale mode, AdaIN1 + LeakyReLU windows, conv1 -> C, AdaIN2 + LeakyReLU windows, conv2 added in Residual mode; the
# 1/sqrt(2) is in both ratios. decode.3: AdaIN1 + LeakyReLU to a tensor, the pool to windows at 2F frames, the shortcut at
# F frames then doubled. Weights are W8 per output channel (one plane), streamed per conv into one VTCM buffer.
# Rows past the frame count hold zero in every stored tensor and the conv-input zero in every window.
#
# -Delayed: every convolution reads only rows at or before the row it writes (kernel-3 convs TapDelay 1, 1x1 shortcuts
# TapDelay 2, the pool one row pair later), so each tensor lags its input by its layer's lookahead: frame f of a tensor at
# delay d is row f + d. Block inputs sit at 0, 2, 4, 6, 8 frames (asr_res, F0 and N are written into each block's output at
# the next block's delay), decode.3's pool windows at 18 ticks, and x at OutputDelayTicks (20). Rows before the delay hold
# zero as rows past it do. Tiles cover F + 10 frames and 2F + 20 ticks; the input stays at F frames (InputTiles).
#
# -Spans (with -Delayed): the job loops over Tiles spans; span s takes frame tile s (tick tiles 2s, 2s + 1) through every
# layer. Each tensor holds one span (frame tensors one tile, tick tensors two) after a lead tile, so VTCM does not grow
# with length. The rows a delayed convolution reads before its first output row (History: the last 1 to 4 row pairs of
# each 32-channel block of its input windows' last tile) are saved after each span and restored into the lead tile before
# the next; the pool's input keeps its last row pair in its lead tile.

function Get-KokoroDecoder16Layout {
    param([Parameter(Mandatory)][ValidateRange(2,4096)][int]$Frames,[switch]$Delayed,[switch]$Spans)
    if($Spans -and -not $Delayed){throw 'Spans run the delayed decoder (-Delayed)'}
    $F=$Frames; $lag=if($Delayed){10}else{0}; $T=[int][math]::Ceiling(($F+$lag)/32); $T2=[int][math]::Ceiling((2*$F+2*$lag)/32); $TI=[int][math]::Ceiling($F/32)
    $spanCount=$T; if($Spans){ $T=1; $T2=2 }
    $tb={param([int]$c) 64L*$c}
    $al={param([long]$v) [long]([math]::Ceiling($v/65536)*65536)}
    $planeStride=[long]([math]::Max($T*32,$T2*16))*2048
    # History entries (Spans): E's identity windows (asr_res reads up to 8 rows back), then per block its shortcut's
    # identity windows (blocks after encode), conv1's and conv2's windows; high plane then low plane, packed per block.
    $history=[ordered]@{}; $hAt=0L
    if($Spans){
        $entries=@(,@('E',544,4))
        foreach($j in 0..4){ $cin=if($j){1120}else{544}; $cout=if($j -eq 4){512}else{1024}
            if($j){ $entries+=,@("sc$j",$cin,1) }; $entries+=,@("w1_$j",$cin,1); $entries+=,@("w2_$j",$cout,1) }
        foreach($e in $entries){ $plane=128L*$e[2]*$e[1]/32; $history[$e[0]]=[ordered]@{Offset=$hAt;Width=$e[1];Vectors=$e[2];PlaneBytes=$plane}; $hAt+=2*$plane }
    }
    # HMX activation reads span a crouton plus the next tile; an extent that straddles a 2 MiB VTCM boundary faults in the
    # V73 simulator (exception 0x26). Regions HMX reads (windows, block inputs) keep
    # their bytes plus one 1120-wide tile and a crouton inside one 1 MiB page (faults seen crossing 0x100000 and 0x200000).
    # Regions HMX does not read fill the gaps.
    $small=[ordered]@{Moments=0L;Km=18432L;RatioA=27648L;RatioB=31744L;Tables=35840L;Records=68608L;Pool=104448L;Stride=122368L;Curves=122880L}
    $curveBytes=[long]([math]::Ceiling(8*$F/128)*128)
    # Counts (runtime frames): F, 2F, ceil(F/32), ceil(2F/32) as int32, after the curves; then the span index (Spans).
    $small['Counts']=$small.Curves+2*$curveBytes; $small['Span']=$small.Counts+16
    $page=1048576L; $slack=(& $tb 1120)+2048
    $regions=[ordered]@{}; $at=0L
    foreach($r in @(@('WinHi',((2*$T+2)*(& $tb 1120)),$true),@('C',([math]::Max($T*(& $tb 1024),$T2*(& $tb 512))),$false),@('S',($T*(& $tb 512)),$false),
        @('WinLo',((2*$T+2)*(& $tb 1120)),$true),@('A',(($T+$(if($Delayed){2}else{1}))*(& $tb 1120)),$false),@('XA',($T*(& $tb 1120)),$true),@('XB',($T*(& $tb 1120)),$true),
        @('E',($T*(& $tb 544)),$true),@('Small',0,$false),@('Planes',(4*$planeStride),$false),@('O',(2*$T*(& $tb 512)),$false),@('History',$hAt,$false))){
        if($r[0] -eq 'Small'){ $regions['Small']=[ordered]@{Offset=$at;Bytes=($small.Counts+128)}; $at+=& $al $regions.Small.Bytes; continue }
        if($r[0] -eq 'History' -and -not $Spans){ continue }
        if($r[2] -and [math]::Floor($at/$page) -ne [math]::Floor(($at+$r[1]+$slack-1)/$page)){ $at=[long]([math]::Ceiling($at/$page)*$page) }
        if($r[2] -and [math]::Floor($at/$page) -ne [math]::Floor(($at+$r[1]+$slack-1)/$page)){ throw "$($r[0]) and its read extent exceed one 2 MiB VTCM page" }
        $regions[$r[0]]=[ordered]@{Offset=$at;Bytes=[long]$r[1]}; $at+=& $al $r[1] }
    # Preserve the accepted placement for small inputs; larger static tensors
    # may move the streamed weights after the aligned activation extent.
    $weightAt=[math]::Max(4194304L,$at); $vtcm=$weightAt+3440640L
    if($vtcm -gt 8388608L){throw 'Decoder activations and streamed weights exceed the admitted 8 MiB of VTCM'}
    $regions['Weights']=[ordered]@{Offset=$weightAt;Bytes=3440640L}
    # Inputs: asr (512-wide croutons, T tiles), F0 curve and N curve (int32, 2F samples each, 128-byte padded).
    # Frames: the runtime frame count (int32), read only by a -RuntimeFrames job; Frames is then the capacity.
    $input=[ordered]@{Asr=0L;F0=($TI*32768L);N=($TI*32768L+$curveBytes);Frames=($TI*32768L+2*$curveBytes)}; $inputBytes=$TI*32768L+2*$curveBytes
    # Convs in run order: asr_res, then per block shortcut, conv1, conv2. Weights Cout * Cin * K bytes each.
    $blocks=@(@{Name='encode';Cin=544;Cout=1024;Wide=1120},@{Name='decode.0';Cin=1120;Cout=1024;Wide=1120},@{Name='decode.1';Cin=1120;Cout=1024;Wide=1120},
        @{Name='decode.2';Cin=1120;Cout=1024;Wide=1120},@{Name='decode.3';Cin=1120;Cout=512;Wide=512;Up=$true})
    $convs=[Collections.Generic.List[object]]::new(); $w=0L
    $list=@(,@('asr_res.0',544,64,1))
    foreach($b in $blocks){ foreach($c in @(@('conv1x1',$b.Cin,1),@('conv1',$b.Cin,3),@('conv2',$b.Cout,3))){ $list+=,@("$($b.Name).$($c[0])",$c[1],$b.Cout,$c[2]) } }
    foreach($c in $list){ $bytes=[long]$c[2]*$c[1]*$c[3]; $convs.Add([ordered]@{Name=$c[0];Cin=$c[1];Cout=$c[2];K=$c[3];Offset=$w;Bytes=$bytes}); $w+=$bytes }
    # Parameter records (tables.bin): asr_res tables; F0 and N stride constants; per block AdaIN1 records, conv1 tables, AdaIN2
    # records, conv2 tables, shortcut tables, shortcut ratios, conv2 ratios, decode.3 pool constants.
    $p=[ordered]@{AsrTables=0L;F0=2048L;N=2080L;IdentityE=2176L}; $pAt=6528L; $blockParams=[Collections.Generic.List[object]]::new()
    foreach($b in $blocks){
        $q=[ordered]@{}; $ob=$b.Cout/32
        if($b.Cin -eq 1120){ $q['IdentitySc']=$pAt; $pAt+=256L*$b.Cin/32 }
        foreach($e in @(@('Records1',(32L*$b.Cin)),@('Tables1',(1024L*$ob)),@('Records2',(32L*$b.Cout)),@('Tables2',(1024L*$ob)),@('TablesSc',(1024L*$ob)),@('RatioSc',(128L*$ob)),@('Ratio2',(128L*$ob)))){ $q[$e[0]]=$pAt; $pAt+=$e[1] }
        if($b.Up){ $q['Pool']=$pAt; $pAt+=512L*$b.Cin/32; $q['Convert']=$pAt; $pAt+=384L*$ob }
        $blockParams.Add($q)
    }
    # Normalization direction (2026-10-11): runtime synthesis computes and
    # supplies no AdaIN statistics. The front end emits scalar streams; each site's K and M are expanded from them through
    # the existing style projections and arrive through the direct-coefficient input. The
    # moments records below remain for stock-reference comparison and syllabus observation, staged for removal from the
    # runtime path; do not build new runtime work on them.
    # AdaIN moments records in run order (per block AdaIN1 over its input, AdaIN2 over conv1's output; decode.3's AdaIN2 runs
    # at 2F frames): the AdaInMoments16 record (S1, A2, AB, B2 int32 per channel, 16 bytes per channel). Exported after the
    # decoder output; supplied in the input after the runtime frame count, followed by one int32 frame count N per site.
    # Coefficients (Km: per 32-channel block K[32] at 0, M[32] at 128, int32; 8 bytes per channel) follow the same order:
    # exported after the moments records; a Corrected job adds per-site deltas in this layout, from the input after the counts.
    $sites=[Collections.Generic.List[object]]::new(); $mAt=0L; $kAt=0L
    foreach($b in $blocks){ foreach($e in @(@(1,$b.Cin,'F'),@(2,$b.Cout,$(if($b.Up){'F2'}else{'F'})))){
        $sites.Add([ordered]@{Index=$sites.Count;Name="$($b.Name).adain$($e[0])";Width=$e[1];Count=$e[2];Offset=$mAt;Bytes=16L*$e[1];KmOffset=$kAt;KmBytes=8L*$e[1]}); $mAt+=16L*$e[1]; $kAt+=8L*$e[1] } }
    $input['Moments']=$inputBytes+128; $input['MomentCounts']=$input.Moments+$mAt; $input['KmDeltas']=$input.MomentCounts+128
    [pscustomobject]@{Frames=$F;Tiles=$T;Tiles2=$T2;InputTiles=$TI;Delayed=[bool]$Delayed;Spans=[bool]$Spans;SpanCount=$(if($Spans){$spanCount}else{0});History=$history
        OutputDelayTicks=2*$lag;OutputTiles=2*$T;PlaneStride=$planeStride;Regions=$regions;Small=$small;CurveBytes=$curveBytes
        Input=$input;InputBytes=$inputBytes;RuntimeInputBytes=($inputBytes+128);SuppliedInputBytes=($input.MomentCounts+128);CorrectedInputBytes=($input.KmDeltas+$kAt);KmBytes=$kAt;Blocks=$blocks;Convs=$convs.ToArray();WeightBytes=$w;Params=$p;BlockParams=$blockParams.ToArray();ParameterBytes=$pAt
        MomentSites=$sites.ToArray();MomentsBytes=$mAt;OutputBytes=$(if($Spans){2L*$spanCount*32768}else{$T2*32768L});VtcmBytes=$vtcm
        ConstantsTableOffset=$pAt;ConstantsBytes=$mAt;ConstantsParameterBytes=($pAt+$mAt)}
}

# Appends the decoder job to Steps (registers as the generator jobs: r18 VTCM, r24 DMA descriptor slots). The decoder output
# (512-wide croutons, 2T tiles, rows past 2F zero) is DMAed to OutputBase + OutputOffset. -StopAfterBlock n (0 encode ..
# 3 decode.2) instead copies that block's output (1120-wide, T tiles) there.
function Add-KokoroDecoder16JobSteps {
    param([Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[hashtable]]$Steps,[Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Calls,
        [Parameter(Mandatory)][ValidateRange(2,4096)][int]$Frames,
        [int]$InputBase=20,[long]$InputOffset=0,[int]$WeightsBase=21,[long]$WeightsOffset=0,[int]$TablesBase=22,[long]$TablesOffset=0,
        [int]$OutputBase=23,[long]$OutputOffset=256,[ValidateRange(-1,4)][int]$StopAfterBlock=-1,
        # With -StopAfterBlock: Shortcut dumps the block's output region after the shortcut (Scale), Conv1 the conv1 output C
        # (1024-wide, F frames), instead of the block output.
        [ValidateSet('Block','Shortcut','Conv1','Windows1','Pool','Coeff')][string]$DumpPoint='Block',
        # The frame count is read at run time from the input buffer (Layout.Input.Frames, int32, clamped to 2 .. Frames);
        # Frames is the capacity the layout is sized for. Loop counts, pads and window edges follow the runtime count.
        [switch]$RuntimeFrames,
        # AdaIN statistics: Accumulate over this job's frames; Export also copies each site's record and then its coefficients
        # after the decoder output (OutputOffset + OutputBytes + site offset; + MomentsBytes + site KmOffset); Supplied loads
        # each site's record and frame count N from the input (Layout.Input.Moments, Layout.Input.MomentCounts) instead of
        # accumulating, so a chunk normalizes as the whole utterance; Corrected accumulates, then adds each site's Km delta
        # (Layout.Input.KmDeltas + site KmOffset, int32 wrapping) to its coefficients. SuppliedExport runs as Supplied and
        # also exports each site's local coefficients (from this job's own moments) where Export puts coefficients: the
        # supplied minus local difference is the exact Corrected delta on the supplied trajectory. Direct loads each site's
        # absolute coefficients from the KmDeltas region and computes no moments and no coefficients.
        [ValidateSet('Accumulate','Export','Supplied','SuppliedExport','Corrected','Direct','Constants')][string]$Moments='Accumulate',
        # Delayed tensors (Get-KokoroDecoder16Layout -Delayed); the output is x at Layout.OutputDelayTicks. -Spans runs them
        # one 32-frame span at a time through every layer (Get-KokoroDecoder16Layout -Spans).
        [switch]$Delayed,[switch]$Spans)
    if($RuntimeFrames -and $StopAfterBlock -ge 0){throw 'Dump points need a fixed frame count'}
    if($Moments -ne 'Accumulate' -and $StopAfterBlock -ge 0){throw 'Exported or supplied moments need the whole decoder'}
    if($Delayed -and $StopAfterBlock -ge 0){throw 'Dump points read undelayed tensors'}
    if($Delayed -and $Moments -notin 'Direct','Constants'){throw 'Delayed tensors take supplied coefficients (Direct or Constants)'}
    $L=Get-KokoroDecoder16Layout -Frames $Frames -Delayed:$Delayed -Spans:$Spans
    $F=$Frames; $nT=$L.Tiles; $nT2=$L.Tiles2; $reg=$L.Regions; $sm=$reg.Small.Offset; $small=$L.Small; $planes=$reg.Planes.Offset
    $s=$Steps; $callList=$Calls
    $imm={param([int]$r,[long]$v) $u=[long]([uint32]($v -band 0xffffffffL));$s.Add(@{Op='lo';x=$r;i=($u -band 65535)});$s.Add(@{Op='hi';x=$r;i=($u -shr 16)})}
    $ptr={param([int]$r,[int]$baseReg,[long]$offset) $offsetReg=if($r -eq $baseReg){15}else{$r}; & $imm $offsetReg $offset;$s.Add(@{Op='add';d=$r;s=$baseReg;t=$offsetReg}) }
    # Counts by name: F, F2 (2F), T (tiles of F), T2 (tiles of 2F); immediates, or loads from the VTCM counts at run time.
    $countValue=@{F=$F;F2=2*$F;T=$nT;T2=$nT2}; $countIndex=@{F=0;F2=1;T=2;T2=3}
    # Spans: T and T2 are the tiles of one span (1, 2), immediates also with run-time frames; the span count is Counts[2].
    $runtimeCount={param([string]$name) $RuntimeFrames -and -not ($Spans -and $name -in 'T','T2') }
    $cnt={param([int]$r,[string]$name) if(& $runtimeCount $name){ & $ptr $r 18 ($sm+$small.Counts); $s.Add(@{Op='load';d=$r;s=$r;Offset=4*$countIndex[$name]}) } else { & $imm $r $countValue[$name] } }
    # r = VTCM + offset + count * multiple (uses r6..r9 at run time).
    $ptrN={param([int]$r,[long]$offset,[string]$name,[long]$multiple)
        if(& $runtimeCount $name){ & $cnt 6 $name; & $imm 7 $multiple; $s.Add(@{Op='mpy-d';d=8;s=6;t=7}); & $imm 6 $offset; $s.Add(@{Op='add';d=8;s=8;t=6}); $s.Add(@{Op='add';d=$r;s=18;t=8}) }
        else { & $ptr $r 18 ($offset+$countValue[$name]*$multiple) } }
    $call={param([string]$label) $pc=@{Op='add-pc';d=14;i=0};$lo=@{Op='lo';x=15;i=0};$hi=@{Op='hi';x=15;i=0};$s.Add($pc);$s.Add($lo);$s.Add($hi);$s.Add(@{Op='add';d=14;s=14;t=15});$s.Add(@{Op='callr';s=14});$callList.Add(@{pc=$pc;low=$lo;high=$hi;label=$label})}
    $script:__d16=0
    $label={ $script:__d16++; "d16_$($script:__d16)" }
    $sync={ $s.Add(@{Op='syncht'}) }
    $dma={param([int]$destBase,[long]$destOff,[int]$srcBase,[long]$srcOff,[long]$length)
        if($length -lt 2 -or $length -ge 2*16777215){throw 'DMA length out of range'}
        & $ptr 1 $srcBase $srcOff; & $ptr 2 $destBase $destOff; & $imm 3 $length; $s.Add(@{Op='addi';d=0;s=24;i=0})
        foreach($step in @(New-KokoroDmaCopySteps -NoReturn)){$s.Add($step)} }
    $fillR4={param([long]$bytes,[long]$pattern)
        & $imm 6 $pattern; $s.Add(@{Op='vsplat';d=0;s=6}); & $imm 5 ($bytes/128); $s.Add(@{Op='imm';d=7;i=0})
        $n=& $label; $s.Add(@{Op='label';Name=$n});$s.Add(@{Op='vstore';s=4;t=0;Offset=0});$s.Add(@{Op='addi';d=4;s=4;i=128});$s.Add(@{Op='addi';d=5;s=5;i=-1});$s.Add(@{Op='gtu';d=0;s=5;t=7});$s.Add(@{Op='jump-p';u=0;Label=$n}) }
    $fill={param([long]$off,[long]$bytes,[long]$pattern) & $ptr 4 18 $off; & $fillR4 $bytes $pattern }
    # Spans: the span index (int32 in Small); r <- base + offset + (span << shift) (uses r6, r7); predicate jumps.
    $spanAt=$sm+$small.Span
    $loadSpan={param([int]$r) & $ptr $r 18 $spanAt; $s.Add(@{Op='load';d=$r;s=$r;Offset=0}) }
    $ptrSpan={param([int]$r,[int]$baseReg,[long]$offset,[int]$shift) & $loadSpan 6; $s.Add(@{Op='asl-i';d=6;s=6;i=$shift}); & $imm 7 $offset; $s.Add(@{Op='add';d=6;s=6;t=7}); $s.Add(@{Op='add';d=$r;s=$baseReg;t=6}) }
    $jumpIfSpan={param([string]$test,[string]$target) & $loadSpan 6; $s.Add(@{Op='imm';d=7;i=0}); $s.Add(@{Op=$test;d=0;s=6;t=7}); $s.Add(@{Op='jump-p';u=0;Label=$target}) }
    $jump={param([string]$target) $s.Add(@{Op='eq';d=0;s=15;t=15}); $s.Add(@{Op='jump-p';u=0;Label=$target}) }
    $dmaSpan={param([int]$destBase,[long]$destOff,[int]$destShift,[int]$srcBase,[long]$srcOff,[int]$srcShift,[long]$length)
        if($srcShift -ge 0){ & $ptrSpan 1 $srcBase $srcOff $srcShift } else { & $ptr 1 $srcBase $srcOff }
        if($destShift -ge 0){ & $ptrSpan 2 $destBase $destOff $destShift } else { & $ptr 2 $destBase $destOff }
        & $imm 3 $length; $s.Add(@{Op='addi';d=0;s=24;i=0}); foreach($step in @(New-KokoroDmaCopySteps -NoReturn)){$s.Add($step)} }
    $padUsed=[Collections.Generic.HashSet[string]]::new()
    # A stored tensor's pad: rows past the count, or with -Delayed rows outside [delay, count + delay) ($padDelayed below).
    $padAt={param([long]$off,[string]$fr,[int]$width,[int]$halfword,[int]$delay,[string]$tiles) if($Delayed){ & $padDelayed $off $fr $width $halfword $delay $tiles } else { & $pad $off $fr $width $halfword } }
    # Rows past the frame count (F or F2) of the tensor at off <- the halfword.
    $pad={param([long]$off,[string]$fr,[int]$width,[int]$halfword)
        & $ptr 0 18 $off
        if($RuntimeFrames){ & $cnt 5 $fr; & $call "dec_padrt_${width}_$halfword"; [void]$padUsed.Add("rt,$width,$halfword") }
        else { $v=$countValue[$fr]; & $call "dec_pad_${v}_${width}_$halfword"; [void]$padUsed.Add("$v,$width,$halfword") } }
    # Delayed: rows before the tensor's delay (static, tile 0) and rows from count + delay through the tile count.
    $leadUsed=[Collections.Generic.HashSet[string]]::new(); $capacityUsed=[Collections.Generic.HashSet[string]]::new()
    $padDelayed={param([long]$off,[string]$fr,[int]$width,[int]$halfword,[int]$delay,[string]$tiles)
        if($Spans){
            # Lead rows in span 0 only; rows from count + delay - 32k * span (clamped to 0 .. 32k) through the span's k tiles.
            if($delay -gt 0){ $skipLead=& $label; & $jumpIfSpan 'gtu' $skipLead; & $ptr 0 18 $off; & $call "dec_lead_${delay}_${width}_$halfword"; [void]$leadUsed.Add("$delay,$width,$halfword"); $s.Add(@{Op='label';Name=$skipLead}) }
            $k=$countValue[$tiles]
            & $loadSpan 6; $s.Add(@{Op='asl-i';d=6;s=6;i=(4+$k)}); if($RuntimeFrames){ & $cnt 5 $fr; $s.Add(@{Op='addi';d=5;s=5;i=$delay}) } else { & $imm 5 ($countValue[$fr]+$delay) }; $s.Add(@{Op='sub';d=5;s=5;t=6})
            $s.Add(@{Op='imm';d=7;i=0}); $s.Add(@{Op='max';d=5;s=5;t=7}); $s.Add(@{Op='imm';d=7;i=(32*$k)}); $s.Add(@{Op='min';d=5;s=5;t=7}); $s.Add(@{Op='imm';d=6;i=$k})
            & $ptr 0 18 $off; & $call "dec_padcap_${width}_$halfword"; [void]$capacityUsed.Add("$width,$halfword"); return
        }
        if($delay -gt 0){ & $ptr 0 18 $off; & $call "dec_lead_${delay}_${width}_$halfword"; [void]$leadUsed.Add("$delay,$width,$halfword") }
        & $ptr 0 18 $off; & $cnt 5 $fr; if($delay -gt 0){ $s.Add(@{Op='addi';d=5;s=5;i=$delay}) }; & $cnt 6 $tiles
        & $call "dec_padcap_${width}_$halfword"; [void]$capacityUsed.Add("$width,$halfword") }
    $tbw={param([int]$c) 64L*$c}
    $convUsed=[Collections.Generic.HashSet[string]]::new()
    $conv={param([long]$hi,[long]$lo,[int]$cin,[int]$cout,[int]$k,[string]$tiles,[int]$delay=0)
        $name=if($Delayed){"dec_conv_${cin}_${cout}_${k}_$delay"}else{"dec_conv_${cin}_${cout}_$k"}; [void]$convUsed.Add("$cin,$cout,$k,$delay")
        & $ptr 0 18 $hi; & $ptr 1 18 $lo; & $ptr 2 18 $reg.Weights.Offset; & $ptr 3 18 ($sm+$small.Tables); & $cnt 4 $tiles; & $ptr 5 18 $planes; & $call $name; & $sync }
    $combine={param([string]$mode,[int]$cout,[long]$out,[long]$ratio,[string]$tiles,[long]$skip) & $ptr 0 18 $planes; & $ptr 1 18 $out; & $ptr 2 18 $ratio; & $cnt 3 $tiles; & $call "dec_combine_$($mode.ToLower())_${cout}_$skip"; [void]$combines.Add("$mode,$cout,$skip"); & $sync }
    $siteIndex=[ref]0
    $adain={param([long]$x,[int]$width,[string]$fr,[string]$tiles,[long]$records,[string]$output,[long]$hi,[long]$lo)
        $site=$L.MomentSites[$siteIndex.Value]; $siteIndex.Value++
        if($site.Width -ne $width -or $site.Count -ne $fr){throw "AdaIN site $($site.Name) does not match the run order"}
        $local=$Moments -notin 'Supplied','Direct'; $supplied=$Moments -in 'Supplied','SuppliedExport'
        if($Moments -eq 'Direct'){
            # The site's coefficients from the input (the KmDeltas region holds absolute Km): no moments, no derivation.
            & $dma 18 ($sm+$small.Km) $InputBase ($InputOffset+$L.Input.KmDeltas+$site.KmOffset) $site.KmBytes
            & $ptr 0 18 $x; & $ptr 1 18 $hi; & $ptr 2 18 $lo; & $ptr 3 18 ($sm+$small.Km); & $cnt 4 $tiles; & $call "dec_leaky_$($output.ToLower())_$width"; & $sync
            return
        }
        if($Moments -eq 'Constants'){
            & $dma 18 ($sm+$small.Moments) $TablesBase ($TablesOffset+$L.ConstantsTableOffset+$site.Offset) $site.Bytes
            & $dma 18 ($sm+$small.Records) $TablesBase ($TablesOffset+$records) (32L*$width)
            & $ptr 0 18 ($sm+$small.Moments); & $ptr 1 18 ($sm+$small.Records); & $ptr 2 18 ($sm+$small.Km)
            & $call "dec_constants_$width"
            & $ptr 0 18 $x; & $ptr 1 18 $hi; & $ptr 2 18 $lo; & $ptr 3 18 ($sm+$small.Km); & $cnt 4 $tiles; & $call "dec_leaky_$($output.ToLower())_$width"; & $sync
            return
        }
        if($local){
            & $fill ($sm+$small.Moments) (16L*$width) 0
            & $ptr 0 18 $x; & $ptr 1 18 ($sm+$small.Moments); & $cnt 2 $tiles; & $call "dec_moments_$width"; & $sync
            if($Moments -eq 'Export'){ & $dma $OutputBase ($OutputOffset+$L.OutputBytes+$site.Offset) 18 ($sm+$small.Moments) $site.Bytes }
        }
        & $dma 18 ($sm+$small.Records) $TablesBase ($TablesOffset+$records) (32L*$width)
        if($local){
            & $ptr 0 18 ($sm+$small.Moments); & $ptr 1 18 ($sm+$small.Records); & $ptr 2 18 ($sm+$small.Km); & $cnt 3 $fr; & $call "dec_coeff_$width"
            if($Moments -in 'Export','SuppliedExport'){ & $dma $OutputBase ($OutputOffset+$L.OutputBytes+$L.MomentsBytes+$site.KmOffset) 18 ($sm+$small.Km) $site.KmBytes }
        }
        if($supplied){
            & $dma 18 ($sm+$small.Moments) $InputBase ($InputOffset+$L.Input.Moments+$site.Offset) $site.Bytes
            & $ptr 0 18 ($sm+$small.Moments); & $ptr 1 18 ($sm+$small.Records); & $ptr 2 18 ($sm+$small.Km)
            & $ptr 3 $InputBase ($InputOffset+$L.Input.MomentCounts+4L*$site.Index); $s.Add(@{Op='load';d=3;s=3;Offset=0})
            & $call "dec_coeff_$width"
        }
        if($Moments -eq 'Corrected'){
            # Km += delta, the delta staged in the moments area (no longer read for this site).
            & $dma 18 ($sm+$small.Moments) $InputBase ($InputOffset+$L.Input.KmDeltas+$site.KmOffset) $site.KmBytes
            & $ptr 4 18 ($sm+$small.Km); & $ptr 5 18 ($sm+$small.Moments); & $imm 6 ($site.KmBytes/128); $s.Add(@{Op='imm';d=7;i=0})
            $n=& $label; $s.Add(@{Op='label';Name=$n})
            $s.Add(@{Op='vload';d=0;s=4;Offset=0}); $s.Add(@{Op='vload';d=1;s=5;Offset=0}); $s.Add(@{Op='vadd-w';d=0;s=0;t=1}); $s.Add(@{Op='vstore';s=4;t=0;Offset=0})
            $s.Add(@{Op='addi';d=4;s=4;i=128}); $s.Add(@{Op='addi';d=5;s=5;i=128}); $s.Add(@{Op='addi';d=6;s=6;i=-1}); $s.Add(@{Op='gtu';d=0;s=6;t=7}); $s.Add(@{Op='jump-p';u=0;Label=$n})
        }
        & $ptr 0 18 $x; & $ptr 1 18 $hi; & $ptr 2 18 $lo; & $ptr 3 18 ($sm+$small.Km); & $cnt 4 $tiles; & $call "dec_leaky_$($output.ToLower())_$width"; & $sync }
    $windowsFix={param([int]$width,[string]$fr,[string]$tiles,[int]$delay=0)
        $w=& $tbw $width
        & $fill $reg.WinHi.Offset $w 0x80008000L; & $fill $reg.WinLo.Offset $w 0
        & $ptrN 4 ($reg.WinHi.Offset+$w) $tiles $w; & $fillR4 $w 0x80008000L; & $ptrN 4 ($reg.WinLo.Offset+$w) $tiles $w; & $fillR4 $w 0
        if($Delayed){ & $padDelayed ($reg.WinHi.Offset+$w) $fr $width 0x8000 $delay $tiles; & $padDelayed ($reg.WinLo.Offset+$w) $fr $width 0 $delay $tiles }
        else {
        & $pad ($reg.WinHi.Offset+$w) $fr $width 0x8000
        & $pad ($reg.WinLo.Offset+$w) $fr $width 0
        }
        & $sync }
    $weights={param([int]$index) $c=$L.Convs[$index]; & $dma 18 $reg.Weights.Offset $WeightsBase ($WeightsOffset+$c.Offset) $c.Bytes }
    # Spans: restore a conv input's history into its windows' lead tile (spans after the first), then save the tail of the
    # windows' last tile (-NoSave: a later use in this span saves it).
    $tailUsed=[Collections.Generic.HashSet[string]]::new()
    $history={param([string]$name,[int]$curTiles,[switch]$NoSave)
        $e=$L.History[$name]; $w=& $tbw $e.Width; $v=$e.Vectors; $at=$reg.History.Offset+$e.Offset
        $planesAt=@(@($reg.WinHi.Offset,$at),@($reg.WinLo.Offset,($at+$e.PlaneBytes)))
        $skip=& $label; & $jumpIfSpan 'eq' $skip
        foreach($pl in $planesAt){ & $ptr 0 18 $pl[1]; & $ptr 1 18 $pl[0]; & $call "dec_tailrestore_$($e.Width)_$v" }
        $s.Add(@{Op='label';Name=$skip}); [void]$tailUsed.Add("Packed,Tile,$($e.Width),$v")
        if(-not $NoSave){ foreach($pl in $planesAt){ & $ptr 0 18 ($pl[0]+$curTiles*$w); & $ptr 1 18 $pl[1]; & $call "dec_tailsave_$($e.Width)_$v" }; [void]$tailUsed.Add("Tile,Packed,$($e.Width),$v") }
        & $sync }

    # Inputs: asr into E (544 wide), F0 and N through their stride-2 convs into E (512, 513) and both wide tensors (1088, 1089).
    if($RuntimeFrames){
        # Frame count from the input, clamped to 2 .. capacity; then F, 2F, ceil(F/32), ceil(2F/32) into the VTCM counts.
        & $ptr 0 $InputBase ($InputOffset+$L.Input.Frames); $s.Add(@{Op='load';d=1;s=0;Offset=0})
        & $imm 2 $F; $s.Add(@{Op='min';d=1;s=1;t=2}); $s.Add(@{Op='imm';d=2;i=2}); $s.Add(@{Op='max';d=1;s=1;t=2})
        & $ptr 3 18 ($sm+$small.Counts); $s.Add(@{Op='store';s=3;t=1;Offset=0})
        $s.Add(@{Op='add';d=2;s=1;t=1}); $s.Add(@{Op='store';s=3;t=2;Offset=4})
        $lag=if($Delayed){10}else{0}
        $s.Add(@{Op='addi';d=4;s=1;i=(31+$lag)}); $s.Add(@{Op='lsr-i';d=4;s=4;i=5}); $s.Add(@{Op='store';s=3;t=4;Offset=8})
        $s.Add(@{Op='addi';d=4;s=2;i=(31+2*$lag)}); $s.Add(@{Op='lsr-i';d=4;s=4;i=5}); $s.Add(@{Op='store';s=3;t=4;Offset=12})
        # Spans: the input's tiles, ceil(F/32), after the span index.
        if($Spans){ $s.Add(@{Op='addi';d=4;s=1;i=31}); $s.Add(@{Op='lsr-i';d=4;s=4;i=5}); $s.Add(@{Op='store';s=3;t=4;Offset=20}) }
    }
    foreach($region in 'E','XA','XB'){ & $fill $reg[$region].Offset $reg[$region].Bytes 0x80008000L }
    # Runtime: the output copies capacity tiles; tiles past the runtime count hold zero.
    if($RuntimeFrames){ & $fill $reg.O.Offset $reg.O.Bytes 0x80008000L }
    $asrDone=& $label
    # Delayed: every input tile (the input holds zero past the runtime frame count); E's tiles past them stay zero.
    # Spans: one input tile per span, in the loop.
    $inputTiles=if($Spans){0}elseif($Delayed){$L.InputTiles}else{$nT}
    for($t=0;$t -lt $inputTiles;$t++){
        # Runtime: tile t only while t < T.
        if($RuntimeFrames -and -not $Delayed -and $t -gt 0){ & $cnt 0 'T'; & $imm 1 ($t+1); $s.Add(@{Op='gtu';d=0;s=1;t=0}); $s.Add(@{Op='jump-p';u=0;Label=$asrDone}) }
        & $dma 18 ($reg.E.Offset+$t*(& $tbw 544)) $InputBase ($InputOffset+$L.Input.Asr+$t*32768L) 32768 }
    if($RuntimeFrames -and -not $Delayed){ $s.Add(@{Op='label';Name=$asrDone}) }
    & $dma 18 ($sm+$small.Curves) $InputBase ($InputOffset+$L.Input.F0) (2*$L.CurveBytes)
    & $dma 18 ($sm+$small.Stride) $TablesBase ($TablesOffset+$L.Params.F0) 128
    $stride=[Collections.Generic.HashSet[string]]::new()
    # F0 and N into one tensor's channels at a delay (the stride constants and curves stay in Small).
    $strideInto={param([long]$off,[int]$width,[int]$channel,[int]$curve,[int]$delay)
        if($Spans){
            # Frames t with t + delay in this span's tile: span 0 from row delay, frame 0; span s from row 0, frame 32s - delay.
            $first=& $label; $done=& $label; $at=$off+[long][math]::Floor($channel/32)*2048+4*($channel%32); $curveAt=$sm+$small.Curves+$curve*$L.CurveBytes
            & $jumpIfSpan 'eq' $first
            & $loadSpan 4; $s.Add(@{Op='asl-i';d=6;s=4;i=5}); $s.Add(@{Op='addi';d=6;s=6;i=-$delay})
            & $cnt 11 'F'; $s.Add(@{Op='sub';d=11;s=11;t=6}); $s.Add(@{Op='imm';d=5;i=0}); $s.Add(@{Op='max';d=11;s=11;t=5}); $s.Add(@{Op='imm';d=5;i=32}); $s.Add(@{Op='min';d=11;s=11;t=5})
            $s.Add(@{Op='imm';d=5;i=0}); $s.Add(@{Op='eq';d=0;s=11;t=5}); $s.Add(@{Op='jump-p';u=0;Label=$done})
            $s.Add(@{Op='asl-i';d=7;s=6;i=3}); & $ptr 0 18 $curveAt; $s.Add(@{Op='add';d=0;s=0;t=7}); $s.Add(@{Op='load';d=3;s=0;Offset=-4})
            & $ptr 1 18 $at; $s.Add(@{Op='imm';d=10;i=32}); & $ptr 2 18 ($sm+$small.Stride+32*$curve); & $call "dec_stridespan_$width"; & $jump $done
            $s.Add(@{Op='label';Name=$first})
            & $ptr 0 18 $curveAt; $s.Add(@{Op='imm';d=3;i=0}); & $ptr 1 18 ($at+128*[math]::Floor($delay/2)+2*($delay%2)); $s.Add(@{Op='imm';d=10;i=(32-$delay)})
            if($RuntimeFrames){ & $cnt 11 'F'; $s.Add(@{Op='imm';d=5;i=(32-$delay)}); $s.Add(@{Op='min';d=11;s=11;t=5}) } else { $s.Add(@{Op='imm';d=11;i=[math]::Min($F,32-$delay)}) }; & $ptr 2 18 ($sm+$small.Stride+32*$curve); & $call "dec_stridespan_$width"
            $s.Add(@{Op='label';Name=$done}); [void]$stride.Add("span,$width"); return
        }
        & $ptr 0 18 ($sm+$small.Curves+$curve*$L.CurveBytes); & $ptr 1 18 $off; & $ptr 2 18 ($sm+$small.Stride+32*$curve)
        if($RuntimeFrames){ & $cnt 11 'F' }
        if($Delayed){ & $call "dec_stride_${width}_${channel}_$delay"; [void]$stride.Add("$width,$channel,$delay") }
        else { & $call "dec_stride_${width}_$channel"; [void]$stride.Add("$width,$channel") } }
    $combines=[Collections.Generic.HashSet[string]]::new()
    $identityE={param([long]$hi,[long]$lo)
        & $dma 18 ($sm+$small.Km) $TablesBase ($TablesOffset+$L.Params.IdentityE) 4352
        & $ptr 0 18 $reg.E.Offset; & $ptr 1 18 $hi; & $ptr 2 18 $lo; & $ptr 3 18 ($sm+$small.Km); & $cnt 4 'T'; & $call 'dec_identity_544'; & $sync }
    $spanTop=& $label
    if($Spans){
        # The pool's input lead tile (a[-1] = 0) and channels nothing writes hold zero from here on; span 0.
        & $fill $reg.A.Offset $reg.A.Bytes 0x80008000L
        $s.Add(@{Op='imm';d=6;i=0}); & $ptr 7 18 $spanAt; $s.Add(@{Op='store';s=7;t=6;Offset=0})
        $s.Add(@{Op='label';Name=$spanTop})
        # E <- input tile span (tiles past the input hold zero).
        $eFill=& $label; $eDone=& $label
        & $loadSpan 6
        if($RuntimeFrames){ & $ptr 7 18 ($sm+$small.Counts); $s.Add(@{Op='load';d=7;s=7;Offset=20}); $s.Add(@{Op='addi';d=7;s=7;i=-1}) } else { & $imm 7 ($L.InputTiles-1) }
        $s.Add(@{Op='gtu';d=0;s=6;t=7}); $s.Add(@{Op='jump-p';u=0;Label=$eFill})
        & $dmaSpan 18 $reg.E.Offset -1 $InputBase ($InputOffset+$L.Input.Asr) 15 32768; & $jump $eDone
        $s.Add(@{Op='label';Name=$eFill}); & $fill $reg.E.Offset $reg.E.Bytes 0x80008000L
        $s.Add(@{Op='label';Name=$eDone})
    }
    if($Delayed){
        & $strideInto $reg.E.Offset 544 512 0 0; & $strideInto $reg.E.Offset 544 513 1 0
    } else {
    foreach($target in @(@('E',544,512,0),@('E',544,513,1),@('XA',1120,1088,0),@('XA',1120,1089,1),@('XB',1120,1088,0),@('XB',1120,1089,1))){
        & $strideInto $reg[$target[0]].Offset $target[1] $target[2] $target[3] 0 }
    # asr_res: conv1x1 over E (zero weights past 512) into channels 1024..1087 of both wide tensors (Conv mode).
    # asr_res and the encode shortcut read E rescaled into one conv-input scale (identity windows; the weights fold that scale).
    & $identityE $reg.WinHi.Offset $reg.WinLo.Offset
    & $weights 0; & $dma 18 ($sm+$small.Tables) $TablesBase ($TablesOffset+$L.Params.AsrTables) 2048
    & $conv $reg.WinHi.Offset $reg.WinLo.Offset 544 64 1 'T'
    foreach($x in 'XA','XB'){ & $combine 'Conv' 64 ($reg[$x].Offset+32*2048) 0 'T' ((1120-64)*64) }
    }

    $src='E'; $dst='XA'; $ci=1
    for($j=0;$j -lt 5;$j++){
        $b=$L.Blocks[$j]; $q=$L.BlockParams[$j]; $cin=$b.Cin; $cout=$b.Cout; $ob=$cout/32; $inW=& $tbw $cin
        $xOff=$reg[$src].Offset
        $outOff=if($b.Up){$reg.S.Offset}else{$reg[$dst].Offset}; $skip=if($b.Up){0L}else{[long](1120-$cout)*64}
        # Delayed: the block's input at 2j frames, its output (and its conv windows' lead tile at +width, so a delayed tap
        # reads the zero tile before row 0). asr_res and F0, N go into the output at the next block's delay first; the
        # encode shortcut then reads the identity windows of E that asr_res left.
        $d=2*$j; $shortcutAt=if($Delayed){$inW}else{0L}
        if($Delayed -and -not $b.Up){
            & $identityE ($reg.WinHi.Offset+(& $tbw 544)) ($reg.WinLo.Offset+(& $tbw 544))
            if($Spans){ & $history 'E' 1 -NoSave:($j -ne 3) }
            & $weights 0; & $dma 18 ($sm+$small.Tables) $TablesBase ($TablesOffset+$L.Params.AsrTables) 2048
            & $conv ($reg.WinHi.Offset+(& $tbw 544)) ($reg.WinLo.Offset+(& $tbw 544)) 544 64 1 'T' ($d+2)
            & $combine 'Conv' 64 ($reg[$dst].Offset+32*2048) 0 'T' ((1120-64)*64)
            & $strideInto $reg[$dst].Offset 1120 1088 0 ($d+2); & $strideInto $reg[$dst].Offset 1120 1089 1 ($d+2)
        }
        # Shortcut (F frames) into the output (decode.3: into S, doubled later).
        # The shortcut reads its input rescaled into one conv-input scale (encode: E's windows from asr_res are still there).
        if($j -gt 0){
            & $dma 18 ($sm+$small.Km) $TablesBase ($TablesOffset+$q.IdentitySc) (256L*$cin/32)
            & $ptr 0 18 $xOff; & $ptr 1 18 ($reg.WinHi.Offset+$shortcutAt); & $ptr 2 18 ($reg.WinLo.Offset+$shortcutAt); & $ptr 3 18 ($sm+$small.Km); & $cnt 4 'T'; & $call "dec_identity_$cin"; & $sync
            if($Spans){ & $history "sc$j" 1 }
        }
        & $weights $ci; & $dma 18 ($sm+$small.Tables) $TablesBase ($TablesOffset+$q.TablesSc) (1024L*$ob); & $dma 18 ($sm+$small.RatioA) $TablesBase ($TablesOffset+$q.RatioSc) (128L*$ob)
        & $conv ($reg.WinHi.Offset+$shortcutAt) ($reg.WinLo.Offset+$shortcutAt) $cin $cout 1 'T' 2
        & $combine 'Scale' $cout $outOff ($sm+$small.RatioA) 'T' $skip
        if($j -eq $StopAfterBlock -and $DumpPoint -eq 'Shortcut'){ & $dma $OutputBase $OutputOffset 18 $outOff $(if($b.Up){$nT*(& $tbw 512)}else{$reg[$dst].Bytes}); break }
        # AdaIN1 + LeakyReLU, conv1.
        $cf='F'; $ct='T'
        # Delayed: the pool's input after a lead tile (the row pair before tile 0).
        $aAt=if($Delayed){$reg.A.Offset+$inW}else{$reg.A.Offset}
        if($b.Up){
            if(-not $Spans){ & $fill $reg.A.Offset $reg.A.Bytes 0x80008000L }
            & $adain $xOff $cin 'F' 'T' $q.Records1 'Tensor' $aAt 0
            if($j -eq $StopAfterBlock -and $DumpPoint -eq 'Coeff'){ & $dma $OutputBase $OutputOffset 18 ($sm+$small.Moments) (16L*$cin); & $dma $OutputBase ($OutputOffset+18432) 18 ($sm+$small.Km) (8L*$cin); & $dma $OutputBase ($OutputOffset+36864) 18 ($sm+$small.Records) (32L*$cin); break }
            & $padAt $aAt 'F' $cin 0x8000 $d 'T'; & $sync
            if($j -eq $StopAfterBlock -and $DumpPoint -eq 'Pool'){ & $dma $OutputBase $OutputOffset 18 $reg.A.Offset ($nT*$inW) }
            & $dma 18 ($sm+$small.Pool) $TablesBase ($TablesOffset+$q.Pool) (512L*$cin/32)
            & $ptr 0 18 $aAt; & $ptr 1 18 ($reg.WinHi.Offset+$inW); & $ptr 2 18 ($reg.WinLo.Offset+$inW); & $ptr 3 18 ($sm+$small.Pool); & $cnt 4 'T'; & $call $(if($Delayed){"dec_pool_${cin}_delayed"}else{"dec_pool_$cin"}); & $sync
            # Spans: this span's last row pair of a becomes the next span's previous one.
            if($Spans){ & $ptr 0 18 $aAt; & $ptr 1 18 $reg.A.Offset; & $call "dec_tailtile_${cin}_1"; [void]$tailUsed.Add("Tile,Tile,$cin,1"); & $sync }
            $cf='F2'; $ct='T2'
        } else {
            & $adain $xOff $cin 'F' 'T' $q.Records1 'Windows' ($reg.WinHi.Offset+$inW) ($reg.WinLo.Offset+$inW)
        }
        # Windows1 delay: the block input's, or for decode.3 the pool's (2d + 2 ticks).
        $w1=if($b.Up){2*$d+2}else{$d}
        & $windowsFix $cin $cf $ct $w1
        if($Spans){ & $history "w1_$j" $countValue[$ct] }
        $ctv=$countValue[$ct]
        if($j -eq $StopAfterBlock -and $DumpPoint -in 'Windows1','Pool'){ $at0=if($DumpPoint -eq 'Pool'){$nT*$inW}else{0L}; & $dma $OutputBase ($OutputOffset+$at0) 18 ($reg.WinHi.Offset+$inW) ($ctv*$inW); & $dma $OutputBase ($OutputOffset+$at0+$ctv*$inW) 18 ($reg.WinLo.Offset+$inW) ($ctv*$inW); break }
        & $weights ($ci+1); & $dma 18 ($sm+$small.Tables) $TablesBase ($TablesOffset+$q.Tables1) (1024L*$ob)
        & $conv ($reg.WinHi.Offset+$inW) ($reg.WinLo.Offset+$inW) $cin $cout 3 $ct 1
        & $combine 'Conv' $cout $reg.C.Offset 0 $ct 0
        & $padAt $reg.C.Offset $cf $cout 0x8000 ($w1+1) $ct; & $sync
        if($j -eq $StopAfterBlock -and $DumpPoint -eq 'Conv1'){ & $dma $OutputBase $OutputOffset 18 $reg.C.Offset ($ctv*(& $tbw $cout)); break }
        # AdaIN2 + LeakyReLU, conv2 added onto the shortcut.
        $cw=& $tbw $cout
        & $adain $reg.C.Offset $cout $cf $ct $q.Records2 'Windows' ($reg.WinHi.Offset+$cw) ($reg.WinLo.Offset+$cw)
        & $windowsFix $cout $cf $ct ($w1+1)
        if($Spans){ & $history "w2_$j" $countValue[$ct] }
        & $weights ($ci+2); & $dma 18 ($sm+$small.Tables) $TablesBase ($TablesOffset+$q.Tables2) (1024L*$ob); & $dma 18 ($sm+$small.RatioB) $TablesBase ($TablesOffset+$q.Ratio2) (128L*$ob)
        & $conv ($reg.WinHi.Offset+$cw) ($reg.WinLo.Offset+$cw) $cout $cout 3 $ct 1
        if($b.Up){
            & $ptr 0 18 $reg.S.Offset; & $ptr 1 18 $reg.O.Offset; & $cnt 2 'T'; & $call 'dec_framedouble_512'; & $sync
            & $combine 'Residual' $cout $reg.O.Offset ($sm+$small.RatioB) $ct 0
            & $padAt $reg.O.Offset $cf 512 0x8000 ($w1+2) $ct; & $sync
            # decode.3 holds its output in its own scales; one conversion into the generator's input scales saturates there.
            & $dma 18 ($sm+$small.Pool) $TablesBase ($TablesOffset+$q.Convert) 6144
            & $ptr 0 18 $reg.O.Offset; & $ptr 1 18 ($sm+$small.Pool); & $cnt 2 $ct; & $call 'dec_convert_512'; & $sync
            if($Spans){ & $dmaSpan $OutputBase $OutputOffset 16 18 $reg.O.Offset -1 65536 }
            else { & $dma $OutputBase $OutputOffset 18 $reg.O.Offset $L.OutputBytes }
        } else {
            & $combine 'Residual' $cout $reg[$dst].Offset ($sm+$small.RatioB) 'T' $skip
            & $padAt $reg[$dst].Offset 'F' 1120 0x8000 ($d+2) 'T'; & $sync
            if($j -eq $StopAfterBlock){ & $dma $OutputBase $OutputOffset 18 $reg[$dst].Offset $reg[$dst].Bytes; break }
        }
        $ci+=3; $src=$dst; $dst=if($dst -eq 'XA'){'XB'}else{'XA'}
    }
    if($StopAfterBlock -lt 0 -and $siteIndex.Value -ne $L.MomentSites.Count){throw "The decoder ran $($siteIndex.Value) AdaIN sites; the layout has $($L.MomentSites.Count)"}
    if($Spans){
        & $loadSpan 6; $s.Add(@{Op='addi';d=6;s=6;i=1}); & $ptr 7 18 $spanAt; $s.Add(@{Op='store';s=7;t=6;Offset=0})
        if($RuntimeFrames){ & $ptr 8 18 ($sm+$small.Counts); $s.Add(@{Op='load';d=8;s=8;Offset=8}) } else { & $imm 8 $L.SpanCount }; $s.Add(@{Op='gtu';d=0;s=8;t=6}); $s.Add(@{Op='jump-p';u=0;Label=$spanTop})
    }
    [pscustomobject]@{Layout=$L;Pads=@($padUsed);Combines=@($combines);Stride=@($stride);RuntimeFrames=[bool]$RuntimeFrames;Constants=($Moments -eq 'Constants')
        Delayed=[bool]$Delayed;Spans=[bool]$Spans;Convs=@($convUsed);Leads=@($leadUsed);Capacities=@($capacityUsed);Tails=@($tailUsed)}
}

# Bodies the job calls (labels as Add-KokoroDecoder16JobSteps emits them).
function Get-KokoroDecoder16Bodies {
    param([Parameter(Mandatory)]$Job)
    $L=$Job.Layout; $ps=$L.PlaneStride
    $bodies=[Collections.Generic.List[object]]::new()
    $bodies.Add(@('dec_identity_544',@(New-KokoroAdaInLeaky16Steps -Channels 544 -Output Windows -Identity -LabelPrefix 'decident_544')))
    $bodies.Add(@('dec_identity_1120',@(New-KokoroAdaInLeaky16Steps -Channels 1120 -Output Windows -Identity -LabelPrefix 'decident_1120')))
    $bodies.Add(@('dec_framedouble_512',@(New-KokoroFrameDouble16Steps -Channels 512 -LabelPrefix 'decdouble')))
    $bodies.Add(@('dec_convert_512',@(New-KokoroScaleConvert16Steps -Channels 512 -LabelPrefix 'decconvert')))
    if($Job.Delayed){
        $bodies.Add(@('dec_pool_1120_delayed',@(New-KokoroPool2Steps -Channels 1120 -OutputRowDelay 2 -LabelPrefix 'decpooldelayed')))
        foreach($c in $Job.Convs){ $shape=[int[]]($c -split ',')
            $bodies.Add(@("dec_conv_$($shape -join '_')",@(New-KokoroHmxConvPlanesLoopSteps -InputChannels $shape[0] -OutputChannels $shape[1] -Kernel $shape[2] -TapDelay $shape[3] -WeightPlanes 1 -PlaneStride $ps -LabelPrefix "decconv_$($shape -join '_')"))) }
        foreach($p in $Job.Leads){ $d,$w,$h=[int[]]($p -split ',')
            $bodies.Add(@("dec_lead_${d}_${w}_$h",@(New-KokoroPadRows16Steps -Leading -Frames $d -Channels $w -Halfword $h -LabelPrefix "declead_${d}_${w}_$h"))) }
        foreach($p in $Job.Capacities){ $w,$h=[int[]]($p -split ',')
            $bodies.Add(@("dec_padcap_${w}_$h",@(New-KokoroPadCapacity16Steps -Channels $w -Halfword $h -LabelPrefix "decpadcap_${w}_$h"))) }
    } else {
    $bodies.Add(@('dec_pool_1120',@(New-KokoroPool2Steps -Channels 1120 -LabelPrefix 'decpool')))
    foreach($shape in @(@(544,64,1),@(544,1024,1),@(544,1024,3),@(1024,1024,3),@(1120,1024,1),@(1120,1024,3),@(1120,512,1),@(1120,512,3),@(512,512,3))){
        $bodies.Add(@("dec_conv_$($shape[0])_$($shape[1])_$($shape[2])",@(New-KokoroHmxConvPlanesLoopSteps -InputChannels $shape[0] -OutputChannels $shape[1] -Kernel $shape[2] -WeightPlanes 1 -PlaneStride $ps -LabelPrefix "decconv_$($shape -join '_')"))) }
    }
    foreach($c in $Job.Combines){ $m,$ch,$skip=$c -split ','
        $bodies.Add(@("dec_combine_$($m.ToLower())_${ch}_$skip",@(New-KokoroPlaneCombineLoopSteps -Mode $m -Channels ([int]$ch) -PlaneStride $ps -OutputTileSkip ([long]$skip) -LabelPrefix "deccombine_$($m.ToLower())_${ch}_$skip"))) }
    foreach($w in 544,1120,1024,512){
        if($Job.Constants){
            $bodies.Add(@("dec_constants_$w",@(New-KokoroAdaInConstantCoefficientsLoopSteps -Channels $w -LabelPrefix "decconstants_$w")))
        } else {
        $bodies.Add(@("dec_moments_$w",@(New-KokoroAdaInMoments16LoopSteps -Channels $w -LabelPrefix "decmoments_$w")))
        $bodies.Add(@("dec_coeff_$w",@(New-KokoroAdaInAffineCoefficientsLoopSteps -Channels $w -LabelPrefix "deccoeff_$w")))
        }
        $bodies.Add(@("dec_leaky_windows_$w",@(New-KokoroAdaInLeaky16Steps -Channels $w -Output Windows -LabelPrefix "decleakyw_$w"))) }
    $bodies.Add(@('dec_leaky_tensor_1120',@(New-KokoroAdaInLeaky16Steps -Channels 1120 -Output Tensor -LabelPrefix 'decleakyt_1120')))
    foreach($p in $Job.Pads){ $f,$w,$h=$p -split ','
        if($f -eq 'rt'){ $bodies.Add(@("dec_padrt_${w}_$h",@(New-KokoroPadRows16RuntimeSteps -Channels ([int]$w) -Halfword ([int]$h) -LabelPrefix "decpadrt_${w}_$h"))); continue }
        $bodies.Add(@("dec_pad_${f}_${w}_$h",@(New-KokoroPadRows16Steps -Frames ([int]$f) -Channels ([int]$w) -Halfword ([int]$h) -LabelPrefix "decpad_${f}_${w}_$h"))) }
    foreach($p in $Job.Tails){ $from,$to,$w,$v=$p -split ','
        $name=if($from -eq 'Packed'){'tailrestore'}elseif($to -eq 'Packed'){'tailsave'}else{'tailtile'}
        $bodies.Add(@("dec_${name}_${w}_$v",@(New-KokoroTileTailCopy16Steps -Channels ([int]$w) -Vectors ([int]$v) -From $from -To $to -LabelPrefix "dec${name}_${w}_$v"))) }
    foreach($p in $Job.Stride){ $w,$c,$d=$p -split ','
        if($w -eq 'span'){ $bodies.Add(@("dec_stridespan_$c",@(New-KokoroStrideConv16Steps -Channels ([int]$c) -Channel 0 -CallerStart -LabelPrefix "decstridespan_$c"))); continue }
        if($null -ne $d){ $bodies.Add(@("dec_stride_${w}_${c}_$d",@(New-KokoroStrideConv16Steps -Frames $L.Frames -Channels ([int]$w) -Channel ([int]$c) -Delay ([int]$d) -LabelPrefix "decstride_${w}_${c}_$d" -RuntimeFrames:$Job.RuntimeFrames))); continue }
        $bodies.Add(@("dec_stride_${w}_$c",@(New-KokoroStrideConv16Steps -Frames $L.Frames -Channels ([int]$w) -Channel ([int]$c) -LabelPrefix "decstride_${w}_$c" -RuntimeFrames:$Job.RuntimeFrames))) }
    $bodies.ToArray()
}

# Standalone decoder job (the checked resource wrapper of the frozen resblock runner, as Kokoro.GeneratorTail16Run.ps1).
# Buffers: config, input (asr, F0 curve, N curve), weights, tables, output (decoder output at 256, or a block's output with
# -StopAfterBlock).
function New-KokoroDecoder16RunSteps {
    param([Parameter(Mandatory)][ValidateRange(2,4096)][int]$Frames,[ValidateRange(-1,4)][int]$StopAfterBlock=-1,[ValidateSet('Block','Shortcut','Conv1','Windows1','Pool','Coeff')][string]$DumpPoint='Block',[switch]$RuntimeFrames,
        [ValidateSet('Accumulate','Export','Supplied','SuppliedExport','Corrected','Direct','Constants')][string]$Moments='Accumulate',[switch]$Delayed,[switch]$Spans)
    . (Join-Path $PSScriptRoot 'Kokoro.ResBlockRun.ps1')
    foreach($file in '../kernels/Kokoro.HmxConvPlanes.ps1','../kernels/Kokoro.PlaneCombine.ps1','../kernels/Kokoro.AdaInMoments16.ps1','../kernels/Kokoro.AdaInTurnsCoefficients.ps1','../kernels/Kokoro.AdaInLeaky16.ps1','../kernels/Kokoro.Decoder16.ps1','../hexagon/Kokoro.DmaCopy.ps1') { . (Join-Path $PSScriptRoot $file) }
    $L=Get-KokoroDecoder16Layout -Frames $Frames -Delayed:$Delayed -Spans:$Spans
    $outputBytes=256L+$(if($StopAfterBlock -ge 0){[math]::Max($L.Regions.XA.Bytes,($L.Tiles+2*$L.Tiles2)*71680L)}else{$L.OutputBytes})+$(if($Moments -in 'Export','SuppliedExport'){$L.MomentsBytes+$L.KmBytes}else{0L})
    $s=[Collections.Generic.List[hashtable]]::new()
    $calls=[Collections.Generic.List[object]]::new()
    $imm={param([int]$r,[long]$v) $u=[long]([uint32]($v -band 0xffffffffL));$s.Add(@{Op='lo';x=$r;i=($u -band 65535)});$s.Add(@{Op='hi';x=$r;i=($u -shr 16)})}
    # The admitted config tile count is the decoder's (the phone harness passes Layout.Tiles).
    $wrapperSource=New-KokoroResBlockRunSteps -Frames $Frames -Kernel 11
    $base=@($wrapperSource.Steps);$start=-1
    for($i=0;$i -lt $base.Count;$i++){if($base[$i].Op -eq 'label' -and $base[$i].Name -eq 'connected_job'){$start=$i;break}}
    if($start -lt 0){throw 'Connected wrapper anchor changed'}
    $parameterBytes=if($Moments -eq 'Constants'){$L.ConstantsParameterBytes}else{$L.ParameterBytes}
    $inBytes=if($Moments -in 'Corrected','Direct'){$L.CorrectedInputBytes}elseif($Moments -in 'Supplied','SuppliedExport'){$L.SuppliedInputBytes}elseif($RuntimeFrames){$L.RuntimeInputBytes}else{$L.InputBytes}; $minimum=@(4,$inBytes,$L.WeightBytes,$parameterBytes,$outputBytes)
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
    # Job. r18 VTCM, r20 input, r21 weights, r22 tables, r23 output, r24 descriptors, r26:27 start ticks.
    $s.Add(@{Op='label';Name='connected_job'});$s.Add(@{Op='allocframe';Bytes=256})
    foreach($r in 16,18,20,22,24,26){$s.Add(@{Op='store-d';s=29;t=$r;Offset=(($r-16)*4)})}
    $s.Add(@{Op='addi';d=24;s=29;i=(64+63)}); & $imm 0 -64; $s.Add(@{Op='and';d=24;s=24;t=0})
    $s.Add(@{Op='hwticks';d=26})
    $job=Add-KokoroDecoder16JobSteps -Steps $s -Calls $calls -Frames $Frames -OutputBase 23 -OutputOffset 256 -StopAfterBlock $StopAfterBlock -DumpPoint $DumpPoint -RuntimeFrames:$RuntimeFrames -Moments $Moments -Delayed:$Delayed -Spans:$Spans
    $s.Add(@{Op='hwticks';d=0});$s.Add(@{Op='store-d';s=23;t=26;Offset=0});$s.Add(@{Op='store-d';s=23;t=0;Offset=8})
    $s.Add(@{Op='imm';d=0;i=1});$s.Add(@{Op='store';s=23;t=0;Offset=44})
    foreach($r in 16,18,20,22,24,26){$s.Add(@{Op='load-d';d=$r;s=29;Offset=(($r-16)*4)})}
    $s.Add(@{Op='dealloc-return'})
    foreach($pair in (Get-KokoroDecoder16Bodies -Job $job)){$s.Add(@{Op='label';Name=$pair[0]});foreach($step in $pair[1]){$s.Add($step)}}
    $labels=@{};$pcs=[Collections.Generic.Dictionary[object,long]]::new();$pc=0L;$isa=Get-InstructionSet
    foreach($step in $s){if($step.Op -eq 'label'){if($labels.ContainsKey($step.Name)){throw "Duplicate label $($step.Name)"};$labels[$step.Name]=$pc};$pcs[$step]=$pc;$pc+=& $isa.Length $step}
    foreach($c in $calls){if(-not $labels.ContainsKey($c.label)){throw "Missing body $($c.label)"};$delta=[long]([uint32](($labels[$c.label]-$pcs[$c.pc]) -band 0xffffffffL));$c.low.i=$delta -band 65535;$c.high.i=$delta -shr 16}
    [pscustomobject]@{Steps=$s.ToArray();Layout=[ordered]@{Frames=$Frames;RuntimeFrames=[bool]$RuntimeFrames;FramesOffset=$L.Input.Frames;Tiles=$L.InputTiles;Tiles2=$L.Tiles2;Delayed=[bool]$Delayed;Spans=[bool]$Spans;SpanCount=$L.SpanCount;OutputDelayTicks=$L.OutputDelayTicks;InputBytes=$inBytes;WeightBytes=$L.WeightBytes;ParameterBytes=$parameterBytes;OutputBytes=$outputBytes;OutputOffset=256;PcmOffset=256;Samples=1;VtcmBytes=$L.VtcmBytes;StopAfterBlock=$StopAfterBlock
        Moments=$Moments;MomentsInputOffset=$L.Input.Moments;MomentCountsInputOffset=$L.Input.MomentCounts;MomentsOutputOffset=(256L+$L.OutputBytes);KmOutputOffset=(256L+$L.OutputBytes+$L.MomentsBytes);KmDeltasInputOffset=$L.Input.KmDeltas;MomentSites=$L.MomentSites}}
}
