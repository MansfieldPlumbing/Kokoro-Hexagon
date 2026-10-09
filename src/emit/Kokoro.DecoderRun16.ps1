#requires -Version 7.4
# Stock Kokoro decoder front on the DSP at 16 bits (docs/decoder-design.md): captured asr, F0_curve, N_curve -> the decoder
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

function Get-KokoroDecoder16Layout {
    param([Parameter(Mandatory)][ValidateRange(2,4096)][int]$Frames)
    $F=$Frames; $T=[int][math]::Ceiling($F/32); $T2=[int][math]::Ceiling(2*$F/32)
    $tb={param([int]$c) 64L*$c}
    $al={param([long]$v) [long]([math]::Ceiling($v/65536)*65536)}
    $planeStride=[long]([math]::Max($T*32,$T2*16))*2048
    $regions=[ordered]@{}; $at=0L
    foreach($r in @(@('WinHi',((2*$T+2)*(& $tb 1120))),@('WinLo',((2*$T+2)*(& $tb 1120))),@('Planes',(4*$planeStride)),
        @('XA',($T*(& $tb 1120))),@('XB',($T*(& $tb 1120))),@('E',($T*(& $tb 544))),@('C',([math]::Max($T*(& $tb 1024),$T2*(& $tb 512)))),
        @('A',(($T+1)*(& $tb 1120))),@('S',($T*(& $tb 512))),@('O',(2*$T*(& $tb 512))))){
        $regions[$r[0]]=[ordered]@{Offset=$at;Bytes=[long]$r[1]}; $at+=& $al $r[1] }
    $small=[ordered]@{Moments=0L;Km=18432L;RatioA=27648L;RatioB=31744L;Tables=35840L;Records=68608L;Pool=104448L;Stride=122368L;Curves=122880L}
    $curveBytes=[long]([math]::Ceiling(8*$F/128)*128)
    $regions['Small']=[ordered]@{Offset=$at;Bytes=($small.Curves+2*$curveBytes)}; $at+=& $al $regions.Small.Bytes
    if($at -gt 4194304){throw 'Decoder activations exceed the first 4 MiB of VTCM'}
    $regions['Weights']=[ordered]@{Offset=4194304L;Bytes=3440640L}; $vtcm=4194304L+3440640L
    if([math]::Floor($regions.WinHi.Offset/4194304) -ne [math]::Floor(($regions.WinLo.Offset+$regions.WinLo.Bytes-1)/4194304)){throw 'Windows cross a 4 MiB VTCM page'}
    # Inputs: asr (512-wide croutons, T tiles), F0 curve and N curve (int32, 2F samples each, 128-byte padded).
    $input=[ordered]@{Asr=0L;F0=($T*32768L);N=($T*32768L+$curveBytes)}; $inputBytes=$T*32768L+2*$curveBytes
    # Convs in run order: asr_res, then per block shortcut, conv1, conv2. Weights Cout * Cin * K bytes each.
    $blocks=@(@{Name='encode';Cin=544;Cout=1024;Wide=1120},@{Name='decode.0';Cin=1120;Cout=1024;Wide=1120},@{Name='decode.1';Cin=1120;Cout=1024;Wide=1120},
        @{Name='decode.2';Cin=1120;Cout=1024;Wide=1120},@{Name='decode.3';Cin=1120;Cout=512;Wide=512;Up=$true})
    $convs=[Collections.Generic.List[object]]::new(); $w=0L
    $list=@(,@('asr_res.0',544,64,1))
    foreach($b in $blocks){ foreach($c in @(@('conv1x1',$b.Cin,1),@('conv1',$b.Cin,3),@('conv2',$b.Cout,3))){ $list+=,@("$($b.Name).$($c[0])",$c[1],$b.Cout,$c[2]) } }
    foreach($c in $list){ $bytes=[long]$c[2]*$c[1]*$c[3]; $convs.Add([ordered]@{Name=$c[0];Cin=$c[1];Cout=$c[2];K=$c[3];Offset=$w;Bytes=$bytes}); $w+=$bytes }
    # Parameter records (tables.bin): asr_res tables; F0 and N stride constants; per block AdaIN1 records, conv1 tables, AdaIN2
    # records, conv2 tables, shortcut tables, shortcut ratios, conv2 ratios, decode.3 pool constants.
    $p=[ordered]@{AsrTables=0L;F0=2048L;N=2080L}; $pAt=2176L; $blockParams=[Collections.Generic.List[object]]::new()
    foreach($b in $blocks){
        $q=[ordered]@{}; $ob=$b.Cout/32
        foreach($e in @(@('Records1',(32L*$b.Cin)),@('Tables1',(1024L*$ob)),@('Records2',(32L*$b.Cout)),@('Tables2',(1024L*$ob)),@('TablesSc',(1024L*$ob)),@('RatioSc',(128L*$ob)),@('Ratio2',(128L*$ob)))){ $q[$e[0]]=$pAt; $pAt+=$e[1] }
        if($b.Up){ $q['Pool']=$pAt; $pAt+=512L*$b.Cin/32 }
        $blockParams.Add($q)
    }
    [pscustomobject]@{Frames=$F;Tiles=$T;Tiles2=$T2;OutputTiles=2*$T;PlaneStride=$planeStride;Regions=$regions;Small=$small;CurveBytes=$curveBytes
        Input=$input;InputBytes=$inputBytes;Blocks=$blocks;Convs=$convs.ToArray();WeightBytes=$w;Params=$p;BlockParams=$blockParams.ToArray();ParameterBytes=$pAt
        OutputBytes=($T2*32768L);VtcmBytes=$vtcm}
}

# Appends the decoder job to Steps (registers as the generator jobs: r18 VTCM, r24 DMA descriptor slots). The decoder output
# (512-wide croutons, 2T tiles, rows past 2F zero) is DMAed to OutputBase + OutputOffset. -StopAfterBlock n (0 encode ..
# 3 decode.2) instead copies that block's output (1120-wide, T tiles) there.
function Add-KokoroDecoder16JobSteps {
    param([Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[hashtable]]$Steps,[Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Calls,
        [Parameter(Mandatory)][ValidateRange(2,4096)][int]$Frames,
        [int]$InputBase=20,[long]$InputOffset=0,[int]$WeightsBase=21,[long]$WeightsOffset=0,[int]$TablesBase=22,[long]$TablesOffset=0,
        [int]$OutputBase=23,[long]$OutputOffset=256,[ValidateRange(-1,3)][int]$StopAfterBlock=-1)
    $L=Get-KokoroDecoder16Layout -Frames $Frames
    $F=$Frames; $nT=$L.Tiles; $nT2=$L.Tiles2; $reg=$L.Regions; $sm=$reg.Small.Offset; $small=$L.Small; $planes=$reg.Planes.Offset
    $s=$Steps; $callList=$Calls
    $imm={param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL);$s.Add(@{Op='lo';x=$r;i=($u -band 65535)});$s.Add(@{Op='hi';x=$r;i=($u -shr 16)})}
    $ptr={param([int]$r,[int]$baseReg,[long]$offset) $offsetReg=if($r -eq $baseReg){15}else{$r}; & $imm $offsetReg $offset;$s.Add(@{Op='add';d=$r;s=$baseReg;t=$offsetReg}) }
    $call={param([string]$label) $pc=@{Op='add-pc';d=14;i=0};$lo=@{Op='lo';x=15;i=0};$hi=@{Op='hi';x=15;i=0};$s.Add($pc);$s.Add($lo);$s.Add($hi);$s.Add(@{Op='add';d=14;s=14;t=15});$s.Add(@{Op='callr';s=14});$callList.Add(@{pc=$pc;low=$lo;high=$hi;label=$label})}
    $script:__d16=0
    $label={ $script:__d16++; "d16_$($script:__d16)" }
    $sync={ $s.Add(@{Op='syncht'}) }
    $dma={param([int]$destBase,[long]$destOff,[int]$srcBase,[long]$srcOff,[long]$length)
        if($length -lt 2 -or $length -ge 2*16777215){throw 'DMA length out of range'}
        & $ptr 1 $srcBase $srcOff; & $ptr 2 $destBase $destOff; & $imm 3 $length; $s.Add(@{Op='addi';d=0;s=24;i=0})
        foreach($step in @(New-KokoroDmaCopySteps -NoReturn)){$s.Add($step)} }
    $fill={param([long]$off,[long]$bytes,[long]$pattern)
        & $ptr 4 18 $off; & $imm 6 $pattern; $s.Add(@{Op='vsplat';d=0;s=6}); & $imm 5 ($bytes/128); $s.Add(@{Op='imm';d=7;i=0})
        $n=& $label; $s.Add(@{Op='label';Name=$n});$s.Add(@{Op='vstore';s=4;t=0;Offset=0});$s.Add(@{Op='addi';d=4;s=4;i=128});$s.Add(@{Op='addi';d=5;s=5;i=-1});$s.Add(@{Op='gtu';d=0;s=5;t=7});$s.Add(@{Op='jump-p';u=0;Label=$n}) }
    $pad={param([long]$off,[int]$fr,[int]$width,[int]$halfword) & $ptr 0 18 $off; & $call "dec_pad_${fr}_${width}_$halfword" }
    $padUsed=[Collections.Generic.HashSet[string]]::new()
    $padName={param([int]$fr,[int]$width,[int]$halfword) [void]$padUsed.Add("$fr,$width,$halfword") }
    $tbw={param([int]$c) 64L*$c}
    $conv={param([long]$hi,[long]$lo,[int]$cin,[int]$cout,[int]$k,[int]$tiles) & $ptr 0 18 $hi; & $ptr 1 18 $lo; & $ptr 2 18 $reg.Weights.Offset; & $ptr 3 18 ($sm+$small.Tables); & $imm 4 $tiles; & $ptr 5 18 $planes; & $call "dec_conv_${cin}_${cout}_$k"; & $sync }
    $combine={param([string]$mode,[int]$cout,[long]$out,[long]$ratio,[int]$tiles,[long]$skip,[int]$shift=0) & $ptr 0 18 $planes; & $ptr 1 18 $out; & $ptr 2 18 $ratio; & $imm 3 $tiles; & $call "dec_combine_$($mode.ToLower())_${cout}_${skip}_$shift"; [void]$combines.Add("$mode,$cout,$skip,$shift"); & $sync }
    $adain={param([long]$x,[int]$width,[int]$fr,[int]$tiles,[long]$records,[string]$output,[long]$hi,[long]$lo)
        & $fill ($sm+$small.Moments) (16L*$width) 0
        & $ptr 0 18 $x; & $ptr 1 18 ($sm+$small.Moments); & $imm 2 $tiles; & $call "dec_moments_$width"; & $sync
        & $dma 18 ($sm+$small.Records) $TablesBase ($TablesOffset+$records) (32L*$width)
        & $ptr 0 18 ($sm+$small.Moments); & $ptr 1 18 ($sm+$small.Records); & $ptr 2 18 ($sm+$small.Km); & $imm 3 $fr; & $call "dec_coeff_$width"
        & $ptr 0 18 $x; & $ptr 1 18 $hi; & $ptr 2 18 $lo; & $ptr 3 18 ($sm+$small.Km); & $imm 4 $tiles; & $call "dec_leaky_$($output.ToLower())_$width"; & $sync }
    $windowsFix={param([int]$width,[int]$fr,[int]$tiles)
        $w=& $tbw $width
        & $fill $reg.WinHi.Offset $w 0x80008000L; & $fill $reg.WinLo.Offset $w 0
        & $fill ($reg.WinHi.Offset+($tiles+1)*$w) $w 0x80008000L; & $fill ($reg.WinLo.Offset+($tiles+1)*$w) $w 0
        & $pad ($reg.WinHi.Offset+$w) $fr $width 0x8000; & $padName $fr $width 0x8000
        & $pad ($reg.WinLo.Offset+$w) $fr $width 0; & $padName $fr $width 0
        & $sync }
    $weights={param([int]$index) $c=$L.Convs[$index]; & $dma 18 $reg.Weights.Offset $WeightsBase ($WeightsOffset+$c.Offset) $c.Bytes }

    # Inputs: asr into E (544 wide), F0 and N through their stride-2 convs into E (512, 513) and both wide tensors (1088, 1089).
    foreach($region in 'E','XA','XB'){ & $fill $reg[$region].Offset $reg[$region].Bytes 0x80008000L }
    for($t=0;$t -lt $nT;$t++){ & $dma 18 ($reg.E.Offset+$t*(& $tbw 544)) $InputBase ($InputOffset+$L.Input.Asr+$t*32768L) 32768 }
    & $dma 18 ($sm+$small.Curves) $InputBase ($InputOffset+$L.Input.F0) (2*$L.CurveBytes)
    & $dma 18 ($sm+$small.Stride) $TablesBase ($TablesOffset+$L.Params.F0) 128
    $stride=[Collections.Generic.HashSet[string]]::new()
    foreach($target in @(@('E',544,512,0),@('E',544,513,1),@('XA',1120,1088,0),@('XA',1120,1089,1),@('XB',1120,1088,0),@('XB',1120,1089,1))){
        & $ptr 0 18 ($sm+$small.Curves+$target[3]*$L.CurveBytes); & $ptr 1 18 $reg[$target[0]].Offset; & $ptr 2 18 ($sm+$small.Stride+32*$target[3])
        & $call "dec_stride_$($target[1])_$($target[2])"; [void]$stride.Add("$($target[1]),$($target[2])") }
    # asr_res: conv1x1 over E (zero weights past 512) into channels 1024..1087 of both wide tensors (Conv mode).
    & $ptr 0 18 $reg.E.Offset; & $ptr 1 18 $reg.WinLo.Offset; & $imm 2 ($nT*(& $tbw 544)/128); & $call 'dec_lowwindow'; & $sync
    & $weights 0; & $dma 18 ($sm+$small.Tables) $TablesBase ($TablesOffset+$L.Params.AsrTables) 2048
    & $conv $reg.E.Offset $reg.WinLo.Offset 544 64 1 $nT
    $combines=[Collections.Generic.HashSet[string]]::new()
    foreach($x in 'XA','XB'){ & $combine 'Conv' 64 ($reg[$x].Offset+32*2048) 0 $nT ((1120-64)*64) }

    $src='E'; $dst='XA'; $ci=1
    for($j=0;$j -lt 5;$j++){
        $b=$L.Blocks[$j]; $q=$L.BlockParams[$j]; $cin=$b.Cin; $cout=$b.Cout; $ob=$cout/32; $inW=& $tbw $cin
        $xOff=$reg[$src].Offset
        $outOff=if($b.Up){$reg.S.Offset}else{$reg[$dst].Offset}; $skip=if($b.Up){0L}else{[long](1120-$cout)*64}
        # Shortcut (F frames) into the output (decode.3: into S, doubled later).
        & $ptr 0 18 $xOff; & $ptr 1 18 $reg.WinLo.Offset; & $imm 2 ($nT*$inW/128); & $call 'dec_lowwindow'; & $sync
        & $weights $ci; & $dma 18 ($sm+$small.Tables) $TablesBase ($TablesOffset+$q.TablesSc) (1024L*$ob); & $dma 18 ($sm+$small.RatioA) $TablesBase ($TablesOffset+$q.RatioSc) (128L*$ob)
        & $conv $xOff $reg.WinLo.Offset $cin $cout 1 $nT
        $shift=if($b.Up){1}else{0}
        & $combine 'Scale' $cout $outOff ($sm+$small.RatioA) $nT $skip $shift
        # AdaIN1 + LeakyReLU, conv1.
        $cf=$F; $ct=$nT
        if($b.Up){
            & $fill $reg.A.Offset $reg.A.Bytes 0x80008000L
            & $adain $xOff $cin $F $nT $q.Records1 'Tensor' $reg.A.Offset 0
            & $pad $reg.A.Offset $F $cin 0x8000; & $padName $F $cin 0x8000; & $sync
            & $dma 18 ($sm+$small.Pool) $TablesBase ($TablesOffset+$q.Pool) (512L*$cin/32)
            & $ptr 0 18 $reg.A.Offset; & $ptr 1 18 ($reg.WinHi.Offset+$inW); & $ptr 2 18 ($reg.WinLo.Offset+$inW); & $ptr 3 18 ($sm+$small.Pool); & $imm 4 $nT; & $call "dec_pool_$cin"; & $sync
            $cf=2*$F; $ct=$nT2
        } else {
            & $adain $xOff $cin $F $nT $q.Records1 'Windows' ($reg.WinHi.Offset+$inW) ($reg.WinLo.Offset+$inW)
        }
        & $windowsFix $cin $cf $ct
        & $weights ($ci+1); & $dma 18 ($sm+$small.Tables) $TablesBase ($TablesOffset+$q.Tables1) (1024L*$ob)
        & $conv ($reg.WinHi.Offset+$inW) ($reg.WinLo.Offset+$inW) $cin $cout 3 $ct
        & $combine 'Conv' $cout $reg.C.Offset 0 $ct 0
        & $pad $reg.C.Offset $cf $cout 0x8000; & $padName $cf $cout 0x8000; & $sync
        # AdaIN2 + LeakyReLU, conv2 added onto the shortcut.
        $cw=& $tbw $cout
        & $adain $reg.C.Offset $cout $cf $ct $q.Records2 'Windows' ($reg.WinHi.Offset+$cw) ($reg.WinLo.Offset+$cw)
        & $windowsFix $cout $cf $ct
        & $weights ($ci+2); & $dma 18 ($sm+$small.Tables) $TablesBase ($TablesOffset+$q.Tables2) (1024L*$ob); & $dma 18 ($sm+$small.RatioB) $TablesBase ($TablesOffset+$q.Ratio2) (128L*$ob)
        & $conv ($reg.WinHi.Offset+$cw) ($reg.WinLo.Offset+$cw) $cout $cout 3 $ct
        if($b.Up){
            & $ptr 0 18 $reg.S.Offset; & $ptr 1 18 $reg.O.Offset; & $imm 2 $nT; & $call 'dec_framedouble_512'; & $sync
            & $combine 'Residual' $cout $reg.O.Offset ($sm+$small.RatioB) $ct 0 1
            & $pad $reg.O.Offset $cf 512 0x8000; & $padName $cf 512 0x8000; & $sync
            & $dma $OutputBase $OutputOffset 18 $reg.O.Offset $L.OutputBytes
        } else {
            & $combine 'Residual' $cout $reg[$dst].Offset ($sm+$small.RatioB) $nT $skip
            & $pad $reg[$dst].Offset $F 1120 0x8000; & $padName $F 1120 0x8000; & $sync
            if($j -eq $StopAfterBlock){ & $dma $OutputBase $OutputOffset 18 $reg[$dst].Offset $reg[$dst].Bytes; break }
        }
        $ci+=3; $src=$dst; $dst=if($dst -eq 'XA'){'XB'}else{'XA'}
    }
    [pscustomobject]@{Layout=$L;Pads=@($padUsed);Combines=@($combines);Stride=@($stride)}
}

# Bodies the job calls (labels as Add-KokoroDecoder16JobSteps emits them).
function Get-KokoroDecoder16Bodies {
    param([Parameter(Mandatory)]$Job)
    $L=$Job.Layout; $ps=$L.PlaneStride
    $bodies=[Collections.Generic.List[object]]::new()
    $bodies.Add(@('dec_lowwindow',@(New-KokoroLowWindow16Steps -LabelPrefix 'declow')))
    $bodies.Add(@('dec_framedouble_512',@(New-KokoroFrameDouble16Steps -Channels 512 -LabelPrefix 'decdouble')))
    $bodies.Add(@('dec_pool_1120',@(New-KokoroPool2Steps -Channels 1120 -LabelPrefix 'decpool')))
    foreach($shape in @(@(544,64,1),@(544,1024,1),@(544,1024,3),@(1024,1024,3),@(1120,1024,1),@(1120,1024,3),@(1120,512,1),@(1120,512,3),@(512,512,3))){
        $bodies.Add(@("dec_conv_$($shape[0])_$($shape[1])_$($shape[2])",@(New-KokoroHmxConvPlanesLoopSteps -InputChannels $shape[0] -OutputChannels $shape[1] -Kernel $shape[2] -WeightPlanes 1 -PlaneStride $ps -LabelPrefix "decconv_$($shape -join '_')"))) }
    foreach($c in $Job.Combines){ $m,$ch,$skip,$shift=$c -split ','
        $bodies.Add(@("dec_combine_$($m.ToLower())_${ch}_${skip}_$shift",@(New-KokoroPlaneCombineLoopSteps -Mode $m -Channels ([int]$ch) -PlaneStride $ps -OutputTileSkip ([long]$skip) -RatioShift ([int]$shift) -LabelPrefix "deccombine_$($m.ToLower())_${ch}_${skip}_$shift"))) }
    foreach($w in 544,1120,1024,512){
        $bodies.Add(@("dec_moments_$w",@(New-KokoroAdaInMoments16LoopSteps -Channels $w -LabelPrefix "decmoments_$w")))
        $bodies.Add(@("dec_coeff_$w",@(New-KokoroAdaInAffineCoefficientsLoopSteps -Channels $w -LabelPrefix "deccoeff_$w")))
        $bodies.Add(@("dec_leaky_windows_$w",@(New-KokoroAdaInLeaky16Steps -Channels $w -Output Windows -LabelPrefix "decleakyw_$w"))) }
    $bodies.Add(@('dec_leaky_tensor_1120',@(New-KokoroAdaInLeaky16Steps -Channels 1120 -Output Tensor -LabelPrefix 'decleakyt_1120')))
    foreach($p in $Job.Pads){ $f,$w,$h=$p -split ','
        $bodies.Add(@("dec_pad_${f}_${w}_$h",@(New-KokoroPadRows16Steps -Frames ([int]$f) -Channels ([int]$w) -Halfword ([int]$h) -LabelPrefix "decpad_${f}_${w}_$h"))) }
    foreach($p in $Job.Stride){ $w,$c=$p -split ','
        $bodies.Add(@("dec_stride_${w}_$c",@(New-KokoroStrideConv16Steps -Frames $L.Frames -Channels ([int]$w) -Channel ([int]$c) -LabelPrefix "decstride_${w}_$c"))) }
    $bodies.ToArray()
}

# Standalone decoder job (the checked resource wrapper of the frozen resblock runner, as Kokoro.GeneratorTail16Run.ps1).
# Buffers: config, input (asr, F0 curve, N curve), weights, tables, output (decoder output at 256, or a block's output with
# -StopAfterBlock).
function New-KokoroDecoder16RunSteps {
    param([Parameter(Mandatory)][ValidateRange(2,4096)][int]$Frames,[ValidateRange(-1,3)][int]$StopAfterBlock=-1)
    . (Join-Path $PSScriptRoot 'Kokoro.ResBlockRun.ps1')
    foreach($file in 'Kokoro.HmxConvPlanes.ps1','Kokoro.PlaneCombine.ps1','Kokoro.AdaInMoments16.ps1','Kokoro.AdaInTurnsCoefficients.ps1','Kokoro.AdaInLeaky16.ps1','Kokoro.Decoder16.ps1','Kokoro.DmaCopy.ps1') { . (Join-Path $PSScriptRoot $file) }
    $L=Get-KokoroDecoder16Layout -Frames $Frames
    $outputBytes=256L+$(if($StopAfterBlock -ge 0){$L.Regions.XA.Bytes}else{$L.OutputBytes})
    $s=[Collections.Generic.List[hashtable]]::new()
    $calls=[Collections.Generic.List[object]]::new()
    $imm={param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL);$s.Add(@{Op='lo';x=$r;i=($u -band 65535)});$s.Add(@{Op='hi';x=$r;i=($u -shr 16)})}
    # The admitted config tile count is the decoder's (the phone harness passes Layout.Tiles).
    $wrapperSource=New-KokoroResBlockRunSteps -Frames $Frames -Kernel 11
    $base=@($wrapperSource.Steps);$start=-1
    for($i=0;$i -lt $base.Count;$i++){if($base[$i].Op -eq 'label' -and $base[$i].Name -eq 'connected_job'){$start=$i;break}}
    if($start -lt 0){throw 'Connected wrapper anchor changed'}
    $minimum=@(4,$L.InputBytes,$L.WeightBytes,$L.ParameterBytes,$outputBytes)
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
    $job=Add-KokoroDecoder16JobSteps -Steps $s -Calls $calls -Frames $Frames -OutputBase 23 -OutputOffset 256 -StopAfterBlock $StopAfterBlock
    $s.Add(@{Op='hwticks';d=0});$s.Add(@{Op='store-d';s=23;t=26;Offset=0});$s.Add(@{Op='store-d';s=23;t=0;Offset=8})
    $s.Add(@{Op='imm';d=0;i=1});$s.Add(@{Op='store';s=23;t=0;Offset=44})
    foreach($r in 16,18,20,22,24,26){$s.Add(@{Op='load-d';d=$r;s=29;Offset=(($r-16)*4)})}
    $s.Add(@{Op='dealloc-return'})
    foreach($pair in (Get-KokoroDecoder16Bodies -Job $job)){$s.Add(@{Op='label';Name=$pair[0]});foreach($step in $pair[1]){$s.Add($step)}}
    $labels=@{};$pcs=[Collections.Generic.Dictionary[object,long]]::new();$pc=0L;$isa=Get-InstructionSet
    foreach($step in $s){if($step.Op -eq 'label'){if($labels.ContainsKey($step.Name)){throw "Duplicate label $($step.Name)"};$labels[$step.Name]=$pc};$pcs[$step]=$pc;$pc+=& $isa.Length $step}
    foreach($c in $calls){if(-not $labels.ContainsKey($c.label)){throw "Missing body $($c.label)"};$delta=[uint32](($labels[$c.label]-$pcs[$c.pc]) -band 0xffffffffL);$c.low.i=$delta -band 65535;$c.high.i=$delta -shr 16}
    [pscustomobject]@{Steps=$s.ToArray();Layout=[ordered]@{Frames=$Frames;Tiles=$L.Tiles;Tiles2=$L.Tiles2;InputBytes=$L.InputBytes;WeightBytes=$L.WeightBytes;ParameterBytes=$L.ParameterBytes;OutputBytes=$outputBytes;OutputOffset=256;PcmOffset=256;Samples=1;VtcmBytes=$L.VtcmBytes;StopAfterBlock=$StopAfterBlock}}
}
