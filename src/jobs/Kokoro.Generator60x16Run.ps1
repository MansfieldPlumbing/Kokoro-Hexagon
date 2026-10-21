#requires -Version 7.4
# Stock generator resblocks.3/4/5 and their three-way mean at 16 bits, activations resident in VTCM.
# Source: hexgrad/kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec, istftnet.py AdaINResBlock1.forward and
# Generator.forward. Pass order as the 8-bit resident
# stage (Kokoro.Generator60xResidentRun.ps1).
#
# Per branch (kernel 3, 7, 11), per dilation pair (1, 3, 5):
#   first half:  K/M/S from R moments; per batch phase-turns AdaIN+Snake R -> high/low windows,
#                two-plane HMX conv1 -> planes, combine -> C; epilogue: moments of C.
#   second half: K/M/S from C moments; per batch AdaIN+Snake C -> windows, HMX conv2 -> planes,
#                combine with R += ratio * O; epilogue: moments of the new R.
# Values are biased u16 (x + 32768). Rows past the frame count hold x = 0 in R and C (so moments see
# nothing) and the conv-input zero (high 128, low 0) in the windows, as stock zero padding.
# Inputs (method 2, five buffers): config (tiles), R0 (biased u16), weights (per branch and stage Wh
# then Wl, 32768*K bytes), parameter records (16384 bytes per branch and stage: turns parameters,
# column tables, residual ratios; tools/New-KokoroGenerator60x16Fixture.ps1), output.
# Output, relative to the aligned DDR workspace r25: branch 0 and 1 results (read back for the mean),
# the final tensor, the K/M/S constants of all 18 stages (1536 bytes each), then 128 KiB scratch.

function Get-KokoroGenerator60x16Layout {
    param([ValidateRange(2,32768)][int]$Frames=7801,[ValidateRange(1,64)][int]$BatchTiles=22,[ValidateSet(128,256)][int]$Channels=128)
    # Per channel count C: tiles of 64 C bytes; parameter records of 128 C bytes (turns parameters 32 C, column tables at
    # 32 C, residual ratios at 80 C, group 3 shifts at 80 C + 1024); moments records of 16 C bytes; K/M/S of 12 C bytes.
    $tileBytes=64*$Channels; $record=128*$Channels
    $tiles=[int][math]::Ceiling($Frames/32); $bytes=$tiles*$tileBytes
    $al={param([long]$v) [long]([math]::Ceiling($v/65536)*65536)}
    $small=[ordered]@{Parameters=0;Moments=$record;InputMoments=($record+16*$Channels);PrivateMoments=($record+32*$Channels);Kms=($record+80*$Channels)}
    $smallBytes=[long]([math]::Ceiling(($small.Kms+12*$Channels)/32768)*32768)
    $regions=[ordered]@{}; $at=0L
    # HMX activation reads must not straddle a 4 MiB VTCM page: both windows come first. ConvOutput carries four tiles of
    # slack: the front interleave writes past the stage input (7,801 frames fitted only by 64 KiB rounding; 7,321 did not).
    $list=@(@('Window',(($BatchTiles+2)*$tileBytes)),@('WindowLow',(($BatchTiles+2)*$tileBytes)),@('Planes',(6L*$BatchTiles*$tileBytes)),@('Weights',(2L*$Channels*$Channels*11)),@('Small',$smallBytes),@('Residual',$bytes),@('ConvOutput',($bytes+4L*$tileBytes)))
    foreach($r in $list){ $regions[$r[0]]=[ordered]@{Offset=$at;Bytes=[long]$r[1]}; $at+=& $al $r[1] }
    $page=4194304
    foreach($name in 'Window','WindowLow'){ $w=$regions[$name]; if([math]::Floor($w.Offset/$page) -ne [math]::Floor(($w.Offset+$w.Bytes-1)/$page)){throw 'Conv-input window crosses a 4 MiB VTCM boundary'} }
    [pscustomobject]@{Frames=$Frames;Tiles=$tiles;TensorBytes=$bytes;BatchTiles=$BatchTiles;Regions=$regions;Small=$small;VtcmBytes=$at;PlaneStride=([long]$BatchTiles*$tileBytes);Channels=$Channels;TileBytes=$tileBytes;RecordBytes=$record}
}

function New-KokoroGenerator60x16RunSteps {
    param([ValidateRange(2,32768)][int]$Frames=7801,[ValidateRange(1,64)][int]$BatchTiles=22,[ValidateRange(1,4)][int]$HvxThreads=4,
        [ValidateSet('Accumulate','Export','Constants')][string]$AdaInMode='Accumulate',
        # Capacity-sized residual stage with a live int32 frame count appended to the input.
        [switch]$RuntimeFrames,
        [ValidateCount(8,8)][ValidateRange(0,1023)][int[]]$PmuEvents,
        # Diagnosis: end after stage StopAfterStage (b*6 + s) with its output (C after a first half, R after a
        # second half) in the final-tensor slot.
        [ValidateRange(-1,17)][int]$StopAfterStage=-1,
        # With StopAfterStage: Windows dumps the first batch's conv-input windows (high, then low), Planes its
        # six HMX byte planes, into the final-tensor slot instead of finishing the stage.
        [ValidateSet('Stage','Windows','Planes')][string]$DumpPoint='Stage',
        # Then the 16-bit tail (Kokoro.GeneratorTail16Run.ps1) on the final tensor: PCM int16 in the output buffer;
        # tail weights and parameters follow the stage's in their buffers.
        [switch]$Tail,
        # Block kernel sizes: 3, 7, 11 (resblocks.3-5 and their mean), or one block alone (e.g. 11 for noise_res[1]),
        # whose output is the final tensor. The fixture lists the same blocks (tools/New-KokoroGenerator60x16Fixture.ps1).
        [ValidateCount(1,3)][ValidateSet(3,7,11)][int[]]$Kernels=@(3,7,11),
        # The 128-channel front first (tools/New-KokoroGeneratorFront16Fixture.ps1, Kokoro.GeneratorFront16.ps1): the input
        # buffer holds har and ups[1]-input planes; noise_convs[1] -> noise_res[1] and ups[1] -> reflection pad -> add give
        # the stage input in VTCM. noise_res[1] and front weights and records follow the stage's (and the tail's).
        [switch]$Front,
        # 128 (generator resblocks.3-5, noise_res[1]) or 256 channels (resblocks.0-2, noise_res[0]).
        [ValidateSet(128,256)][int]$Channels=128,
        # Completion word 1 (src/runspace/KokoroGeneratorTailProbe.ps1) instead of the stage count the resblock harness checks.
        [switch]$GenericHarness,
        # The whole generator in one job (tools/New-KokoroGeneratorWholeFixture.ps1): the 256-channel 10x section (-Front,
        # (Frames - 1)/6 frames) from decoder output and har, then the 128-channel 60x section and the tail, its ups[1] input
        # planes LeakyReLU(0.1) of the 10x mean in VTCM. Each section's inputs, weights, records and DDR workspace follow the
        # previous section's; bodies are emitted per section (labels suffixed with the channel count); one worker pool.
        [switch]$Whole,
        # With -Whole: the harmonic source and its STFT first (Kokoro.HarmonicSource16Run.ps1, from f0 and z in the input
        # buffer after the decoder output), har written to the DDR workspace in both layouts (the 60x planes, and the 10x
        # phase-major planes by Kokoro.HarPhaseMajor16.ps1); both fronts read har there. Inputs, weights and records of the
        # source follow the sections'.
        [switch]$Source,
        # With -Whole -Source: the decoder first (Kokoro.DecoderRun16.ps1, from asr, F0_curve and N_curve after the source's inputs),
        # its output written to the DDR workspace where the 10x front reads it instead of the input buffer.
        [switch]$Decoder,
        [ValidateSet('Accumulate','Constants')][string]$DecoderMoments='Accumulate',
        # Tile: depth-first. Every stage's weights, record and K/M/S stay resident in VTCM, and each block of BatchTiles
        # tiles runs through all 18 stages before the next: at step i, stage q of every branch processes block i - q, so
        # each stage reads exactly what the layer schedule gives it. Residual rings of 8 blocks and stage rings of 4;
        # interior steps run in a counted loop with ring slots computed in registers, the six steps at each end
        # unrolled; the tile-parallel bodies use every HVX thread. One section without fronts or tail, three kernels and
        # their mean, supplied AdaIN values, a power-of-two BatchTiles.
        [ValidateSet('Layer','Tile')][string]$Schedule='Layer',
        # How HVX workers wait for work and the main thread waits for them: QuRT futex traps, or polling the pool
        # with pause. Default: Spin for the tile schedule (dispatches microseconds apart), Futex otherwise.
        [ValidateSet('','Futex','Spin')][string]$PoolWait='',
        # Tile schedule: 0 runs every convolution on the main thread, which holds the matrix unit; 1 to 3 run them on
        # that HVX worker, which never takes the matrix lock.
        [ValidateRange(0,3)][int]$MatrixThread=0,
        # With MatrixThread: Main leaves the matrix lock with the main thread; Worker hands it to that worker for the
        # job (QuRT unlock on main before the workers start, try-lock in the worker, and the reverse at the end);
        # Convolution has the worker take and release it around every convolution.
        [ValidateSet('Main','Worker','Convolution')][string]$MatrixLock='Main',
        # With -Source: generate the source noise on the DSP from the seed and scale the input holds where z was.
        [switch]$SeededNoise,
        # Tile schedule: weight planes per convolution. 1 keeps only each stage's high weight plane resident (int8 weights
        # in the high bytes of the 16-bit weights file), two accumulator groups and the two-group combine.
        [ValidateSet(1,2)][int]$WeightPlanes=2,
        # Tile schedule: the controller contact. Each window fill reads its tile's controller value v (one int32 word,
        # v << 16) and applies K = K_base + P_K * v and M = M_base + P_M * v per channel (Q31 multiply, as K * x), with
        # K_base, M_base and S from the stage's supplied AdaIN values as before and P_K, P_M per stage from the
        # parameters input after the constants table. v = 0 is exactly the constants arithmetic.
        [switch]$ControllerContact,
        # Group the window fill's straight-line vector instructions into packets (Group-HexagonPackets) instead of one
        # instruction per packet.
        [switch]$VectorPackets,
        # Tile schedule: branches per stage. 3 runs a stage of all three branches together: one window fill dispatch and
        # one combine dispatch, each body repeated over the branches at fixed VTCM strides, and the three convolutions back
        # to back; each branch has its own windows and planes. 1 runs the 18 stages one at a time.
        [ValidateSet(1,3)][int]$BranchesPerStage=1,
        # Tile schedule: every stage keeps its own window, so each window tile is filled once. Consecutive blocks' windows
        # share two tiles (the last tile of block j and the first of block j + 1); they move from the end of the previous
        # window to its start, and the fill computes only the block's other tiles and the next block's first.
        [switch]$FillOnce)
    if($WeightPlanes -eq 1 -and $Schedule -ne 'Tile'){ throw 'One weight plane is a tile schedule option.' }
    if($FillOnce -and $Schedule -ne 'Tile'){ throw 'Filling each window tile once is a tile schedule option.' }
    $packets={ param([object[]]$Steps) $grouped=if($VectorPackets){ Group-HexagonPackets $Steps } else { $Steps }; $grouped }
    if($ControllerContact -and $Schedule -ne 'Tile'){ throw 'The controller contact is a tile schedule option.' }
    if($BranchesPerStage -ne 1 -and ($Schedule -ne 'Tile' -or $MatrixThread)){ throw 'Three branches per stage is a tile schedule option with the convolutions on the main thread.' }
    if($SeededNoise -and -not $Source){ throw 'Seeded noise is a source option.' }
    if(-not $PoolWait){ $PoolWait=if($Schedule -eq 'Tile'){'Spin'}else{'Futex'} }
    if($MatrixThread -and ($Schedule -ne 'Tile' -or $MatrixThread -ge $HvxThreads)){ throw 'MatrixThread names an HVX worker of the tile schedule.' }
    if($Schedule -eq 'Tile' -and ($Whole -or $Source -or $Decoder -or $Front -or $Tail -or $RuntimeFrames -or $StopAfterStage -ge 0 -or
        $Kernels.Count -ne 3 -or $AdaInMode -ne 'Constants' -or ($BatchTiles -band ($BatchTiles-1)) -or $Channels -ne 128)) {
        throw 'The tile schedule runs one 128-channel section of three kernels and their mean with supplied AdaIN values, a power-of-two block of tiles per step.'
    }
    if($RuntimeFrames -and ($Whole -or $Source -or $Decoder -or $Front -or $Tail -or $StopAfterStage -ge 0)) {
        throw 'Runtime frames currently admit complete residual stages only.'
    }
    . (Join-Path $PSScriptRoot 'Kokoro.ResBlockRun.ps1')
    foreach($file in '../kernels/Kokoro.GeneratorFront16.ps1','Kokoro.GeneratorTail16Run.ps1','../kernels/Kokoro.LeakyRelu16.ps1','../kernels/Kokoro.TailSpectrum16.ps1','../kernels/Kokoro.HmxConvPlanes.ps1','../kernels/Kokoro.PlaneCombine.ps1','../kernels/Kokoro.AdaInMoments16.ps1','../kernels/Kokoro.AdaInTurnsCoefficients.ps1','../kernels/Kokoro.AdaInSnakeTurns.ps1','../kernels/Kokoro.BranchMean16.ps1','../hexagon/Kokoro.DmaCopy.ps1','../kernels/Kokoro.StftWindow16.ps1','../kernels/Kokoro.StftPolar16.ps1','Kokoro.HarmonicStft16Run.ps1','../kernels/Kokoro.HarmonicSource16.ps1','Kokoro.HarmonicSource16Run.ps1','../kernels/Kokoro.HarPhaseMajor16.ps1','../kernels/Kokoro.AdaInLeaky16.ps1','../kernels/Kokoro.Decoder16.ps1','Kokoro.DecoderRun16.ps1') { . (Join-Path $PSScriptRoot $file) }
    if($Whole){
        if($StopAfterStage -ge 0 -or $Kernels.Count -ne 3){throw '-Whole runs both whole sections'}
        $upFramesWhole=[int](($Frames-1)/6); if(6*$upFramesWhole+1 -ne $Frames){throw 'Frames is not 6 m + 1'}
        $sections=@(@{Channels=256;Frames=$upFramesWhole;Front=$true;Tail=$false;Chained=$false;Suffix='_c256'},@{Channels=128;Frames=$Frames;Front=$true;Tail=$true;Chained=$true;Suffix='_c128'})
        if($Source){
            $sourceFrames=$Frames; $sourceLayout=Get-KokoroHarmonicSource16Layout -Frames $sourceFrames
            $tiles60=$sourceLayout.Tiles; $tiles10=[int][math]::Ceiling(($upFramesWhole+1)/32)
            $har60At=0L; $harPmAt=[long]([math]::Ceiling(2L*$tiles60*4096/4096)*4096); $sourceDdrBytes=[long]([math]::Ceiling(($harPmAt+2L*$tiles10*16384)/4096)*4096)
            $sections[0].HarReg=25; $sections[0].HarAt=$harPmAt; $sections[1].HarReg=25; $sections[1].HarAt=$har60At
        }
        if($Decoder){ if(-not $Source){throw '-Decoder needs -Whole -Source'}; $decIn=[int]((($Frames-1)/6)/20); if(20*$decIn -ne ($Frames-1)/6){throw 'The 10x frames are not 20 decoder frames each'}; $decLayout=Get-KokoroDecoder16Layout -Frames $decIn; $decSlot=$sourceDdrBytes; $sourceDdrBytes+=[long]([math]::Ceiling($decLayout.OutputBytes/4096)*4096) }
    } elseif($Source){ throw '-Source needs -Whole'
    } else { $sections=@(,@{Channels=$Channels;Frames=$Frames;Front=[bool]$Front;Tail=[bool]$Tail;Chained=$false;Suffix=''}) }
    # Binds one section's sizes and offsets in this scope (dot-sourced). Inputs, weights and records start at the given
    # bases; the DDR workspace offsets (r25-relative, 4096-aligned base) are absolute.
    $configure={param($sec,[long]$ddrBase,[long]$inBase,[long]$wBase,[long]$pBase)
    $Channels=$sec.Channels; $Frames=$sec.Frames; $Front=[switch]$sec.Front; $Tail=[switch]$sec.Tail; $chained=$sec.Chained; $sfx=$sec.Suffix
    $branches=$Kernels.Count; $withMean=$branches -eq 3
    if($Channels -ne 128 -and $Tail){throw '-Tail is 128-channel'}
    $front10=$Front -and $Channels -eq 256
    if($branches -eq 2){throw 'Two blocks have no stock combination here.'}
    if(-not $withMean -and $Tail){throw '-Tail follows the three-block stage'}
    $layout=Get-KokoroGenerator60x16Layout -Frames $Frames -BatchTiles $BatchTiles -Channels $Channels
    $harFromInput=-not $sec.ContainsKey('HarReg')
    $tileBytes=$layout.TileBytes; $recordBytes=$layout.RecordBytes; $blocksPerTile=$Channels/32; $kmsBytes=$(if($ControllerContact){20}else{12})*$Channels; $momentVectors=$Channels/8
    $tablesAt=32*$Channels; $ratiosAt=80*$Channels
    $tiles=$layout.Tiles; $tensorBytes=$layout.TensorBytes; $batch=$BatchTiles; $R=$layout.Regions; $planeStride=$layout.PlaneStride
    $offResidual=$R.Residual.Offset; $offConv=$R.ConvOutput.Offset; $offWin=$R.Window.Offset; $offLow=$R.WindowLow.Offset; $offPlanes=$R.Planes.Offset; $offWeights=$R.Weights.Offset
    $offSmall=$R.Small.Offset; $offParams=$offSmall+$layout.Small.Parameters; $offMoments=$offSmall+$layout.Small.Moments; $offInputMoments=$offSmall+$layout.Small.InputMoments; $offKms=$offSmall+$layout.Small.Kms
    $privateMoments=@(0,0,1,2) | ForEach-Object { $offSmall+$layout.Small.PrivateMoments+16*$Channels*$_ }
    $branchWeights=[long[]]::new($branches); $weightBytes=$wBase
    for($b=0;$b -lt $branches;$b++){ $branchWeights[$b]=$weightBytes; $weightBytes+=6L*2*$Channels*$Channels*$Kernels[$b] }
    $parameterBytes=$pBase+6*$branches*$recordBytes
    $stride=[int]([math]::Ceiling($tensorBytes/128)*128); $finalOffset=$ddrBase+2*$stride; $coefOffset=$finalOffset+$tensorBytes
    $scratchOffset=[long]([math]::Ceiling(($coefOffset+18*$kmsBytes)/4096)*4096); $outputBytes=192+$scratchOffset+131072
    $vtcmBytes=$layout.VtcmBytes; $inputBytes=$inBase+$tensorBytes
    $r0Base=20; $r0Offset=$inBase
    if($front10){
        # 256-channel front (tools/New-KokoroGeneratorFront10x16Fixture.ps1): input buffer = decoder output (512-channel
        # croutons), then phase-major har high and low planes (256-channel tiles).
        if(-not $withMean -or $StopAfterStage -ge 0){throw '-Front feeds the whole three-block stage'}
        $decFrames=[int]($Frames/10); if(10*$decFrames -ne $Frames){throw 'Frames is not 10 m'}
        $decTiles=[int][math]::Ceiling($decFrames/32); $qPairs=[int][math]::Ceiling(($decFrames+1)/2); $decBytes=$decTiles*32768L
        $inputBytes=$inBase+$(if($Decoder){0L}else{$decBytes})+$(if($harFromInput){2L*$tiles*$tileBytes}else{0L})
        if($harFromInput){ $harReg=20; $harAt=$inBase+$decBytes } else { $harReg=$sec.HarReg; $harAt=$sec.HarAt }
        $al64={param([long]$v) [long]([math]::Ceiling($v/65536)*65536)}
        $offFrontWeights=& $al64 $layout.VtcmBytes; $offFrontTables=$offFrontWeights+786432; $offUpA=$offFrontTables+163840; $offUpB=$offUpA+$decTiles*16384L
        $vtcmBytes=[math]::Max($vtcmBytes,(& $al64 ($offUpB+$decTiles*16384L)))
        $upHi=$R.Residual.Offset; $upLo=$upHi+($decTiles+2)*32768L
        if($upLo+($decTiles+2)*32768L -gt $R.Residual.Offset+$R.Residual.Bytes){throw 'ups[0] input planes exceed the residual region'}
        if([math]::Floor($upHi/4194304) -ne [math]::Floor(($upLo+($decTiles+2)*32768L-1)/4194304)){throw 'ups[0] input planes cross a 4 MiB VTCM boundary'}
        if((10*$qPairs+5)/16 -gt [math]::Floor($R.ConvOutput.Bytes/$tileBytes)){throw 'The interleave writes past the target region'}
        $noiseSlot=[long]([math]::Ceiling(($scratchOffset+131072)/4096)*4096); $r0Slot=$noiseSlot+[long]([math]::Ceiling($tensorBytes/4096)*4096)
        $outputBytes=192+$r0Slot+$tensorBytes; $r0Base=25; $r0Offset=$r0Slot
    }
    elseif($Front){
        if(-not $withMean -or $StopAfterStage -ge 0){throw '-Front feeds the whole three-block stage'}
        if($batch % 2){throw '-Front needs an even batch (ups[1] batches are half as many 256-channel tiles)'}
        $upFrames=[int](($Frames-1)/6)+1; if(6*($upFrames-1)+1 -ne $Frames){throw 'Frames is not 6 m + 1'}
        $upTiles=[int][math]::Ceiling($upFrames/32); $upBatch=$batch/2
        # Chained (-Whole): the ups[1] input planes come from the 10x section, not the input buffer.
        $inputBytes=$inBase+$(if($harFromInput){2L*$tiles*4096}else{0L})+$(if($chained){0L}else{2L*$upTiles*16384})
        if($harFromInput){ $harReg=20; $harAt=$inBase } else { $harReg=$sec.HarReg; $harAt=$sec.HarAt }
        $al64={param([long]$v) [long]([math]::Ceiling($v/65536)*65536)}
        $offFrontWeights=& $al64 $layout.VtcmBytes; $offFrontTables=$offFrontWeights+393216; $offUpPhase=$offFrontTables+65536
        $vtcmBytes=[math]::Max($vtcmBytes,(& $al64 ($offUpPhase+$upTiles*16384L)))
        if($R.Residual.Offset+2L*($upTiles+2)*16384 -gt 4194304){throw 'ups[1] input planes cross a 4 MiB VTCM boundary'}
        if(($tiles+4)*8192L -gt $R.ConvOutput.Bytes){throw 'The interleave needs four tiles of slack after the stage input'}
        $noiseSlot=[long]([math]::Ceiling(($scratchOffset+131072)/4096)*4096); $r0Slot=$noiseSlot+[long]([math]::Ceiling($tensorBytes/4096)*4096)
        $outputBytes=192+$r0Slot+$tensorBytes; $r0Base=25; $r0Offset=$r0Slot
    }
    $tailWeightOffset=$weightBytes; $tailParameterOffset=$parameterBytes
    if($Tail){
        if($StopAfterStage -ge 0){throw '-Tail runs only after the whole stage'}
        $tailLayout=Get-KokoroGeneratorTail16Layout -Frames $Frames
        $vtcmBytes=[math]::Max($vtcmBytes,$tailLayout.VtcmBytes); $weightBytes+=172032; $parameterBytes+=16384
        $pcmOffset=[long]([math]::Ceiling($outputBytes/256)*256); $outputBytes=$pcmOffset+$tailLayout.OutputBytes-256
    }
    if($front10){ $noiseWeightOffset=$weightBytes; $weightBytes+=6L*2*256*256*7; $frontWeightOffset=$weightBytes; $weightBytes+=196608L*2+10*786432L
        $noiseParameterOffset=$parameterBytes; $parameterBytes+=6*$recordBytes; $frontParameterOffset=$parameterBytes; $parameterBytes+=163840 }
    elseif($Front){ $noiseWeightOffset=$weightBytes; $weightBytes+=6L*32768*11; $frontWeightOffset=$weightBytes; $weightBytes+=1228800
        $noiseParameterOffset=$parameterBytes; $parameterBytes+=6*16384; $frontParameterOffset=$parameterBytes; $parameterBytes+=65536 }
    }
    # Place each section after the previous one, then bind the first. VTCM is shared: the job requests the largest.
    $bases=[Collections.Generic.List[long[]]]::new(); $ddrAt=$(if($Source){$sourceDdrBytes}else{0L}); $inAt=0L; $wAt=0L; $pAt=0L; $vtcmTotal=0L
    # Weight regions by part: Main is the path from x to PCM, Source the branch fed only by the excitation. Resblock
    # stages are W8 two-plane records (high plane, then low plane, Channels^2 K bytes each).
    $weightRegions=[Collections.Generic.List[object]]::new()
    foreach($sec in $sections){
        $bases.Add([long[]]@($ddrAt,$inAt,$wAt,$pAt)); . $configure $sec $ddrAt $inAt $wAt $pAt
        $vtcmTotal=[math]::Max($vtcmTotal,$vtcmBytes)
        for($b=0;$b -lt $branches;$b++){$weightRegions.Add([pscustomobject]@{Name="resblocks.c$Channels.k$($Kernels[$b])";Part='Main';Format='ResblockW16';Channels=$Channels;Kernel=$Kernels[$b];Offset=$branchWeights[$b];Bytes=6L*2*$Channels*$Channels*$Kernels[$b]})}
        if($Tail){$weightRegions.Add([pscustomobject]@{Name='tail';Part='Main';Format='Tail';Channels=$Channels;Kernel=7;Offset=$tailWeightOffset;Bytes=172032L})}
        if($front10){
            $weightRegions.Add([pscustomobject]@{Name='noise_res.0';Part='Source';Format='ResblockW16';Channels=256;Kernel=7;Offset=$noiseWeightOffset;Bytes=6L*2*256*256*7})
            $weightRegions.Add([pscustomobject]@{Name='noise_convs.0';Part='Source';Format='Front';Channels=256;Kernel=12;Offset=$frontWeightOffset;Bytes=393216L})
            $weightRegions.Add([pscustomobject]@{Name='ups.0';Part='Main';Format='Front';Channels=256;Kernel=20;Offset=$frontWeightOffset+393216;Bytes=10*786432L})
        } elseif($Front){
            $weightRegions.Add([pscustomobject]@{Name='noise_res.1';Part='Source';Format='ResblockW16';Channels=128;Kernel=11;Offset=$noiseWeightOffset;Bytes=6L*32768*11})
            $weightRegions.Add([pscustomobject]@{Name='noise_convs.1';Part='Source';Format='Front';Channels=128;Kernel=1;Offset=$frontWeightOffset;Bytes=49152L})
            $weightRegions.Add([pscustomobject]@{Name='ups.1';Part='Main';Format='Front';Channels=128;Kernel=12;Offset=$frontWeightOffset+49152;Bytes=1179648L})
        }
        $ddrAt=[long]([math]::Ceiling(($outputBytes-192)/4096)*4096); $inAt=$inputBytes; $wAt=$weightBytes; $pAt=$parameterBytes
    }
    $totalInput=$inputBytes; $totalWeights=$weightBytes; $totalParameters=$parameterBytes; $totalOutput=$outputBytes
    if($Source){
        $sourceIn=$totalInput; $sourceW=$totalWeights; $sourceP=$totalParameters
        $weightRegions.Add([pscustomobject]@{Name='source.stft';Part='Source';Format='Stft';Channels=22;Kernel=20;Offset=$sourceW;Bytes=[long]$sourceLayout.WeightBytes})
        $totalInput+=$sourceLayout.InputBytes; $totalWeights+=$sourceLayout.WeightBytes; $totalParameters+=$sourceLayout.ParameterBytes
        # The phase-major gather uses VTCM from 0: both 60x har planes, then both phase-major planes.
        $gHi=0L; $gLo=[long]([math]::Ceiling($tiles60*4096/65536)*65536); $gPmHi=2*$gLo; $gPmLo=$gPmHi+[long]([math]::Ceiling($tiles10*16384/65536)*65536)
        $vtcmTotal=[math]::Max($vtcmTotal,[math]::Max($sourceLayout.VtcmBytes,$gPmLo+$tiles10*16384L))
        if($Decoder){ $decInOff=$totalInput; $decWOff=$totalWeights; $decPOff=$totalParameters; $totalInput+=$decLayout.InputBytes; $totalWeights+=$decLayout.WeightBytes; $totalParameters+=$(if($DecoderMoments -eq 'Constants'){$decLayout.ConstantsParameterBytes}else{$decLayout.ParameterBytes}); $vtcmTotal=[math]::Max($vtcmTotal,$decLayout.VtcmBytes) }
    }
    $runtimeFramesOffset=$totalInput
    if($RuntimeFrames){$totalInput+=4}
    $bind={param([int]$i) $q=$bases[$i]; . $configure $sections[$i] $q[0] $q[1] $q[2] $q[3]}
    # Site tables live in DDR. Only the active site's ratios occupy the existing
    # moments scratch; K/M/S retain their existing addresses and extent.
    $siteByRecord=[Collections.Generic.Dictionary[long,object]]::new()
    $momentSites=[Collections.Generic.List[object]]::new(); $momentAt=0L; $kmsAt=0L
    $constantsTableOffset=$totalParameters
    for($section=0;$section -lt $sections.Count;$section++){
        . $bind $section
        $siteBlocks=@(for($bb=0;$bb -lt $branches;$bb++){@{Module='resblocks';Block=$(if($Channels -eq 256){$bb}else{3+$bb});Record=$pBase+6L*$bb*$recordBytes}})
        if($Front){$siteBlocks+=@{Module='noise_res';Block=$(if($front10){0}else{1});Record=$noiseParameterOffset}}
        foreach($siteBlock in $siteBlocks){for($st=0;$st -lt 6;$st++){
            $site=[pscustomobject]@{Index=$momentSites.Count;Name="generator.$($siteBlock.Module).$($siteBlock.Block).stage$st";
                Module=$siteBlock.Module;Block=$siteBlock.Block;Stage=$st;Width=$Channels;Frames=$Frames;
                Offset=$momentAt;Bytes=16L*$Channels;KmOffset=$kmsAt;KmBytes=12L*$Channels;
                RecordOffset=$siteBlock.Record+$st*$recordBytes;KmLayout='Turns'}
            $momentSites.Add($site); $siteByRecord.Add([long]$site.RecordOffset,$site)
            $momentAt+=$site.Bytes; $kmsAt+=$site.KmBytes
        }}
    }
    $exportOffset=[long]([math]::Ceiling($totalOutput/128)*128)
    if($AdaInMode -eq 'Export'){$totalOutput=$exportOffset+$momentAt+$kmsAt}
    if($AdaInMode -eq 'Constants'){$totalParameters+=$momentAt}
    # Controller contact inputs: per stage P_K[C] then P_M[C] (int32), then one controller word per tile.
    $contactOffset=$totalParameters; $controllerBytes=[long]([math]::Ceiling(4L*$tiles/128)*128)
    if($ControllerContact){$totalParameters+=18L*8*$Channels+$controllerBytes}
    if($Schedule -eq 'Tile'){
        # VTCM for the tile schedule: HMX windows and planes first (inside the first 1 MiB), then the rings, K/M/S and
        # records of all 18 stages, then their weights, resident for the whole job.
        $al={param([long]$v) [long]([math]::Ceiling($v/65536)*65536)}
        $tileStages=@(for($bb=0;$bb -lt 3;$bb++){for($st=0;$st -lt 6;$st++){
            [pscustomobject]@{Branch=$bb;Stage=$st;Pair=[int][math]::Floor($st/2);Half=$st%2;Dilation=@(1,3,5)[[int][math]::Floor($st/2)]
                WeightOffset=$branchWeights[$bb]+$st*2L*$Channels*$Channels*$Kernels[$bb];WeightBytes=[long]$WeightPlanes*$Channels*$Channels*$Kernels[$bb];RecordOffset=$pBase+(6L*$bb+$st)*$recordBytes}}})
        $tilePlanes=4L+2*($WeightPlanes-1)
        # With three branches per stage, branch b's windows and planes are b strides after branch 0's.
        $windowStride=& $al (($batch+2L)*$tileBytes); $planesStride=& $al ($tilePlanes*$batch*$tileBytes)
        # With FillOnce, stage s of branch b has window 3 s + b, so a stage's three branches are still one stride apart.
        $windowCount=if($FillOnce){18}else{$BranchesPerStage}
        $tileRegions=[ordered]@{}; $at=0L
        $hmxRegions=@(@('Window',($windowCount*$windowStride)),@('WindowLow',($windowCount*$windowStride)),@('Planes',($BranchesPerStage*$planesStride)))
        if($FillOnce){ $hmxRegions=@($hmxRegions[2],$hmxRegions[0],$hmxRegions[1]) }
        foreach($r in @($hmxRegions+@(@('Moments',(16L*$Channels)),@('Mean',([long]$batch*$tileBytes)),
            @('ResidualRings',(3L*8*$batch*$tileBytes)),@('StageRings',(9L*4*$batch*$tileBytes)),@('Kms',(18L*$kmsBytes)),@('Records',(18L*$recordBytes)),@('Controller',$(if($ControllerContact){$controllerBytes}else{0L}))))){ $tileRegions[$r[0]]=$at; $at+=& $al $r[1] }
        $tileWeightAt=[long[]]::new(18); foreach($g in $tileStages){ $tileWeightAt[6*$g.Branch+$g.Stage]=$at; $at+=$g.WeightBytes }
        $vtcmTotal=& $al $at
        if($vtcmTotal -gt 8388608){throw 'The tile schedule does not fit VTCM.'}
        if($FillOnce){
            # Eighteen windows do not fit the first 1 MiB; each lies inside one 1 MiB page (hexagon-v73-notes.md).
            if($tileRegions.Planes+($BranchesPerStage-1)*$planesStride+$tilePlanes*$batch*$tileBytes -gt 1048576){throw 'HMX planes must lie in the first 1 MiB of VTCM.'}
            foreach($name in 'Window','WindowLow'){ for($k=0;$k -lt 18;$k++){ $first=$tileRegions[$name]+$k*$windowStride; $last=$first+($batch+2L)*$tileBytes-1
                if([math]::Floor($first/1048576) -ne [math]::Floor($last/1048576)){throw 'A conv-input window crosses a 1 MiB VTCM boundary.'} } }
        }
        elseif($tileRegions.Planes+($BranchesPerStage-1)*$planesStride+$tilePlanes*$batch*$tileBytes -gt 1048576){throw 'HMX windows and planes must lie in the first 1 MiB of VTCM.'}
    }
    . $bind 0
    $vtcmBytes=$vtcmTotal

    $s=[Collections.Generic.List[hashtable]]::new()
    $calls=[Collections.Generic.List[object]]::new()
    $imm={param([int]$r,[long]$v) $u=[long]([uint32]($v -band 0xffffffffL));$s.Add(@{Op='lo';x=$r;i=($u -band 65535)});$s.Add(@{Op='hi';x=$r;i=($u -shr 16)})}
    $ptr={param([int]$r,[int]$baseReg,[long]$offset) $offsetReg=if($r -eq $baseReg){15}else{$r}; & $imm $offsetReg $offset;$s.Add(@{Op='add';d=$r;s=$baseReg;t=$offsetReg}) }
    $call={param([string]$label) $pc=@{Op='add-pc';d=14;i=0};$lo=@{Op='lo';x=15;i=0};$hi=@{Op='hi';x=15;i=0};$s.Add($pc);$s.Add($lo);$s.Add($hi);$s.Add(@{Op='add';d=14;s=14;t=15});$s.Add(@{Op='callr';s=14});$calls.Add(@{pc=$pc;low=$lo;high=$hi;label=$label})}
    $addr={param([int]$r,[string]$target) $pc=@{Op='add-pc';d=$r;i=0};$lo=@{Op='lo';x=15;i=0};$hi=@{Op='hi';x=15;i=0};$s.Add($pc);$s.Add($lo);$s.Add($hi);$s.Add(@{Op='add';d=$r;s=$r;t=15});$calls.Add(@{pc=$pc;low=$lo;high=$hi;label=$target})}
    $label={ $script:__u16++; "g16_$($script:__u16)" }
    $script:__u16=0
    $padBodies=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $liveFrames={param([int]$r)
        & $ptr $r 20 $runtimeFramesOffset; $s.Add(@{Op='load';d=$r;s=$r;Offset=0})
        & $imm 13 $Frames; $s.Add(@{Op='min';d=$r;s=$r;t=13}); $s.Add(@{Op='imm';d=13;i=2}); $s.Add(@{Op='max';d=$r;s=$r;t=13})
    }
    $padCapacity={param([long]$off,[int]$firstTile,[int]$tileCount,[int]$value)
        if(-not $RuntimeFrames){return}
        & $liveFrames 5
        & $imm 13 (32*$firstTile); $s.Add(@{Op='sub';d=5;s=5;t=13})
        $s.Add(@{Op='imm';d=13;i=0}); $s.Add(@{Op='max';d=5;s=5;t=13})
        & $imm 13 (32*$tileCount); $s.Add(@{Op='min';d=5;s=5;t=13})
        & $ptr 0 18 $off; & $imm 6 $tileCount
        $name="body_padcapacity_${Channels}_$value"
        [void]$padBodies.Add("$Channels,$value")
        & $call $name
    }
    $jump={param([string]$target) $s.Add(@{Op='eq';d=0;s=0;t=0}); $s.Add(@{Op='jump-p';u=0;Label=$target}) }

    # Performance counters (as Kokoro.Generator60xResidentRun.ps1; record at r25 + scratch).
    $pmuCategories=@('Setup','Dma','Coefficients','AdaInSnake','HmxConv','Combine','Moments','Mean','Sync','TileFix')
    $pmuCategories+=@('Source','Decoder','Tail','Boundary')
    $pmuStages=@('Setup','Decoder','Source','HarLayout','Front256','Noise256','Ups256','Res256_0','Res256_1','Res256_2','Mean256','Front128','Noise128','Ups128','Res128_0','Res128_1','Res128_2','Mean128','Tail','Exit')
    $pmuCategories+=@($pmuStages | ForEach-Object {"Stage.$_"})
    $pmuCategories+=@('Unmarked')
    $pmuStage=[string[]]@('Setup')
    $pmuOffset=$scratchOffset
    # Per-site records use unused scratch between the pool and its stacks.
    $pmuSiteOffset=8192; $pmuSites=@(); $pmuSiteRecordCount=0
    if($PmuEvents){
        $pmuAst=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$null,[ref]$null)
        $pmuCommands=@($pmuAst.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and
            $node.CommandElements[0] -is [Management.Automation.Language.VariableExpressionAst]},$true))
        $pmuSites=@(foreach($command in $pmuCommands){
            if($command.CommandElements[0].VariablePath.UserPath -cne 'mark' -or $command.CommandElements[1].Extent.Text -cne "'Unmarked'"){continue}
            $siteArgument=-1
            for($arg=0;$arg -lt $command.CommandElements.Count;$arg++){if($command.CommandElements[$arg] -is [Management.Automation.Language.CommandParameterAst] -and $command.CommandElements[$arg].ParameterName -ceq 'site'){$siteArgument=$arg+1;break}}
            if($siteArgument -lt 0){throw 'Unmarked PMU mark has no site index.'}
            $siteIndex=[int]$command.CommandElements[$siteArgument].SafeGetValue()
            $preceding=@($pmuCommands | Where-Object {$_.Extent.EndOffset -le $command.Extent.StartOffset -and $_.CommandElements[0].VariablePath.UserPath -cne 'mark'}) | Select-Object -Last 1
            if($siteIndex -eq 0){$preceding=$null}
            [pscustomobject]@{Index=$siteIndex;File=$PSCommandPath;
                MarkLine=$command.Extent.StartLineNumber;PrecedingLine=$(if($preceding){$preceding.Extent.StartLineNumber}else{$command.Extent.StartLineNumber});
                PrecedingStep=$(if($preceding){$preceding.Extent.Text}elseif($siteIndex -eq 0){'Caller Unmarked mark to syncht boundary (PMU instrumentation)'}else{'Block entry'})}
        })
        $pmuSites=@($pmuSites | Sort-Object Index)
        if($pmuSites.Count -eq 0 -or $pmuSites[0].Index -ne 0 -or (@($pmuSites.Index | Sort-Object -Unique).Count -ne $pmuSites.Count)){throw 'Unmarked PMU site indices must be unique and start at zero.'}
        # Keep indices stable when an optional source branch has no mark site.
        $pmuSiteRecordCount=1+$pmuSites[-1].Index
        if(256+64*$pmuCategories.Count -gt 4096 -or $pmuSiteOffset+64*$pmuSiteRecordCount -gt 61440){throw 'PMU records overlap the pool or stacks.'}
    }
    $mark={param([string]$category,[string]$nextStage='',[int]$site=-1)
        if(-not $PmuEvents){return}
        $c=[array]::IndexOf($pmuCategories,$category); if($c -lt 0){throw "Unknown PMU category $category"}
        $stageIndex=[array]::IndexOf($pmuCategories,"Stage.$($pmuStage[0])"); if($stageIndex -lt 0){throw 'Unknown PMU stage'}
        $recordOffset=256+64*$c
        if($category -ceq 'Unmarked'){if($site -cnotin $pmuSites.Index){throw 'Invalid Unmarked PMU site.'};$recordOffset=$pmuSiteOffset+64*$site}
        & $ptr 0 25 ($pmuOffset+$recordOffset); & $ptr 1 25 ($pmuOffset+256+64*$stageIndex); & $call 'body_pmu_mark'
        if($nextStage){$pmuStage[0]=$nextStage}
    }

    # HVX worker pool (as Kokoro.Generator60xResidentRun.ps1): block at r25 + scratch + 4096, stacks at
    # + 65536 - 4096 + 16384*k. Futex, HVX lock and unlock are the libqurt.a trap stubs (SDK 6.4.0.2
    # computev73 pic/libqurt.a 8e0ba5fd...); thread create/join/exit are imports.
    $poolOffset=$scratchOffset+4096; $stackOffset=$scratchOffset+65536
    # Spin waits poll the pool between pause(#16) instructions.
    $poolPause=16
    $futexWait={param([int]$addrReg,[int]$valueReg) $s.Add(@{Op='addi';d=1;s=$valueReg;i=0}); $s.Add(@{Op='addi';d=0;s=$addrReg;i=0}); $s.Add(@{Op='imm';d=3;i=0}); $s.Add(@{Op='imm';d=4;i=-1}); $s.Add(@{Op='imm';d=5;i=-1}); $s.Add(@{Op='trap0';i=0x20}) }
    # Tile-parallel call: arguments are VTCM offsets (r18-relative); perTile ones advance 8192 bytes per tile.
    # With -Moments the second argument is the job's moments record: each worker accumulates into its own
    # zeroed 2048-byte record, added into the job's after the join (wrapping int32 sums, order-free).
    # An argument may also be a ring descriptor (tile schedule): @{Base;Blocks;Block;Delta;Within}, set by $ringPointer
    # at the descriptor's tile plus the worker's first tile.
    # Publish the next pool sequence and wake the workers; then wait until every worker has reported that sequence.
    $wake={
        $s.Add(@{Op='syncht'})
        & $ptr 6 25 $poolOffset; $s.Add(@{Op='load';d=0;s=6;Offset=0}); $s.Add(@{Op='addi';d=0;s=0;i=1}); $s.Add(@{Op='store';s=6;t=0;Offset=0})
        if($PoolWait -eq 'Futex'){ $s.Add(@{Op='addi';d=0;s=6;i=0}); & $imm 1 ($HvxThreads-1); $s.Add(@{Op='trap0';i=0x11}) }
    }
    $join={
        for($k=1;$k -lt $HvxThreads;$k++){
            $wait=& $label; $done=& $label
            $s.Add(@{Op='label';Name=$wait})
            & $ptr 6 25 ($poolOffset+64*$k); & $ptr 7 25 $poolOffset; $s.Add(@{Op='load';d=8;s=6;Offset=20}); $s.Add(@{Op='load';d=9;s=7;Offset=0})
            $s.Add(@{Op='eq';d=0;s=8;t=9}); $s.Add(@{Op='jump-p';u=0;Label=$done})
            if($PoolWait -eq 'Futex'){ $s.Add(@{Op='addi';d=6;s=6;i=20}); & $futexWait 6 8 } else { $s.Add(@{Op='pause';i=$poolPause}) }
            & $jump $wait
            $s.Add(@{Op='label';Name=$done})
        }
    }
    $parallel={param([string]$body,[object[]]$off,[bool[]]$perTile,[int]$count,[switch]$Moments)
        $n=$off.Count
        $argument={param([int]$r,[int]$i,[int]$skip) if($off[$i] -is [hashtable]){ & $ringPointer $r $off[$i].Base $off[$i].Blocks $off[$i].Block $off[$i].Delta ($off[$i].Within+$skip) } else { & $ptr $r 18 $off[$i] } }
        if($HvxThreads -eq 1 -or $count -lt 2){ for($i=0;$i -lt $n;$i++){ & $argument $i $i 0 }; & $imm $n $count; & $call $body; return }
        $chunk=[int][math]::Ceiling($count/$HvxThreads)
        for($k=1;$k -lt $HvxThreads;$k++){
            $o=$k*$chunk; $c=[math]::Max(0,[math]::Min($chunk,$count-$o))
            if($c -gt 0 -and $Moments){ & $ptr 4 18 $privateMoments[$k]; $s.Add(@{Op='vxor';d=0;s=0;t=0}); for($v=0;$v -lt $momentVectors;$v++){$s.Add(@{Op='vstore';s=4;t=0;Offset=(128*($v%8))}); if($v%8 -eq 7 -and $v -lt $momentVectors-1){$s.Add(@{Op='addi';d=4;s=4;i=1024})}} }
            & $ptr 6 25 ($poolOffset+64*$k)
            if($c -gt 0){
                for($i=0;$i -lt $n;$i++){
                    if($off[$i] -is [hashtable]){ & $argument 0 $i $o }
                    else { $value=if($Moments -and $i -eq 1){$privateMoments[$k]}elseif($perTile[$i]){$off[$i]+$o*$tileBytes}else{$off[$i]}; & $ptr 0 18 $value }
                    $s.Add(@{Op='store';s=6;t=0;Offset=(4*$i)})
                }
                & $imm 0 $c; $s.Add(@{Op='store';s=6;t=0;Offset=(4*$n)})
                & $addr 0 $body; $s.Add(@{Op='store';s=6;t=0;Offset=44})
            }
            & $imm 0 $c; $s.Add(@{Op='store';s=6;t=0;Offset=48})
        }
        & $wake
        for($i=0;$i -lt $n;$i++){ & $argument $i $i 0 }; & $imm $n ([math]::Min($chunk,$count)); & $call $body
        & $join
        if($Moments){
            for($k=1;$k -lt $HvxThreads;$k++){
                if($k*$chunk -ge $count){ continue }
                for($half=0;$half -lt $momentVectors/8;$half++){
                    & $ptr 4 18 ($off[1]+1024*$half); & $ptr 5 18 ($privateMoments[$k]+1024*$half)
                    for($v=0;$v -lt 8;$v++){ $s.Add(@{Op='vload';d=0;s=4;Offset=(128*$v)}); $s.Add(@{Op='vload';d=1;s=5;Offset=(128*$v)}); $s.Add(@{Op='vadd-w';d=0;s=0;t=1}); $s.Add(@{Op='vstore';s=4;t=0;Offset=(128*$v)}) }
                }
            }
        }
    }
    # QuRT matrix lock traps (as Kokoro.HmxMatrixProbe.ps1): unlock2(0) is r0 = 0, r5 = 1; try-lock is r5 = 2.
    $matrixUnlock={ $s.Add(@{Op='imm';d=0;i=0}); $s.Add(@{Op='imm';d=5;i=1}); $s.Add(@{Op='trap0';i=0x1d}) }
    $matrixTryLock={ $s.Add(@{Op='imm';d=5;i=2}); $s.Add(@{Op='trap0';i=0x1d}) }
    $handOffMatrix=$MatrixThread -and $MatrixLock -ne 'Main'
    $poolStart={
        if($HvxThreads -eq 1){return}
        if($handOffMatrix){ & $matrixUnlock }
        & $ptr 4 25 $poolOffset; $s.Add(@{Op='vxor';d=0;s=0;t=0}); for($k=0;$k -lt 8;$k++){$s.Add(@{Op='vstore';s=4;t=0;Offset=(128*$k)})}
        & $ptr 6 25 $poolOffset; & $imm 0 0x4C4F4F50L; $s.Add(@{Op='store';s=6;t=0;Offset=8}); & $imm 0 $HvxThreads; $s.Add(@{Op='store';s=6;t=0;Offset=12})
        for($k=1;$k -lt $HvxThreads;$k++){
            & $ptr 6 25 ($poolOffset+64*$k); & $ptr 0 25 $poolOffset; $s.Add(@{Op='store';s=6;t=0;Offset=32})
            & $ptr 7 25 ($poolOffset+512+64*$k)
            & $imm 0 0x007F0000L; $s.Add(@{Op='store';s=7;t=0;Offset=16}); & $imm 0 0xFFFEFF00L; $s.Add(@{Op='store';s=7;t=0;Offset=20})
            & $imm 0 16384; $s.Add(@{Op='store';s=7;t=0;Offset=24}); & $ptr 0 25 ($stackOffset-4096+16384*$k); $s.Add(@{Op='store';s=7;t=0;Offset=28})
            $s.Add(@{Op='addi';d=0;s=6;i=24}); $s.Add(@{Op='addi';d=1;s=7;i=0}); & $addr 2 'hvx_worker'; $s.Add(@{Op='addi';d=3;s=6;i=0})
            $s.Add(@{Op='got-call';Import='qurt_thread_create';d=14})
            & $ptr 6 25 ($poolOffset+64*$k); $s.Add(@{Op='store';s=6;t=0;Offset=28})
        }
    }
    $poolStop={
        if($HvxThreads -eq 1){return}
        & $ptr 6 25 $poolOffset; $s.Add(@{Op='imm';d=0;i=1}); $s.Add(@{Op='store';s=6;t=0;Offset=4}); $s.Add(@{Op='syncht'})
        $s.Add(@{Op='load';d=0;s=6;Offset=0}); $s.Add(@{Op='addi';d=0;s=0;i=1}); $s.Add(@{Op='store';s=6;t=0;Offset=0})
        $s.Add(@{Op='addi';d=0;s=6;i=0}); & $imm 1 ($HvxThreads-1); $s.Add(@{Op='trap0';i=0x11})
        for($k=1;$k -lt $HvxThreads;$k++){
            & $ptr 6 25 ($poolOffset+64*$k); $s.Add(@{Op='load';d=0;s=6;Offset=24}); $s.Add(@{Op='addi';d=1;s=6;i=36})
            $s.Add(@{Op='got-call';Import='qurt_thread_join';d=14})
            & $ptr 6 25 ($poolOffset+64*$k); $s.Add(@{Op='store';s=6;t=0;Offset=40})
            if($handOffMatrix -and $k -eq $HvxThreads-1){ & $matrixTryLock }
        }
    }

    # DMA dest <- src, length bytes; r24 holds two 64-byte aligned descriptor slots in DDR.
    $dma={param([int]$destBase,[long]$destOff,[int]$srcBase,[long]$srcOff,[long]$length)
        if($length -lt 2 -or $length -ge 2*16777215){throw 'DMA length out of range'}
        & $ptr 1 $srcBase $srcOff; & $ptr 2 $destBase $destOff; & $imm 3 $length; $s.Add(@{Op='addi';d=0;s=24;i=0})
        foreach($step in @(New-KokoroDmaCopySteps -NoReturn)){$s.Add($step)}
        & $mark 'Dma'
    }
    $sync={ & $mark 'Unmarked' -site 0; $s.Add(@{Op='syncht'}); & $mark 'Sync' }
    # VTCM tiles <- one 32-bit pattern (0x80008000: x = 0 or the high-window zero; 0: the low-window zero).
    $fill={param([long]$off,[int]$count,[long]$pattern)
        & $ptr 4 18 $off; & $imm 6 $pattern; $s.Add(@{Op='vsplat';d=0;s=6}); & $imm 5 ($count*$tileBytes/128); $s.Add(@{Op='imm';d=7;i=0})
        $n=& $label; $s.Add(@{Op='label';Name=$n});$s.Add(@{Op='vstore';s=4;t=0;Offset=0});$s.Add(@{Op='addi';d=4;s=4;i=128});$s.Add(@{Op='addi';d=5;s=5;i=-1});$s.Add(@{Op='gtu';d=0;s=5;t=7});$s.Add(@{Op='jump-p';u=0;Label=$n})
        & $mark 'TileFix'
    }
    # VTCM tiles at destOff <- the tiles at srcOff, eight vectors at a time.
    $copyTiles={param([long]$destOff,[long]$srcOff,[int]$count)
        & $ptr 4 18 $srcOff; & $ptr 5 18 $destOff; & $imm 6 ($count*$tileBytes/1024); $s.Add(@{Op='imm';d=7;i=0})
        $n=& $label; $s.Add(@{Op='label';Name=$n})
        for($k=0;$k -lt 8;$k++){$s.Add(@{Op='vload';d=$k;s=4;Offset=(128*$k)})}; for($k=0;$k -lt 8;$k++){$s.Add(@{Op='vstore';s=5;t=$k;Offset=(128*$k)})}
        $s.Add(@{Op='addi';d=4;s=4;i=1024});$s.Add(@{Op='addi';d=5;s=5;i=1024});$s.Add(@{Op='addi';d=6;s=6;i=-1});$s.Add(@{Op='gtu';d=0;s=6;t=7});$s.Add(@{Op='jump-p';u=0;Label=$n})
        & $mark 'TileFix'
    }
    $zeroRecord={param([long]$off) & $ptr 4 18 $off; $s.Add(@{Op='vxor';d=0;s=0;t=0}); for($k=0;$k -lt $momentVectors;$k++){$s.Add(@{Op='vstore';s=4;t=0;Offset=(128*($k%8))}); if($k%8 -eq 7 -and $k -lt $momentVectors-1){$s.Add(@{Op='addi';d=4;s=4;i=1024})}} }
    $copyRecord={param([long]$destOff,[long]$srcOff) for($half=0;$half -lt $momentVectors/8;$half++){ & $ptr 4 18 ($srcOff+1024*$half); & $ptr 5 18 ($destOff+1024*$half); for($k=0;$k -lt 8;$k++){$s.Add(@{Op='vload';d=$k;s=4;Offset=(128*$k)})}; for($k=0;$k -lt 8;$k++){$s.Add(@{Op='vstore';s=5;t=$k;Offset=(128*$k)})} } }
    # Rows >= Frames of the tile at tileOff: every halfword of those rows <- value (0x8000 or 0).
    $padRows={param([long]$tileOff,[long]$value)
        if($Frames%32 -eq 0){return}
        # Each vector contains two rows: low/high halfwords of its 32 words.
        # Construct each row-pair mask once and reuse it across channel blocks.
        $firstPair=[int][math]::Floor(($Frames%32)/2)
        for($pair=$firstPair;$pair -lt 16;$pair++){
            $keep=if($pair -eq $firstPair -and $Frames%2){0x0000ffffL}else{0L}
            $padding=($value -bor ($value -shl 16)) -band (0xffffffffL -bxor $keep)
            & $imm 6 $keep; $s.Add(@{Op='vsplat';d=1;s=6})
            & $imm 8 $padding; $s.Add(@{Op='vsplat';d=2;s=8})
            for($block=0;$block -lt $blocksPerTile;$block++){
                & $ptr 4 18 ($tileOff+$block*2048+$pair*128)
                $s.Add(@{Op='vload';d=0;s=4;Offset=0}); $s.Add(@{Op='vand';d=0;s=0;t=1})
                $s.Add(@{Op='vor';d=0;s=0;t=2}); $s.Add(@{Op='vstore';s=4;t=0;Offset=0})
            }
        }
        & $mark 'TileFix'
    }
    $moments={param([long]$srcOff,[int]$count) if($AdaInMode -eq 'Constants'){return}; & $parallel "body_moments$sfx" @($srcOff,$offMoments) @($true,$false) $count -Moments; & $mark 'Moments' }

    # Checked resource wrapper of the frozen K=11 resblock runner (as the resident stage), with admission
    # sizes and the VTCM request changed.
    # The admitted config tile count (Kokoro.ResBlockRun.ps1) is the last section's: the harness passes the layout's Tiles.
    $wrapperSource=New-KokoroResBlockRunSteps -Frames $sections[-1].Frames -Kernel 11
    $base=@($wrapperSource.Steps);$start=-1
    for($i=0;$i -lt $base.Count;$i++){if($base[$i].Op -eq 'label' -and $base[$i].Name -eq 'connected_job'){$start=$i;break}}
    if($start -lt 0){throw 'Connected wrapper anchor changed'}
    $minimum=@(4,$totalInput,$totalWeights,$totalParameters,$totalOutput)
    $oldVtcm=[long]$wrapperSource.Layout.VtcmBytes
    $patched=@{request=0;check=0}
    for($i=0;$i -lt $start;$i++){
        $step=$base[$i].Clone()
        if($step.Op -eq 'lo' -and $step.x -eq 1 -and $i -ge 2 -and $base[$i-1].Op -eq 'load' -and $base[$i-1].s -eq 3){$a=[int](($base[$i-1].Offset-4)/8);$v=$minimum[$a]-1;$step.i=$v -band 65535;$base[$i+1]=$base[$i+1].Clone();$base[$i+1].i=$v -shr 16}
        elseif($step.Op -eq 'lo' -and $i+1 -lt $start -and $base[$i+1].Op -eq 'hi' -and $base[$i+1].x -eq $step.x){
            $value=[long]$step.i -bor ([long]$base[$i+1].i -shl 16); $new=$null
            if($step.x -eq 1 -and $value -eq $oldVtcm){$new=$vtcmBytes;$patched.request++}
            elseif($step.x -eq 15 -and $value -eq $oldVtcm-1){$new=$vtcmBytes-1;$patched.check++}
            if($null -ne $new){$step.i=$new -band 65535;$base[$i+1]=$base[$i+1].Clone();$base[$i+1].i=$new -shr 16}
        }
        $s.Add($step)
    }
    if($patched.request -ne 1 -or $patched.check -ne 1){throw "VTCM size anchors changed ($($patched.request),$($patched.check))"}

    # Job. r18 VTCM, r20 input, r21 weights, r22 parameter records, r23 output/telemetry,
    # r24 descriptor slots, r25 aligned DDR workspace, r26:27 start ticks.
    $s.Add(@{Op='label';Name='connected_job'});$s.Add(@{Op='allocframe';Bytes=256})
    foreach($r in 16,18,20,22,24,26){$s.Add(@{Op='store-d';s=29;t=$r;Offset=(($r-16)*4)})}
    $s.Add(@{Op='addi';d=24;s=29;i=(64+63)}); & $imm 0 -64; $s.Add(@{Op='and';d=24;s=24;t=0})
    $s.Add(@{Op='addi';d=25;s=23;i=191}); & $imm 0 -128; $s.Add(@{Op='and';d=25;s=25;t=0})
    $s.Add(@{Op='hwticks';d=26})
    if($PmuEvents){
        $evtcfg=0L;$evtcfg1=0L;$pmucfg=0L
        for($i=0;$i -lt 4;$i++){ $evtcfg=$evtcfg -bor (([long]$PmuEvents[$i] -band 0xff) -shl (8*$i)); $evtcfg1=$evtcfg1 -bor (([long]$PmuEvents[$i+4] -band 0xff) -shl (8*$i)) }
        for($i=0;$i -lt 8;$i++){ $pmucfg=$pmucfg -bor ((([long]$PmuEvents[$i] -shr 8) -band 3) -shl (2*$i)) }
        & $ptr 4 25 $pmuOffset; $s.Add(@{Op='vxor';d=0;s=0;t=0}); for($k=0;$k -lt [math]::Ceiling((256+64*$pmuCategories.Count)/128);$k++){$s.Add(@{Op='vstore';s=4;t=0;Offset=(128*($k%8))}); if($k%8 -eq 7){$s.Add(@{Op='addi';d=4;s=4;i=1024})}}
        & $ptr 4 25 ($pmuOffset+$pmuSiteOffset); for($k=0;$k -lt [math]::Ceiling(64*$pmuSiteRecordCount/128);$k++){$s.Add(@{Op='vstore';s=4;t=0;Offset=(128*($k%8))}); if($k%8 -eq 7){$s.Add(@{Op='addi';d=4;s=4;i=1024})}}
        & $ptr 4 25 ($pmuOffset+64); $s.Add(@{Op='store-d';s=4;t=26;Offset=32}); $s.Add(@{Op='upcycle';d=6}); $s.Add(@{Op='store-d';s=4;t=6;Offset=40})
        $s.Add(@{Op='imm';d=5;i=2}); $s.Add(@{Op='trap0';i=0x55}); & $ptr 2 25 $pmuOffset; $s.Add(@{Op='store';s=2;t=0;Offset=4})
        foreach($w in @(@(4,$pmucfg),@(5,$evtcfg),@(10,$evtcfg1))){ $s.Add(@{Op='imm';d=0;i=$w[0]}); & $imm 1 $w[1]; $s.Add(@{Op='imm';d=2;i=1}); $s.Add(@{Op='trap0';i=0x4a}) }
        $s.Add(@{Op='imm';d=0;i=0}); $s.Add(@{Op='imm';d=1;i=1}); $s.Add(@{Op='imm';d=2;i=0}); $s.Add(@{Op='trap0';i=0x4a})
        & $ptr 2 25 $pmuOffset; & $imm 4 $pmucfg; $s.Add(@{Op='store';s=2;t=4;Offset=16}); & $imm 4 $evtcfg; $s.Add(@{Op='store';s=2;t=4;Offset=20}); & $imm 4 $evtcfg1; $s.Add(@{Op='store';s=2;t=4;Offset=24})
        & $mark 'Setup'
    }
    # Front sequences (-Front): noise_convs[1] onto a zero residual, then after noise_res[1] the ups[1] phases, interleave,
    # reflection, and the add into the stage input, kept in DDR for the three branches.
    $fillVectors={param([long]$off,[int]$vectors,[long]$pattern)
        & $ptr 4 18 $off; & $imm 6 $pattern; $s.Add(@{Op='vsplat';d=0;s=6}); & $imm 5 $vectors; $s.Add(@{Op='imm';d=7;i=0})
        $n=& $label; $s.Add(@{Op='label';Name=$n});$s.Add(@{Op='vstore';s=4;t=0;Offset=0});$s.Add(@{Op='addi';d=4;s=4;i=128});$s.Add(@{Op='addi';d=5;s=5;i=-1});$s.Add(@{Op='gtu';d=0;s=5;t=7});$s.Add(@{Op='jump-p';u=0;Label=$n})
    }
    $frontNoise={
        & $mark 'Unmarked' -site 1; & $fill $offResidual $tiles 0x80008000L
        & $dma 18 $offFrontWeights 21 $frontWeightOffset 49152
        & $dma 18 $offFrontTables 22 $frontParameterOffset 65536
        for($start=0;$start -lt $tiles;$start+=$batch){
            $count=[math]::Min($batch,$tiles-$start); $first=[math]::Max(0,$start-1); $last=[math]::Min($tiles,$start+$count+1)
            if($start -eq 0){ & $fillVectors $offWin 32 0x80008000L; & $fillVectors $offLow 32 0 }
            if($start+$count -eq $tiles){ & $fillVectors ($offWin+($count+1)*4096) 32 0x80008000L; & $fillVectors ($offLow+($count+1)*4096) 32 0 }
            & $dma 18 ($offWin+($first-$start+1)*4096) $harReg ($harAt+$first*4096L) (($last-$first)*4096L)
            & $dma 18 ($offLow+($first-$start+1)*4096) $harReg ($harAt+$tiles*4096L+$first*4096L) (($last-$first)*4096L)
            & $ptr 0 18 ($offWin+4096); & $ptr 1 18 ($offLow+4096); & $ptr 2 18 $offFrontWeights; & $ptr 3 18 $offFrontTables; & $imm 4 $count; & $ptr 5 18 $offPlanes
            & $call 'body_conv_front_noise'; & $mark 'HmxConv'; & $mark 'Unmarked' -site 2; & $sync
            & $parallel "body_combine_residual$sfx" @($offPlanes,($offResidual+$start*8192),($offFrontTables+8192)) @($true,$true,$false) $count
            & $mark 'Combine'
        }
        & $mark 'Unmarked' -site 3; & $padRows ($offResidual+($tiles-1)*8192) 0x8000
    }
    $frontUps={
        & $mark 'Unmarked' -site 4; & $sync; & $dma 25 $noiseSlot 18 $offResidual $tensorBytes
        $upHi=$offResidual; $upLo=$offResidual+($upTiles+2)*16384L; $harBytes=2L*$tiles*4096
        & $fillVectors $upHi 128 0x80008000L; & $fillVectors ($upHi+($upTiles+1)*16384L) 128 0x80008000L
        & $fillVectors $upLo 128 0; & $fillVectors ($upLo+($upTiles+1)*16384L) 128 0
        if($chained){
            # -Whole: LeakyReLU(0.1) of the 10x mean (same per-channel scales, 41 tiles of 256 channels; rows past its frames
            # hold x = 0, so ups[1]'s extra input frame is zero) straight into the ups[1] input planes.
            if($chainTiles -ne $upTiles){throw 'The 10x mean does not cover the ups[1] input tiles'}
            & $dma 18 $offConv 25 $chainOffset ($upTiles*16384L)
            & $ptr 0 18 $offConv; & $ptr 1 18 ($upHi+16384); & $ptr 2 18 ($upLo+16384); & $imm 3 ($upTiles*128)
            & $call 'body_leaky_up'; & $mark 'Combine'; & $mark 'Unmarked' -site 5; & $sync
        }
        else { & $dma 18 ($upHi+16384) 20 ($inBase+$harBytes) ($upTiles*16384L); & $dma 18 ($upLo+16384) 20 ($inBase+$harBytes+$upTiles*16384L) ($upTiles*16384L) }
        for($c=0;$c -lt 3;$c++){
            & $dma 18 $offFrontWeights 21 ($frontWeightOffset+49152+$c*393216L) 393216
            for($start=0;$start -lt $upTiles;$start+=$upBatch){
                $count=[math]::Min($upBatch,$upTiles-$start)
                & $ptr 0 18 ($upHi+($start+1)*16384L); & $ptr 1 18 ($upLo+($start+1)*16384L); & $ptr 2 18 $offFrontWeights; & $ptr 3 18 ($offFrontTables+16384+12288*$c); & $imm 4 $count; & $ptr 5 18 $offPlanes
                & $call 'body_conv_front_up'; & $mark 'HmxConv'; & $mark 'Unmarked' -site 6; & $sync
                & $ptr 0 18 $offPlanes; & $ptr 1 18 ($offUpPhase+$start*16384L); & $ptr 2 18 ($offFrontTables+53248+2048*$c-1024); & $imm 3 $count
                & $call 'body_combine_conv256'; & $mark 'Combine'; & $mark 'Unmarked' -site 7; & $sync
            }
            & $ptr 0 18 $offUpPhase; & $ptr 1 18 $offConv; & $imm 2 $c; & $imm 3 ([math]::Ceiling($upFrames/2))
            & $call 'body_front_interleave'; & $mark 'Combine'; & $mark 'Unmarked' -site 8; & $sync
        }
        # Reflection: padded frame 0 is padded frame 2 (even halfwords of row pairs 0 and 1 of tile 0).
        & $imm 6 0xFFFF0000L; $s.Add(@{Op='vsplat';d=30;s=6}); & $imm 6 0x0000FFFFL; $s.Add(@{Op='vsplat';d=31;s=6})
        for($blk=0;$blk -lt 4;$blk++){
            & $ptr 4 18 ($offConv+2048*$blk); $s.Add(@{Op='vload';d=0;s=4;Offset=0}); $s.Add(@{Op='vload';d=1;s=4;Offset=128})
            $s.Add(@{Op='vand';d=0;s=0;t=30}); $s.Add(@{Op='vand';d=1;s=1;t=31}); $s.Add(@{Op='vor';d=0;s=0;t=1}); $s.Add(@{Op='vstore';s=4;t=0;Offset=0})
        }
        & $mark 'Unmarked' -site 9; & $sync; & $dma 18 $offResidual 25 $noiseSlot $tensorBytes
        & $ptr 0 18 $offConv; & $ptr 1 18 $offResidual; & $ptr 2 18 ($offFrontTables+59392); & $imm 3 $tiles
        & $call 'body_front_add'; & $mark 'Combine'
        & $mark 'Unmarked' -site 10; & $padRows ($offResidual+($tiles-1)*8192) 0x8000
        & $mark 'Unmarked' -site 11; & $sync; & $dma 25 $r0Slot 18 $offResidual $tensorBytes
    }
    $front10Noise={
        & $mark 'Unmarked' -site 12; & $fill $offResidual $tiles 0x80008000L
        & $dma 18 $offFrontWeights 21 $frontWeightOffset 393216
        & $dma 18 $offFrontTables 22 $frontParameterOffset 163840
        for($start=0;$start -lt $tiles;$start+=$batch){
            $count=[math]::Min($batch,$tiles-$start); $first=[math]::Max(0,$start-1); $last=[math]::Min($tiles,$start+$count+1)
            if($start -eq 0){ & $mark 'Unmarked' -site 13; & $fill $offWin 1 0x80008000L; & $mark 'Unmarked' -site 14; & $fill $offLow 1 0 }
            if($start+$count -eq $tiles){ & $mark 'Unmarked' -site 15; & $fill ($offWin+($count+1)*$tileBytes) 1 0x80008000L; & $mark 'Unmarked' -site 16; & $fill ($offLow+($count+1)*$tileBytes) 1 0 }
            & $dma 18 ($offWin+($first-$start+1)*$tileBytes) $harReg ($harAt+$first*[long]$tileBytes) (($last-$first)*[long]$tileBytes)
            & $dma 18 ($offLow+($first-$start+1)*$tileBytes) $harReg ($harAt+$tiles*[long]$tileBytes+$first*[long]$tileBytes) (($last-$first)*[long]$tileBytes)
            & $ptr 0 18 ($offWin+$tileBytes); & $ptr 1 18 ($offLow+$tileBytes); & $ptr 2 18 $offFrontWeights; & $ptr 3 18 $offFrontTables; & $imm 4 $count; & $ptr 5 18 $offPlanes
            & $call 'body_conv_front10_noise'; & $mark 'HmxConv'; & $mark 'Unmarked' -site 17; & $sync
            & $parallel "body_combine_residual$sfx" @($offPlanes,($offResidual+$start*$tileBytes),($offFrontTables+12288)) @($true,$true,$false) $count
            & $mark 'Combine'
        }
        & $mark 'Unmarked' -site 18; & $padRows ($offResidual+($tiles-1)*$tileBytes) 0x8000
    }
    $front10Ups={
        & $mark 'Unmarked' -site 19; & $sync; & $dma 25 $noiseSlot 18 $offResidual $tensorBytes
        # Decoder output into the C region, LeakyReLU(0.1) into the ups[0] input planes (zero halo tiles).
        if($Decoder){ & $dma 18 $offConv 25 $decSlot $decBytes } else { & $dma 18 $offConv 20 $inBase $decBytes }
        & $mark 'Unmarked' -site 20; & $fill $upHi 2 0x80008000L; & $mark 'Unmarked' -site 21; & $fill ($upHi+($decTiles+1)*32768L) 2 0x80008000L; & $mark 'Unmarked' -site 22; & $fill $upLo 2 0; & $mark 'Unmarked' -site 23; & $fill ($upLo+($decTiles+1)*32768L) 2 0
        & $ptr 0 18 $offConv; & $ptr 1 18 ($upHi+32768); & $ptr 2 18 ($upLo+32768); & $imm 3 ($decTiles*256)
        & $call 'body_leaky_up'; & $mark 'Unmarked' -site 24; & $sync
        for($r=0;$r -lt 10;$r++){
            & $dma 18 $offFrontWeights 21 ($frontWeightOffset+393216+$r*786432L) 786432
            & $ptr 0 18 ($upHi+32768); & $ptr 1 18 ($upLo+32768); & $ptr 2 18 $offFrontWeights; & $ptr 3 18 ($offFrontTables+16384+12288*$r); & $imm 4 $decTiles; & $ptr 5 18 $offPlanes
            & $call 'body_conv_front10_up'; & $mark 'HmxConv'; & $mark 'Unmarked' -site 25; & $sync
            & $parallel "body_combine_conv$sfx" @($offPlanes,$(if($r%2){$offUpB}else{$offUpA}),($offFrontTables+139264+1024*$r-1024)) @($true,$true,$false) $decTiles
            & $mark 'Combine'
            if($r%2){ & $mark 'Unmarked' -site 26; & $sync; & $ptr 0 18 $offUpA; & $ptr 1 18 $offConv; & $imm 2 (($r-1)/2); & $imm 3 $qPairs; & $ptr 4 18 $offUpB; & $call 'body_front10_interleave'; & $mark 'Combine'; & $mark 'Unmarked' -site 27; & $sync }
        }
        & $dma 18 $offResidual 25 $noiseSlot $tensorBytes
        & $ptr 0 18 $offConv; & $ptr 1 18 $offResidual; & $ptr 2 18 ($offFrontTables+149504); & $imm 3 $tiles
        & $call 'body_front10_add'; & $mark 'Combine'
        & $mark 'Unmarked' -site 28; & $padRows ($offResidual+($tiles-1)*$tileBytes) 0x8000
        & $mark 'Unmarked' -site 29; & $sync; & $dma 25 $r0Slot 18 $offResidual $tensorBytes
    }
    & $poolStart
    $stopped=$false
    if($Decoder){ & $mark 'Boundary' 'Decoder'; $decJob=Add-KokoroDecoder16JobSteps -Steps $s -Calls $calls -Frames $decIn -InputBase 20 -InputOffset $decInOff -WeightsBase 21 -WeightsOffset $decWOff -TablesBase 22 -TablesOffset $decPOff -OutputBase 25 -OutputOffset $decSlot -Moments $DecoderMoments; & $mark 'Decoder' 'Setup'; & $mark 'Unmarked' -site 30; & $sync }
    if($Source){
        & $mark 'Boundary' 'Source'
        Add-KokoroHarmonicSource16JobSteps -Steps $s -Calls $calls -Frames $sourceFrames -InputBase 20 -InputOffset $sourceIn -WeightsBase 21 -WeightsOffset $sourceW -TablesBase 22 -TablesOffset $sourceP -HarBase 25 -HarOffset $har60At -SeededNoise:$SeededNoise
        & $mark 'Source' 'HarLayout'
        & $mark 'Unmarked' -site 31; & $sync
        & $dma 18 $gHi 25 $har60At ($tiles60*4096L); & $dma 18 $gLo 25 ($har60At+$tiles60*4096L) ($tiles60*4096L)
        & $fillVectors $gPmHi ($tiles10*128) 0x80008000L; & $fillVectors $gPmLo ($tiles10*128) 0
        & $mark 'Unmarked' -site 32; & $sync
        $phaseTileCount=[int][math]::Floor($upFramesWhole/32)
        if(-not $RuntimeFrames -and $phaseTileCount -gt 0){
            & $parallel 'body_har_phase_major_tiles' @($gHi,$gLo,$gPmHi,$gPmLo,$gPmHi) @($false,$false,$true,$true,$false) $phaseTileCount
        }
        # Complete output tiles are independent; retain the existing row body for the partial tile.
        if($RuntimeFrames -or $upFramesWhole%32){
        & $imm 0 $(if($RuntimeFrames){$upFramesWhole}else{$upFramesWhole%32}); & $ptr 1 18 $gHi; & $ptr 2 18 $gLo; & $ptr 3 18 $gPmHi; & $ptr 4 18 $gPmLo; & $imm 5 $(if($RuntimeFrames){0}else{32*$phaseTileCount})
        & $call 'body_har_phase_major'
        }
        & $imm 0 1; & $ptr 1 18 $gHi; & $ptr 2 18 $gLo; & $ptr 3 18 $gPmHi; & $ptr 4 18 $gPmLo; & $imm 5 $upFramesWhole
        & $call 'body_har_phase_major_last'
        & $mark 'Unmarked' -site 33; & $sync
        & $dma 25 $harPmAt 18 $gPmHi ($tiles10*16384L); & $dma 25 ($harPmAt+$tiles10*16384L) 18 $gPmLo ($tiles10*16384L)
        & $mark 'Unmarked' -site 34; & $sync
    }
    # Tile schedule (see -Schedule). A step moves a block of $batch tiles: at step i, stage q of every branch processes
    # block i - q. A block operand is a constant block index (the unrolled end steps) or $null, the runtime step in r17
    # (free in every body this schedule calls). Ring slots are block & (ring blocks - 1), each $batch contiguous tiles.
    $blockBytes=[long]$batch*$tileBytes
    $blockShift=[int][math]::Round([math]::Log($blockBytes,2))
    $blockCount=[int][math]::Ceiling($tiles/$batch)
    $blockTiles={param([int]$block) [int][math]::Min($batch,$tiles-$block*$batch)}
    # Register r <- tile `within` of block (block + delta) in a ring.
    $ringPointer={param([int]$r,[long]$ringBase,[int]$ringBlocks,$block,[int]$delta,[int]$within)
        if($null -ne $block){ & $ptr $r 18 ($ringBase+(($block+$delta) -band ($ringBlocks-1))*$blockBytes+$within*[long]$tileBytes); return }
        $s.Add(@{Op='addi';d=$r;s=17;i=$delta}); & $imm 15 ($ringBlocks-1); $s.Add(@{Op='and';d=$r;s=$r;t=15})
        $s.Add(@{Op='asl-i';d=$r;s=$r;i=$blockShift}); & $imm 15 ($ringBase+$within*[long]$tileBytes); $s.Add(@{Op='add';d=$r;s=$r;t=15}); $s.Add(@{Op='add';d=$r;s=$r;t=18})
    }
    $ring={param([long]$ringBase,[int]$ringBlocks,$block,[int]$delta,[int]$within) @{Base=$ringBase;Blocks=$ringBlocks;Block=$block;Delta=$delta;Within=$within}}
    # Controller contact: register r <- the controller word of tile `within` of block (block + delta), one word per tile.
    $batchShift=[int][math]::Round([math]::Log($batch,2))
    $controllerPointer={param([int]$r,$block,[int]$delta,[int]$within)
        if($null -ne $block){ & $ptr $r 18 ($tileRegions.Controller+4L*(($block+$delta)*$batch+$within)); return }
        $s.Add(@{Op='addi';d=$r;s=17;i=$delta}); $s.Add(@{Op='asl-i';d=$r;s=$r;i=($batchShift+2)})
        & $imm 15 ($tileRegions.Controller+4L*$within); $s.Add(@{Op='add';d=$r;s=$r;t=15}); $s.Add(@{Op='add';d=$r;s=$r;t=18})
    }
    $dmaRegisters={param([long]$length) & $imm 3 $length; $s.Add(@{Op='addi';d=0;s=24;i=0}); foreach($step in @(New-KokoroDmaCopySteps -NoReturn)){$s.Add($step)} }
    # Segmented tile-parallel call: segment k runs on HVX thread k (0 the main thread) with its own arguments (VTCM
    # offsets or ring descriptors) and tile count; an optional Extra argument reaches the body in r5 (pool slot 56).
    $dispatch={param([string]$body,[object[]]$segments)
        if($HvxThreads -lt 3 -or $segments.Count -gt $HvxThreads){throw 'A segmented dispatch needs one HVX thread per segment, at least three.'}
        $value={param([int]$r,$a)
            if($a -is [hashtable] -and $a.Controller){ & $controllerPointer $r $a.Block $a.Delta $a.Within }
            elseif($a -is [hashtable]){ & $ringPointer $r $a.Base $a.Blocks $a.Block $a.Delta $a.Within } else { & $ptr $r 18 $a } }
        $n=$segments[0].Arguments.Count
        for($k=1;$k -lt $HvxThreads;$k++){
            & $ptr 6 25 ($poolOffset+64*$k)
            $c=if($k -lt $segments.Count){$segments[$k].Count}else{0}
            if($c -gt 0){
                for($i=0;$i -lt $n;$i++){ & $value 0 $segments[$k].Arguments[$i]; $s.Add(@{Op='store';s=6;t=0;Offset=(4*$i)}) }
                if($segments[$k].Contains('Extra')){ & $value 0 $segments[$k].Extra; $s.Add(@{Op='store';s=6;t=0;Offset=56}) }
                & $imm 0 $c; $s.Add(@{Op='store';s=6;t=0;Offset=(4*$n)})
                & $addr 0 $body; $s.Add(@{Op='store';s=6;t=0;Offset=44})
            }
            & $imm 0 $c; $s.Add(@{Op='store';s=6;t=0;Offset=48})
        }
        & $wake
        for($i=0;$i -lt $n;$i++){ & $value $i $segments[0].Arguments[$i] }
        if($segments[0].Contains('Extra')){ & $value 5 $segments[0].Extra }
        & $imm $n $segments[0].Count; & $call $body
        & $join
    }
    # Stage q of a branch at step i processes block i - q: a constant block, or at run time r17 + (k - q) for its block + k.
    # With three branches per stage $g is branch 0's stage; branch b's windows, planes, rings, K/M/S and records lie at fixed
    # strides from branch 0's, so one fill and one combine body cover all three (see $branchBodies).
    $tileStage={param($g,[int]$q,$block)
        $index=6*$g.Branch+$g.Stage; $grouped=$BranchesPerStage -gt 1
        $kAt=$tileRegions.Kms+$index*$kmsBytes; $rAt=$tileRegions.Records+$index*$recordBytes
        $residualBase=$tileRegions.ResidualRings+$g.Branch*8L*$blockBytes; $stageBase=$tileRegions.StageRings+(3L*$g.Branch+$g.Pair)*4*$blockBytes
        $sourceBase=if($g.Half -eq 0){$residualBase}else{$stageBase}; $sourceBlocks=if($g.Half -eq 0){8}else{4}
        $delta={param([int]$k) if($null -ne $block){$k}else{$k-$q}}
        $count=if($null -ne $block){& $blockTiles $block}else{$batch}
        $isFirst=$null -ne $block -and $block -eq 0; $isLast=$null -ne $block -and $block -eq $blockCount-1
        $winAt=$tileRegions.Window; $lowAt=$tileRegions.WindowLow
        if($FillOnce){ $winAt+=(3L*$g.Stage+$g.Branch)*$windowStride; $lowAt+=(3L*$g.Stage+$g.Branch)*$windowStride }
        # FillOnce after the first block: positions 0 and 1 are the previous window's positions batch and batch + 1.
        $carry=$FillOnce -and -not $isFirst
        for($b=0;$b -lt $BranchesPerStage;$b++){
            $w=$b*$windowStride
            if($isFirst){ & $fill ($winAt+$w) 1 0x80008000L; & $fill ($lowAt+$w) 1 0 }
            if($carry){ & $copyTiles ($winAt+$w) ($winAt+$w+$batch*[long]$tileBytes) 2; & $copyTiles ($lowAt+$w) ($lowAt+$w+$batch*[long]$tileBytes) 2 }
            if($isLast){ & $fill ($winAt+$w+($count+1)*[long]$tileBytes) 1 0x80008000L; & $fill ($lowAt+$w+($count+1)*[long]$tileBytes) 1 0 }
        }
        # Window positions: 0 the previous block's last tile, 1..count this block, count + 1 the next block's first tile.
        # One dispatch fills the window: each halo tile is its own segment, the block's tiles split over the other threads.
        $fillSegment={param([int]$k,[int]$within,[int]$position,[int]$tilesInSegment)
            $segment=@{Count=$tilesInSegment;Arguments=@((& $ring $sourceBase $sourceBlocks $block (& $delta $k) $within),($winAt+$position*[long]$tileBytes),($lowAt+$position*[long]$tileBytes),$kAt)}
            if($ControllerContact){ $segment.Extra=@{Controller=$true;Block=$block;Delta=(& $delta $k);Within=$within} }
            $segment }
        $segments=[Collections.Generic.List[object]]::new()
        if(-not $isFirst -and -not $carry){ $segments.Add((& $fillSegment -1 ($batch-1) 0 1)) }
        $from=if($carry){1}else{0}
        if($count -gt $from){
            $parts=$HvxThreads-$(if($isFirst -or $carry){0}else{1})-$(if($isLast){0}else{1}); $chunk=[int][math]::Ceiling(($count-$from)/$parts)
            for($o=$from;$o -lt $count;$o+=$chunk){ $segments.Add((& $fillSegment 0 $o (1+$o) ([math]::Min($chunk,$count-$o)))) }
        }
        if(-not $isLast){ $segments.Add((& $fillSegment 1 0 ($count+1) 1)) }
        & $dispatch $(if($grouped){"body_turns3_h$($g.Half)$sfx"}else{"body_turns$sfx"}) $segments.ToArray()
        & $mark 'AdaInSnake'
        if($null -ne $block){
            $position=($tiles-1)-$block*$batch+1
            for($b=0;$b -lt $BranchesPerStage;$b++){
                $w=$b*$windowStride
                if($position -ge 0 -and $position -le $count+1){ & $padRows ($winAt+$w+$position*[long]$tileBytes) 0x8000; & $padRows ($lowAt+$w+$position*[long]$tileBytes) 0 }
            }
        }
        & $sync
        $convBody="body_conv_b$($g.Branch)_d$(if($g.Half -eq 0){$g.Dilation}else{1})$sfx"
        if($grouped){
            for($b=0;$b -lt 3;$b++){
                $at=$index+6*$b; $w=$b*$windowStride
                & $ptr 0 18 ($winAt+$w+$tileBytes); & $ptr 1 18 ($lowAt+$w+$tileBytes); & $ptr 2 18 $tileWeightAt[$at]; & $ptr 3 18 ($tileRegions.Records+$at*$recordBytes+$tablesAt); & $imm 4 $count; & $ptr 5 18 ($tileRegions.Planes+$b*$planesStride)
                & $call "body_conv_b$($g.Branch+$b)_d$(if($g.Half -eq 0){$g.Dilation}else{1})$sfx"
            }
        } elseif($MatrixThread){
            # The worker's pool record: r0 to r4 in slots 0 to 16, r5 in slot 56; every other worker gets no work.
            for($k=1;$k -lt $HvxThreads;$k++){
                & $ptr 6 25 ($poolOffset+64*$k)
                if($k -eq $MatrixThread){
                    $slots=@(@(0,($winAt+$tileBytes)),@(4,($lowAt+$tileBytes)),@(8,$tileWeightAt[$index]),@(12,($rAt+$tablesAt)),@(56,$tileRegions.Planes))
                    foreach($slot in $slots){ & $ptr 0 18 $slot[1]; $s.Add(@{Op='store';s=6;t=0;Offset=$slot[0]}) }
                    & $imm 0 $count; $s.Add(@{Op='store';s=6;t=0;Offset=16})
                    & $addr 0 $convBody; $s.Add(@{Op='store';s=6;t=0;Offset=44})
                }
                & $imm 0 $(if($k -ne $MatrixThread){0}elseif($MatrixLock -eq 'Convolution'){2}else{1}); $s.Add(@{Op='store';s=6;t=0;Offset=48})
            }
            & $wake; & $join
        } else {
            & $ptr 0 18 ($winAt+$tileBytes); & $ptr 1 18 ($lowAt+$tileBytes); & $ptr 2 18 $tileWeightAt[$index]; & $ptr 3 18 ($rAt+$tablesAt); & $imm 4 $count; & $ptr 5 18 $tileRegions.Planes
            & $call $convBody
        }
        & $mark 'HmxConv'
        & $sync
        $targetBase=if($g.Half -eq 0){$stageBase}else{$residualBase}; $targetBlocks=if($g.Half -eq 0){4}else{8}
        & $parallel "$(if($g.Half -eq 0){'body_combine_conv'}else{'body_combine_residual'})$(if($grouped){'3'})$sfx" @($tileRegions.Planes,(& $ring $targetBase $targetBlocks $block (& $delta 0) 0),($rAt+$ratiosAt)) @($true,$true,$false) $count
        & $mark 'Combine'
        $targetStride=if($g.Half -eq 0){12L*$blockBytes}else{8L*$blockBytes}
        for($b=0;$b -lt $BranchesPerStage;$b++){
            if($isLast){ & $padRows ($targetBase+$b*$targetStride+($block -band ($targetBlocks-1))*$blockBytes+($count-1)*[long]$tileBytes) 0x8000 }
        }
    }
    # Step i: load input block i + 1 into every branch's residual ring, run every branch's stages, then the mean of block i - 5.
    $tileStep={param($step)
        if($null -eq $step -or $step+1 -lt $blockCount){
            for($bb=0;$bb -lt 3;$bb++){
                $ringBase=$tileRegions.ResidualRings+$bb*8L*$blockBytes
                if($null -ne $step){ & $dma 18 ($ringBase+(($step+1) -band 7)*$blockBytes) 20 ($r0Offset+($step+1)*$blockBytes) ((& $blockTiles ($step+1))*[long]$tileBytes) }
                else {
                    $s.Add(@{Op='addi';d=1;s=17;i=1}); $s.Add(@{Op='asl-i';d=1;s=1;i=$blockShift}); & $imm 15 $r0Offset; $s.Add(@{Op='add';d=1;s=1;t=15}); $s.Add(@{Op='add';d=1;s=1;t=20})
                    & $ringPointer 2 $ringBase 8 $null 1 0
                    & $dmaRegisters $blockBytes
                }
            }
            & $mark 'Dma'
        }
        for($bb=0;$bb -lt 3/$BranchesPerStage;$bb++){ for($q=0;$q -lt 6;$q++){
            $block=if($null -ne $step){$step-$q}else{$null}
            if($null -ne $block -and ($block -lt 0 -or $block -ge $blockCount)){continue}
            & $tileStage $tileStages[6*$bb+$q] $q $block
        }}
        $block=if($null -ne $step){$step-5}else{$null}
        if($null -ne $block -and ($block -lt 0 -or $block -ge $blockCount)){return}
        $count=if($null -ne $block){& $blockTiles $block}else{$batch}
        $meanDelta=if($null -ne $block){0}else{-5}
        $branchRings=@(for($bb=0;$bb -lt 3;$bb++){ & $ring ($tileRegions.ResidualRings+$bb*8L*$blockBytes) 8 $block $meanDelta 0 })
        & $parallel "body_mean$sfx" @($branchRings[0],$branchRings[1],$branchRings[2],$tileRegions.Mean) @($true,$true,$true,$true) $count
        & $mark 'Mean'
        & $sync
        if($null -ne $block){ & $dma 25 ($finalOffset+$block*$blockBytes) 18 $tileRegions.Mean ($count*[long]$tileBytes) }
        else {
            & $ptr 1 18 $tileRegions.Mean
            $s.Add(@{Op='addi';d=2;s=17;i=-5}); $s.Add(@{Op='asl-i';d=2;s=2;i=$blockShift}); & $imm 15 $finalOffset; $s.Add(@{Op='add';d=2;s=2;t=15}); $s.Add(@{Op='add';d=2;s=2;t=25})
            & $dmaRegisters $blockBytes; & $mark 'Dma'
        }
    }
    $tileSection={
        # Setup: every stage's record, weights and supplied AdaIN values, its K/M/S computed once.
        foreach($g in $tileStages){
            $index=6*$g.Branch+$g.Stage; $rAt=$tileRegions.Records+$index*$recordBytes
            & $dma 18 $rAt 22 $g.RecordOffset $recordBytes
            & $dma 18 $tileWeightAt[$index] 21 $g.WeightOffset $g.WeightBytes
            $site=$siteByRecord[[long]$g.RecordOffset]
            & $dma 18 $tileRegions.Moments 22 ($constantsTableOffset+$site.Offset) $site.Bytes
            & $ptr 0 18 $tileRegions.Moments; & $ptr 1 18 $rAt; & $ptr 2 18 ($tileRegions.Kms+$index*$kmsBytes); & $call "body_constant$sfx"; & $mark 'Coefficients'
            if($ControllerContact){ & $dma 18 ($tileRegions.Kms+$index*$kmsBytes+12L*$Channels) 22 ($contactOffset+$index*8L*$Channels) (8L*$Channels) }
        }
        if($ControllerContact){ & $dma 18 $tileRegions.Controller 22 ($contactOffset+18L*8*$Channels) $controllerBytes }
        for($bb=0;$bb -lt 3;$bb++){ & $dma 18 ($tileRegions.ResidualRings+$bb*8L*$blockBytes) 20 $r0Offset ((& $blockTiles 0)*[long]$tileBytes) }
        & $mark 'Boundary' "Res${Channels}_0"
        # Steps 0..5 and blockCount-2..blockCount+4 are unrolled: they hold the first block, the last two and the partial wave.
        for($step=0;$step -lt 6;$step++){ & $tileStep $step }
        # The interior steps count in r17, not LC1: the worker join can wait in a QuRT futex trap, and LC1 did not
        # survive it (the loop ended after a varying number of steps).
        & $imm 17 6
        $steps=& $label; $stepsDone=& $label
        $s.Add(@{Op='label';Name=$steps})
        & $tileStep $null
        $s.Add(@{Op='addi';d=17;s=17;i=1})
        & $imm 15 ($blockCount-2); $s.Add(@{Op='eq';d=0;s=17;t=15}); $s.Add(@{Op='jump-p';u=0;Label=$stepsDone}); & $jump $steps
        $s.Add(@{Op='label';Name=$stepsDone})
        for($step=$blockCount-2;$step -lt $blockCount+5;$step++){ & $tileStep $step }
    }
    for($section=0;$section -lt $sections.Count;$section++){
    if($section -gt 0){ $chainOffset=$finalOffset; $chainTiles=$tiles; . $bind $section }
    & $mark 'Boundary' "Front$Channels"
    if($Schedule -eq 'Tile'){ . $tileSection; continue }
    # Blocks: noise_res[1] first with -Front (index -1: its own weights and records, input computed in VTCM, kernel 11
    # bodies of branch 2), then the stage's branches.
    $blocks=[Collections.Generic.List[object]]::new()
    if($front10){ $blocks.Add(@{B=-1;K=7;W=$noiseWeightOffset;P=$noiseParameterOffset;Body=1}) }
    elseif($Front){ $blocks.Add(@{B=-1;K=11;W=$noiseWeightOffset;P=$noiseParameterOffset;Body=2}) }
    for($bb=0;$bb -lt $branches;$bb++){ $blocks.Add(@{B=$bb;K=$Kernels[$bb];W=$branchWeights[$bb];P=$pBase+$bb*6L*$recordBytes;Body=$bb}) }
    foreach($blk in $blocks){
        if($stopped){break}
        $b=$blk.B; $K=$blk.K
        if($b -ge 0){ & $mark 'Boundary' "Res${Channels}_$b" }
        if($b -lt 0 -and $front10){ & $front10Noise } elseif($b -lt 0){ & $frontNoise } else { & $dma 18 $offResidual $r0Base $r0Offset $tensorBytes }
        if($b -lt 0){ & $mark 'Boundary' "Noise$Channels" }
        if($RuntimeFrames){ & $mark 'Unmarked' -site 35; & $sync; & $padCapacity $offResidual 0 $tiles 0x8000 }
        if($AdaInMode -ne 'Constants'){
            if($b -le 0){ & $zeroRecord $offMoments; & $moments $offResidual $tiles; if($b -eq 0){ & $copyRecord $offInputMoments $offMoments } }
            else { & $copyRecord $offMoments $offInputMoments }
        }
        for($p=0;$p -lt 3 -and -not $stopped;$p++){
            $dilation=@(1,3,5)[$p]
            foreach($half in 0,1){
                if($stopped){continue}
                $st=2*$p+$half
                & $dma 18 $offParams 22 ($blk.P+$st*$recordBytes) $recordBytes
                & $dma 18 $offWeights 21 ($blk.W+$st*2L*$Channels*$Channels*$K) (2L*$Channels*$Channels*$K)
                $site=$siteByRecord[[long]($blk.P+$st*$recordBytes)]
                if($AdaInMode -eq 'Constants'){& $dma 18 $offMoments 22 ($constantsTableOffset+$site.Offset) $site.Bytes}
                elseif($AdaInMode -eq 'Export'){& $dma 23 ($exportOffset+$site.Offset) 18 $offMoments $site.Bytes}
                & $ptr 0 18 $offMoments; & $ptr 1 18 $offParams; & $ptr 2 18 $offKms
                if($AdaInMode -eq 'Constants'){& $call "body_constant$sfx"}
                else {
                    if($RuntimeFrames){ & $liveFrames 3 }else{ & $imm 3 $Frames }
                    & $call "body_coeff$sfx"; & $mark 'Coefficients'
                }
                if($AdaInMode -eq 'Export'){& $dma 23 ($exportOffset+$momentAt+$site.KmOffset) 18 $offKms $site.KmBytes}
                if($b -ge 0){ & $dma 25 ($coefOffset+($b*6+$st)*$kmsBytes) 18 $offKms $kmsBytes }
                if($AdaInMode -ne 'Constants'){& $zeroRecord $offMoments}
                $convSource=if($half -eq 0){$offResidual}else{$offConv}
                $convLabel="body_conv_b$($blk.Body)_d$(if($half -eq 0){$dilation}else{1})$sfx"
                for($start=0;$start -lt $tiles;$start+=$batch){
                    $count=[math]::Min($batch,$tiles-$start)
                    $first=[math]::Max(0,$start-1);$last=[math]::Min($tiles,$start+$count+1)
                    if($start -eq 0){ & $mark 'Unmarked' -site 36; & $fill $offWin 1 0x80008000L; & $mark 'Unmarked' -site 37; & $fill $offLow 1 0 }
                    if($start+$count -eq $tiles){ & $mark 'Unmarked' -site 38; & $fill ($offWin+($count+1)*$tileBytes) 1 0x80008000L; & $mark 'Unmarked' -site 39; & $fill ($offLow+($count+1)*$tileBytes) 1 0 }
                    & $parallel "body_turns$sfx" @(($convSource+$first*$tileBytes),($offWin+($first-$start+1)*$tileBytes),($offLow+($first-$start+1)*$tileBytes),$offKms) @($true,$true,$true,$false) ($last-$first)
                    & $mark 'AdaInSnake'
                    if($RuntimeFrames){
                        & $padCapacity ($offWin+($first-$start+1)*$tileBytes) $first ($last-$first) 0x8000
                        & $padCapacity ($offLow+($first-$start+1)*$tileBytes) $first ($last-$first) 0
                    }
                    if($last -eq $tiles){ & $mark 'Unmarked' -site 40; & $padRows ($offWin+($tiles-$start)*$tileBytes) 0x8000; & $mark 'Unmarked' -site 41; & $padRows ($offLow+($tiles-$start)*$tileBytes) 0 }
                    & $mark 'Unmarked' -site 42; & $sync
                    if($b -ge 0 -and $b*6+$st -eq $StopAfterStage -and $start -eq 0 -and $DumpPoint -eq 'Windows'){ & $dma 25 $finalOffset 18 $offWin (($batch+2)*[long]$tileBytes); & $dma 25 ($finalOffset+($batch+2)*[long]$tileBytes) 18 $offLow (($batch+2)*[long]$tileBytes); $stopped=$true; break }
                    & $ptr 0 18 ($offWin+$tileBytes); & $ptr 1 18 ($offLow+$tileBytes); & $ptr 2 18 $offWeights; & $ptr 3 18 ($offParams+$tablesAt); & $imm 4 $count; & $ptr 5 18 $offPlanes
                    & $call $convLabel; & $mark 'HmxConv'
                    & $mark 'Unmarked' -site 43; & $sync
                    if($b -ge 0 -and $b*6+$st -eq $StopAfterStage -and $start -eq 0 -and $DumpPoint -eq 'Planes'){ & $dma 25 $finalOffset 18 $offPlanes (6L*$planeStride); $stopped=$true; break }
                    $hasLast=($start+$count -eq $tiles)
                    if($half -eq 0){
                        & $parallel "body_combine_conv$sfx" @($offPlanes,($offConv+$start*$tileBytes),($offParams+$ratiosAt)) @($true,$true,$false) $count
                        & $mark 'Combine'
                        if($hasLast){ & $mark 'Unmarked' -site 44; & $padRows ($offConv+($tiles-1)*$tileBytes) 0x8000 }
                        if($RuntimeFrames){ & $padCapacity ($offConv+$start*$tileBytes) $start $count 0x8000 }
                        & $moments ($offConv+$start*$tileBytes) $count
                    } else {
                        & $parallel "body_combine_residual$sfx" @($offPlanes,($offResidual+$start*$tileBytes),($offParams+$ratiosAt)) @($true,$true,$false) $count
                        & $mark 'Combine'
                        if($hasLast){ & $mark 'Unmarked' -site 45; & $padRows ($offResidual+($tiles-1)*$tileBytes) 0x8000 }
                        if($RuntimeFrames){ & $padCapacity ($offResidual+$start*$tileBytes) $start $count 0x8000 }
                        if($p -lt 2){ & $moments ($offResidual+$start*$tileBytes) $count }
                    }
                }
                if($b -ge 0 -and $b*6+$st -eq $StopAfterStage -and -not $stopped){
                    & $mark 'Unmarked' -site 46; & $sync; & $dma 25 $finalOffset 18 $(if($half -eq 0){$offConv}else{$offResidual}) $tensorBytes; $stopped=$true
                }
            }
        }
        if($b -lt 0 -and -not $stopped){ & $mark 'Boundary' "Ups$Channels" }
        if($b -lt 0 -and -not $stopped -and $front10){ & $front10Ups }
        elseif($b -lt 0 -and -not $stopped){ & $frontUps }
        elseif($b -lt $branches-1 -and -not $stopped){ & $mark 'Unmarked' -site 47; & $sync; & $dma 25 ($ddrBase+$b*$stride) 18 $offResidual $tensorBytes }
    }
    # One block: its output is the final tensor.
    if(-not $stopped -and -not $withMean){ & $mark 'Unmarked' -site 48; & $sync; & $dma 25 $finalOffset 18 $offResidual $tensorBytes }
    # Three-branch mean in two chunks: branches 0 and 1 come back from DDR into the free C region.
    if(-not $stopped -and $withMean){
    & $mark 'Boundary' "Mean$Channels"
    & $mark 'Unmarked' -site 49; & $sync
    $chunk=[int][math]::Ceiling($tiles/2)
    for($j=0;$j*$chunk -lt $tiles;$j++){
        $chunkTiles=[math]::Min($chunk,$tiles-$j*$chunk)
        & $dma 18 $offConv 25 ($ddrBase+$j*$chunk*$tileBytes) ($chunkTiles*$tileBytes)
        & $dma 18 ($offConv+$chunk*$tileBytes) 25 ($ddrBase+$stride+$j*$chunk*$tileBytes) ($chunkTiles*$tileBytes)
        & $parallel "body_mean$sfx" @($offConv,($offConv+$chunk*$tileBytes),($offResidual+$j*$chunk*$tileBytes),$offConv) @($true,$true,$true,$true) $chunkTiles
        & $mark 'Mean'; & $mark 'Unmarked' -site 50; & $sync
        & $dma 25 ($finalOffset+$j*$chunk*$tileBytes) 18 $offConv ($chunkTiles*$tileBytes)
    }
    }
    if($Tail){
        & $mark 'Boundary' 'Tail'
        & $mark 'Unmarked' -site 51; & $sync
        Add-KokoroGeneratorTail16JobSteps -Steps $s -Calls $calls -Frames $Frames -InputBase 25 -InputOffset $finalOffset -WeightsBase 21 -WeightsOffset $tailWeightOffset -TablesBase 22 -TablesOffset $tailParameterOffset -PcmBase 23 -PcmOffset $pcmOffset
        & $mark 'Tail' 'Exit'
    }
    }
    & $poolStop
    & $mark 'Boundary' 'Exit'
    if($PmuEvents){
        $s.Add(@{Op='imm';d=0;i=0}); $s.Add(@{Op='imm';d=1;i=0}); $s.Add(@{Op='imm';d=2;i=0}); $s.Add(@{Op='trap0';i=0x4a})
        & $ptr 2 25 $pmuOffset; & $imm 4 0x31554D50L; $s.Add(@{Op='store';s=2;t=4;Offset=0})
    }
    $s.Add(@{Op='hwticks';d=0});$s.Add(@{Op='store-d';s=23;t=26;Offset=0});$s.Add(@{Op='store-d';s=23;t=0;Offset=8})
    $s.Add(@{Op='sub';d=0;s=25;t=23});& $imm 1 $finalOffset;$s.Add(@{Op='add';d=0;s=0;t=1});$s.Add(@{Op='store';s=23;t=0;Offset=40})
    $s.Add(@{Op='imm';d=0;i=$(if($Tail -or $GenericHarness -or -not $withMean){1}else{19})});$s.Add(@{Op='store';s=23;t=0;Offset=44})
    foreach($r in 16,18,20,22,24,26){$s.Add(@{Op='load-d';d=$r;s=29;Offset=(($r-16)*4)})}
    $s.Add(@{Op='dealloc-return'})

    $bodies=[Collections.Generic.List[object]]::new()
    for($section=0;$section -lt $sections.Count;$section++){
    if($sections.Count -gt 1){ . $bind $section }
    $bodies.Add(@("body_turns$sfx",@(& $packets @(New-KokoroAdaInSnakeTurnsSteps -TurnsBits 22 -Channels $Channels -LabelPrefix "adainsnaketurns$sfx" -ControllerContact:$ControllerContact))))
    if($AdaInMode -eq 'Constants'){
        $bodies.Add(@("body_constant$sfx",@(New-KokoroAdaInConstantCoefficientsLoopSteps -Channels $Channels -Turns -LabelPrefix "turnsconstant$sfx")))
    } else {
        $bodies.Add(@("body_moments$sfx",@(New-KokoroAdaInMoments16Steps -Channels $Channels -LabelPrefix "adainmoments16$sfx")))
        $bodies.Add(@("body_coeff$sfx",@(New-KokoroAdaInTurnsCoefficientsSteps -Channels $Channels -LabelPrefix "turnscoeff$sfx")))
    }
    $combineGroups=if($WeightPlanes -eq 2){@{Groups=3;Group3Shifts=$true}}else{@{Groups=2}}
    $convPlanes=if($WeightPlanes -eq 2){@{WeightPlanes=2}}else{@{WeightPlanes=1;TableGroups=3}}
    $bodies.Add(@("body_combine_conv$sfx",@(New-KokoroPlaneCombineSteps -Mode Conv -Channels $Channels @combineGroups -PlaneStride $planeStride -LabelPrefix "combineconv$sfx")))
    $bodies.Add(@("body_combine_residual$sfx",@(New-KokoroPlaneCombineSteps -Mode Residual -Channels $Channels @combineGroups -PlaneStride $planeStride -LabelPrefix "combineresidual$sfx")))
    if($BranchesPerStage -gt 1){
        # A body over three branches: the inner body for branch 0 with the caller's r0 to r5, then for branches 1 and 2
        # with each argument advanced by its branch stride (bytes; 0 keeps it). Arguments live in the frame between calls.
        $branchBodies={param([string]$name,[string]$inner,[long[]]$strides)
            $w=[Collections.Generic.List[hashtable]]::new()
            $w.Add(@{Op='allocframe';Bytes=32}); for($k=0;$k -lt 6;$k++){ $w.Add(@{Op='store';s=29;t=$k;Offset=(4*$k)}) }
            for($b=0;$b -lt 3;$b++){
                if($b -gt 0){
                    for($k=0;$k -lt 6;$k++){
                        $w.Add(@{Op='load';d=$k;s=29;Offset=(4*$k)})
                        if($strides[$k]){ $u=[long]([uint32](($b*$strides[$k]) -band 0xffffffffL)); $w.Add(@{Op='lo';x=15;i=($u -band 65535)}); $w.Add(@{Op='hi';x=15;i=($u -shr 16)}); $w.Add(@{Op='add';d=$k;s=$k;t=15}) }
                    }
                }
                $pc=@{Op='add-pc';d=14;i=0}; $lo=@{Op='lo';x=15;i=0}; $hi=@{Op='hi';x=15;i=0}
                $w.Add($pc); $w.Add($lo); $w.Add($hi); $w.Add(@{Op='add';d=14;s=14;t=15}); $w.Add(@{Op='callr';s=14}); $calls.Add(@{pc=$pc;low=$lo;high=$hi;label=$inner})
            }
            $w.Add(@{Op='dealloc-return'})
            , @($name,$w.ToArray())
        }
        # Fill: source ring, window, low window, K/M/S, count, controller. Combine: planes, target ring, record, count.
        $bodies.Add((& $branchBodies "body_turns3_h0$sfx" "body_turns$sfx" @((8L*$blockBytes),$windowStride,$windowStride,(6L*$kmsBytes),0L,0L)))
        $bodies.Add((& $branchBodies "body_turns3_h1$sfx" "body_turns$sfx" @((12L*$blockBytes),$windowStride,$windowStride,(6L*$kmsBytes),0L,0L)))
        $bodies.Add((& $branchBodies "body_combine_conv3$sfx" "body_combine_conv$sfx" @($planesStride,(12L*$blockBytes),(6L*$recordBytes),0L,0L,0L)))
        $bodies.Add((& $branchBodies "body_combine_residual3$sfx" "body_combine_residual$sfx" @($planesStride,(8L*$blockBytes),(6L*$recordBytes),0L,0L,0L)))
    }
    $bodies.Add(@("body_mean$sfx",@(New-KokoroBranchMean16Steps -Channels $Channels -LabelPrefix "branchmean16$sfx")))
    for($b=0;$b -lt $branches;$b++){foreach($d in 1,3,5){$bodies.Add(@("body_conv_b${b}_d$d$sfx",@(New-KokoroHmxConvPlanesSteps -InputChannels $Channels -OutputChannels $Channels -Kernel $Kernels[$b] -Dilation $d @convPlanes -PlaneStride $planeStride -LabelPrefix "g16_b${b}_d$d$sfx")))}}
    if($front10){
        $bodies.Add(@('body_conv_front10_noise',@(New-KokoroHmxConvPlanesSteps -InputChannels 256 -OutputChannels 256 -Kernel 3 -Dilation 1 -WeightPlanes 2 -PlaneStride $planeStride -LabelPrefix 'g16tn')))
        $bodies.Add(@('body_conv_front10_up',@(New-KokoroHmxConvPlanesSteps -InputChannels 512 -OutputChannels 256 -Kernel 3 -Dilation 1 -WeightPlanes 2 -PlaneStride $planeStride -LabelPrefix 'g16tu')))
        $bodies.Add(@('body_leaky_up',@(New-KokoroLeakyRelu16Steps -Slope 0.1 -LabelPrefix 'leakyup')))
        $bodies.Add(@('body_front10_interleave',@(New-KokoroPhaseInterleaveSteps -Phases 10 -Channels 256)))
        $bodies.Add(@('body_front10_add',@(New-KokoroResidualAdd16Steps -Channels 256)))
    }
    elseif($Front){
        $bodies.Add(@('body_conv_front_noise',@(New-KokoroHmxConvPlanesSteps -InputChannels 64 -OutputChannels 128 -Kernel 3 -Dilation 1 -WeightPlanes 2 -PlaneStride $planeStride -LabelPrefix 'g16fn')))
        $bodies.Add(@('body_conv_front_up',@(New-KokoroHmxConvPlanesSteps -InputChannels 256 -OutputChannels 256 -Kernel 3 -Dilation 1 -WeightPlanes 2 -PlaneStride $planeStride -LabelPrefix 'g16fu')))
        $bodies.Add(@('body_combine_conv256',@(New-KokoroPlaneCombineSteps -Mode Conv -Channels 256 -Groups 3 -Group3Shifts -PlaneStride $planeStride -LabelPrefix 'combine256')))
        $bodies.Add(@('body_front_interleave',@(New-KokoroFrontInterleaveSteps)))
        $bodies.Add(@('body_front_add',@(New-KokoroFrontAddSteps)))
    }
    if($Tail){ foreach($pair in (Get-KokoroGeneratorTail16Bodies -PlaneStride $tailLayout.PlaneStride)){ $bodies.Add($pair) } }
    }
    if($Decoder){ foreach($pair in (Get-KokoroDecoder16Bodies -Job $decJob)){ $bodies.Add($pair) } }
    if($Source){
        foreach($pair in (Get-KokoroHarmonicSource16Bodies -PlaneStride $sourceLayout.Stft.PlaneStride -SeededNoise:$SeededNoise)){ $bodies.Add($pair) }
        $bodies.Add(@('body_har_phase_major',@(New-KokoroHarPhaseMajor16Steps -Phases 6)))
        $bodies.Add(@('body_har_phase_major_tiles',@(New-KokoroHarPhaseMajor16Steps -Phases 6 -TileBatch -LabelPrefix 'harphasemajor16tiles')))
        $bodies.Add(@('body_har_phase_major_last',@(New-KokoroHarPhaseMajor16Steps -Phases 1 -LabelPrefix 'harphasemajor16last')))
    }
    foreach($entry in $padBodies){
        $width,$halfword=$entry.Split(','); $name="body_padcapacity_${width}_$halfword"
        $bodies.Add(@($name,@(New-KokoroPadCapacity16Steps -Channels ([int]$width) -Halfword ([int]$halfword) -LabelPrefix $name)))
    }
    foreach($pair in $bodies){$s.Add(@{Op='label';Name=$pair[0]});foreach($step in $pair[1]){$s.Add($step)}}
    if($HvxThreads -gt 1){
        # hvx_worker(r0 = its pool slot): r16 slot, r17 pool block, r18 last sequence seen, r19 zero, r20 body.
        $loop=& $label; $idle=& $label; $done=& $label; $quit=& $label
        $s.Add(@{Op='label';Name='hvx_worker'})
        $s.Add(@{Op='addi';d=16;s=0;i=0}); $s.Add(@{Op='load';d=17;s=16;Offset=32}); $s.Add(@{Op='imm';d=18;i=0}); $s.Add(@{Op='imm';d=19;i=0})
        $s.Add(@{Op='imm';d=0;i=1}); $s.Add(@{Op='imm';d=5;i=0}); $s.Add(@{Op='trap0';i=0x55})
        $s.Add(@{Op='store';s=16;t=0;Offset=52})
        # The matrix worker (slot = pool + 64 * MatrixThread) takes or releases the matrix lock; the others skip it.
        $matrixWorker={param([scriptblock]$trap) $mine=& $label; $past=& $label
            $s.Add(@{Op='addi';d=1;s=17;i=(64*$MatrixThread)}); $s.Add(@{Op='eq';d=0;s=16;t=1}); $s.Add(@{Op='jump-p';u=0;Label=$mine}); & $jump $past
            $s.Add(@{Op='label';Name=$mine}); & $trap; $s.Add(@{Op='store';s=16;t=0;Offset=60})
            $s.Add(@{Op='label';Name=$past}) }
        if($handOffMatrix -and $MatrixLock -eq 'Worker'){ & $matrixWorker $matrixTryLock }
        # Convolution: a pool count of 2 marks matrix work, bracketed by try-lock and unlock.
        $aroundMatrix={param([scriptblock]$trap) $now=& $label; $skip=& $label
            $s.Add(@{Op='load';d=5;s=16;Offset=48}); $s.Add(@{Op='imm';d=1;i=2}); $s.Add(@{Op='eq';d=0;s=5;t=1}); $s.Add(@{Op='jump-p';u=0;Label=$now}); & $jump $skip
            $s.Add(@{Op='label';Name=$now}); & $trap; $s.Add(@{Op='store';s=16;t=0;Offset=60})
            $s.Add(@{Op='label';Name=$skip}) }
        $s.Add(@{Op='label';Name=$loop})
        $s.Add(@{Op='load';d=0;s=17;Offset=0}); $s.Add(@{Op='eq';d=0;s=0;t=18}); $s.Add(@{Op='jump-p';u=0;Label=$idle})
        $s.Add(@{Op='addi';d=18;s=0;i=0})
        $s.Add(@{Op='load';d=1;s=17;Offset=4}); $s.Add(@{Op='gtu';d=0;s=1;t=19}); $s.Add(@{Op='jump-p';u=0;Label=$quit})
        $s.Add(@{Op='load';d=5;s=16;Offset=48}); $s.Add(@{Op='eq';d=0;s=5;t=19}); $s.Add(@{Op='jump-p';u=0;Label=$done})
        if($MatrixLock -eq 'Convolution'){ & $aroundMatrix $matrixTryLock }
        foreach($k in 0..4){ $s.Add(@{Op='load';d=$k;s=16;Offset=(4*$k)}) }
        if($MatrixThread -or $ControllerContact){ $s.Add(@{Op='load';d=5;s=16;Offset=56}) }
        $s.Add(@{Op='load';d=20;s=16;Offset=44}); $s.Add(@{Op='callr';s=20})
        $s.Add(@{Op='syncht'})
        if($MatrixLock -eq 'Convolution'){ & $aroundMatrix $matrixUnlock }
        $s.Add(@{Op='label';Name=$done})
        $s.Add(@{Op='store';s=16;t=18;Offset=20})
        if($PoolWait -eq 'Futex'){ $s.Add(@{Op='addi';d=0;s=16;i=20}); $s.Add(@{Op='imm';d=1;i=1}); $s.Add(@{Op='trap0';i=0x11}) }
        & $jump $loop
        $s.Add(@{Op='label';Name=$idle})
        if($PoolWait -eq 'Futex'){ & $futexWait 17 18 } else { $s.Add(@{Op='pause';i=$poolPause}) }
        & $jump $loop
        $s.Add(@{Op='label';Name=$quit})
        if($handOffMatrix -and $MatrixLock -eq 'Worker'){ & $matrixWorker $matrixUnlock }
        $s.Add(@{Op='imm';d=0;i=3}); $s.Add(@{Op='imm';d=5;i=0}); $s.Add(@{Op='trap0';i=0x55})
        $s.Add(@{Op='imm';d=0;i=0}); $s.Add(@{Op='got-call';Import='qurt_thread_exit';d=14})
    }
    if($PmuEvents){
        $s.Add(@{Op='label';Name='body_pmu_mark'}); $s.Add(@{Op='allocframe';Bytes=16}); $s.Add(@{Op='store';s=29;t=0;Offset=0}); $s.Add(@{Op='store';s=29;t=1;Offset=4})
        $s.Add(@{Op='imm';d=5;i=0}); $s.Add(@{Op='trap0';i=0x63})
        & $ptr 9 25 ($pmuOffset+128); for($k=0;$k -lt 8;$k++){ $s.Add(@{Op='store';s=9;t=(1+$k);Offset=(4*$k)}) }
        & $ptr 2 25 $pmuOffset; $s.Add(@{Op='load';d=4;s=2;Offset=28}); $s.Add(@{Op='or';d=4;s=4;t=0}); $s.Add(@{Op='store';s=2;t=4;Offset=28})
        & $ptr 2 25 ($pmuOffset+128); & $ptr 3 25 ($pmuOffset+64); $s.Add(@{Op='load';d=1;s=29;Offset=0}); $s.Add(@{Op='load';d=12;s=29;Offset=4})
        $s.Add(@{Op='hwticks';d=6}); $s.Add(@{Op='store-d';s=2;t=6;Offset=32})
        $s.Add(@{Op='upcycle';d=6}); $s.Add(@{Op='store-d';s=2;t=6;Offset=40})
        for($k=0;$k -lt 8;$k++){
            $s.Add(@{Op='load';d=4;s=2;Offset=(4*$k)}); $s.Add(@{Op='load';d=5;s=3;Offset=(4*$k)}); $s.Add(@{Op='sub';d=6;s=4;t=5})
            $s.Add(@{Op='load';d=7;s=1;Offset=(4*$k)}); $s.Add(@{Op='add';d=7;s=7;t=6}); $s.Add(@{Op='store';s=1;t=7;Offset=(4*$k)}); $s.Add(@{Op='store';s=3;t=4;Offset=(4*$k)})
            $s.Add(@{Op='load';d=7;s=12;Offset=(4*$k)}); $s.Add(@{Op='add';d=7;s=7;t=6}); $s.Add(@{Op='store';s=12;t=7;Offset=(4*$k)})
        }
        foreach($o in 32,40){
            $s.Add(@{Op='load-d';d=4;s=2;Offset=$o}); $s.Add(@{Op='load-d';d=6;s=3;Offset=$o}); $s.Add(@{Op='sub-d';d=8;s=4;t=6})
            $s.Add(@{Op='load-d';d=10;s=1;Offset=$o}); $s.Add(@{Op='add-d';d=10;s=10;t=8}); $s.Add(@{Op='store-d';s=1;t=10;Offset=$o}); $s.Add(@{Op='store-d';s=3;t=4;Offset=$o})
            $s.Add(@{Op='load-d';d=10;s=12;Offset=$o}); $s.Add(@{Op='add-d';d=10;s=10;t=8}); $s.Add(@{Op='store-d';s=12;t=10;Offset=$o})
        }
        $s.Add(@{Op='load';d=4;s=1;Offset=48}); $s.Add(@{Op='addi';d=4;s=4;i=1}); $s.Add(@{Op='store';s=1;t=4;Offset=48})
        $s.Add(@{Op='load';d=4;s=12;Offset=48}); $s.Add(@{Op='addi';d=4;s=4;i=1}); $s.Add(@{Op='store';s=12;t=4;Offset=48})
        $s.Add(@{Op='dealloc-return'})
    }
    $labels=@{};$pcs=[Collections.Generic.Dictionary[object,long]]::new();$pc=0L;$isa=Get-InstructionSet
    foreach($step in $s){if($step.Op -eq 'label'){if($labels.ContainsKey($step.Name)){throw "Duplicate label $($step.Name)"};$labels[$step.Name]=$pc};$pcs[$step]=$pc;$pc+=& $isa.Length $step}
    foreach($c in $calls){$delta=[long]([uint32](($labels[$c.label]-$pcs[$c.pc]) -band 0xffffffffL));$c.low.i=$delta -band 65535;$c.high.i=$delta -shr 16}
    $resultLayout=[ordered]@{Frames=$Frames;Tiles=$tiles;InputBytes=$totalInput;WeightBytes=$totalWeights;ParameterBytes=$totalParameters;OutputBytes=$totalOutput;VtcmBytes=$vtcmTotal;Samples=$(if($Tail){5*($Frames-1)}else{1});PcmOffset=$(if($Tail){$pcmOffset}else{256});BranchStride=$stride;FinalWorkspaceOffset=$finalOffset;CoefficientOffset=$coefOffset;ScratchOffset=$scratchOffset;CompletedStages=$(6*$branches+[int]$withMean);BatchTiles=$batch;HvxThreads=$HvxThreads;Regions=$layout.Regions}
    $resultLayout.AdaInMode=$AdaInMode
    $resultLayout.WeightRegions=$weightRegions.ToArray()
    if($Source){ $resultLayout.SourceNoise=[pscustomobject]@{InputOffset=$sourceIn+$sourceLayout.F0Bytes;Bytes=$sourceLayout.HalfwordBytes;Seeded=$SeededNoise.IsPresent} }
    if($ControllerContact){ $resultLayout.ControllerContact=[pscustomobject]@{Offset=$contactOffset;SensitivityBytesPerStage=8L*$Channels;ControllerOffset=$contactOffset+18L*8*$Channels;ControllerBytes=$controllerBytes;Tiles=$tiles} }
    if($PmuEvents){$resultLayout.PmuProfile=[pscustomobject]@{Categories=$pmuCategories;SiteRecordOffset=$pmuSiteOffset;SiteRecordCount=$pmuSiteRecordCount;Sites=$pmuSites}}
    $resultLayout.ConstantPacking=[pscustomobject]@{Frames=$Frames;ParameterBytes=$constantsTableOffset;ConstantsTableOffset=$constantsTableOffset;
        ConstantsBytes=$momentAt;ConstantsParameterBytes=$constantsTableOffset+$momentAt;OutputBytes=$exportOffset;
        MomentSites=$momentSites.ToArray();MomentsBytes=$momentAt;KmBytes=$kmsAt}
    [pscustomobject]@{Steps=$s.ToArray();Layout=$resultLayout}
}
