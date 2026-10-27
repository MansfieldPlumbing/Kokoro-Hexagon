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
    param([ValidateRange(2,1048576)][int]$Frames=7801,[ValidateRange(1,64)][int]$BatchTiles=22,[ValidateSet(128,256)][int]$Channels=128)
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
    param([ValidateRange(2,1048576)][int]$Frames=7801,[ValidateRange(1,64)][int]$BatchTiles=22,[ValidateRange(1,4)][int]$HvxThreads=4,
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
        # Backward: depth-first. Every stage's weights, record and K/M/S stay resident in VTCM. Every convolution reads
        # only rows at or before its output: in each residual pair the first convolution taps its reach r1 late and the
        # second 32 - r1, so the pair emerges exactly one tile late, and step j runs all 18 stages on block j of BatchTiles
        # tiles. The residual of a pair adds the previous level one tile back; the three branches end three tiles shifted
        # and the mean is written at position m - 3. Rows outside the section's frames are set to the conv-input zero at
        # each fill, by row range where a pair's first output lands mid-tile.
        # Rings are indexed by tile (two blocks, a power of two); each stage's conv-input ring carries two guard tiles
        # before its start, written by the fill as a second store of the ring's last two tiles, so the matrix unit reads
        # two tiles of history contiguously. One input ring serves the three branches. Lockstep: thread k (the main thread
        # is thread 0) carries tile BatchTiles j + k through all its stages, calling the stage bodies directly; after each
        # stage it publishes a progress word (after syncht), and before a stage's convolutions it waits until the thread
        # with the previous tile has completed that stage. A thread takes the matrix lock (try-lock) around a stage's three
        # convolutions; the main thread releases the job's lock before the one dispatch and takes it back after. One
        # 128-channel section of three kernels and their mean, or a one-branch source section whose last level (position
        # m - 3) is its output; supplied AdaIN values, 2 <= BatchTiles <= HvxThreads, a power of two.
        # Chunked: the backward geometry with streamed weights, for a section whose weights do not fit VTCM (the
        # 256-channel section). Step j runs block j of BatchTiles tiles through each stage in turn: before a stage's
        # convolutions DMA brings its three branches' weight planes into one buffer, the fills and combines are dispatched
        # one tile per HVX thread, and the main thread runs the convolutions over the block. Each branch and plane has
        # one conv-input buffer (two history tiles, then the block) shared by the six stages; each stage's two history
        # tiles are copied in before its convolutions and its block's last two tiles copied out after them.
        # 2 <= BatchTiles <= HvxThreads, a power of two.
        # A 256-channel section always runs Chunked under a depth-first schedule (its weights do not fit VTCM). With -Whole
        # the sections run one after the other over the whole input, each with its own VTCM layout: the 256-channel section
        # (front, then chunked), then the 128-channel section (front from its mean, then the given schedule) and the tail.
        [ValidateSet('Layer','Backward','Chunked')][string]$Schedule='Layer',
        # With -Front or -Whole: each source insertion point (the input of the add after ups) reads a supplied stream, one
        # tensor of the section's tiles per section after the other inputs, instead of computing noise_convs and noise_res
        # from har.
        [switch]$SuppliedSource,
        # Depth-first with supplied sources: the job runs in spans of SpanTiles 256-channel tiles (a multiple of 10 and of
        # BatchTiles). Each span runs every stage over the tiles its upstream has finished: the 256-channel front over the
        # span's decoder tiles, the chunked section's steps, the 128-channel front over the 256-channel mean that has
        # its right halo, the 128-channel section's steps and the tail likewise. Whole-length tensors live in the DDR
        # workspace; each section's VTCM state is saved there after its steps and restored before its next ones, so VTCM
        # does not grow with the length.
        [ValidateRange(10,1280)][int]$SpanTiles=20,
        # Depth-first with the source on the DSP: the harmonic source and its STFT run in chunks of this many har tiles (a
        # multiple of 16), so their VTCM does not grow with the length.
        [ValidateRange(16,4096)][int]$SourceChunkTiles=128,
        # Spans: the sections listed here take their supplied stream as the add's result Y (the section input) instead of
        # the source N added to U; the front still computes U (exported with -ExportFrontTensors).
        [int[]]$SuppliedSectionInputs=@(),
        # Diagnosis (spans): end the job before the first span (Start) or after this stage of the first span that runs it (Noise256, Source256, Front256,
        # Section256, Noise128, Source128, Front128, Section128).
        [ValidateSet('','Start','Noise256','Source256','Front256','Section256','Noise128','Source128','Front128','Section128')][string]$StopAfterSpanStage='',
        # Layer schedule with -Front or -Whole: each front also parks U, the upsampled input of its add, in the workspace
        # (Layout.SourceStreams[].UpsWorkspaceOffset), next to the source N (WorkspaceOffset) and the add's result Y (the
        # section input, Layout.Sections[].InputWorkspaceOffset): the boundary a fitted source binding learns from.
        [switch]$ExportFrontTensors,
        # How HVX workers wait for work and the main thread waits for them: QuRT futex traps, or polling the pool
        # with pause. Default: Spin for the backward schedule (dispatches microseconds apart), Futex otherwise.
        [ValidateSet('','Futex','Spin')][string]$PoolWait='',
        # With -Source: generate the source noise on the DSP from the seed and scale the input holds where z was.
        [switch]$SeededNoise,
        # Backward schedule: weight planes per convolution. 1 keeps only each stage's high weight plane resident (int8
        # weights in the high bytes of the 16-bit weights file), two accumulator groups and the two-group combine.
        [ValidateSet(1,2)][int]$WeightPlanes=2,
        # Backward schedule: the controller contact. Each fill reads the controller value v of its tile's position (one
        # int32 word per tile, v << 16) and applies K = K_base + P_K * v and M = M_base + P_M * v per channel (Q31
        # multiply, as K * x), with K_base, M_base and S from the stage's supplied AdaIN values as before and P_K, P_M per
        # stage from the parameters input after the constants table. v = 0 is exactly the constants arithmetic.
        [switch]$ControllerContact,
        # Group the fill's straight-line vector instructions into packets (Group-HexagonPackets) instead of one
        # instruction per packet.
        [switch]$VectorPackets,
        # Constants mode, depth-first schedules: each site's K/M/S arrive finished in the parameters after the constants
        # table (ConvertTo-KokoroGeneratorStageCoefficients, ConstantPacking.HostCoefficientsOffset) and are copied in
        # instead of computed from the ratios on the DSP.
        [switch]$HostCoefficients,
        # Computed sources under a depth-first schedule: the noise_res sections of these channel counts run Backward (one
        # branch, its six stages' weights resident) instead of Chunked.
        [ValidateSet(128,256)][int[]]$ResidentSourceChannels=@())

    if($WeightPlanes -eq 1 -and $Schedule -eq 'Layer'){ throw 'One weight plane is a backward schedule option.' }
    $packets={ param([object[]]$Steps) $grouped=if($VectorPackets){ Group-HexagonPackets $Steps } else { $Steps }; $grouped }
    if($ControllerContact -and $Schedule -eq 'Layer'){ throw 'The controller contact is a backward schedule option.' }
    if($SeededNoise -and -not $Source){ throw 'Seeded noise is a source option.' }
    if(-not $PoolWait){ $PoolWait=if($Schedule -ne 'Layer'){'Spin'}else{'Futex'} }
    if($Schedule -ne 'Layer' -and ($Decoder -or ($Tail -and -not $Front) -or $RuntimeFrames -or $StopAfterStage -ge 0 -or
        $Kernels.Count -ne 3 -or $AdaInMode -ne 'Constants' -or ($BatchTiles -band ($BatchTiles-1)) -or $BatchTiles -lt 2 -or $BatchTiles -gt $HvxThreads)) {
        throw 'A depth-first schedule runs sections of three kernels and their mean with supplied AdaIN values, one tile per HVX thread (2 <= BatchTiles <= HvxThreads, a power of two).'
    }
    if($Schedule -ne 'Layer' -and ($Front -or $Whole) -and -not ($SuppliedSource -or $Source)){ throw 'A depth-first front reads supplied source streams (-SuppliedSource) or computes them (-Source).' }
    if($SuppliedSource -and -not ($Front -or $Whole)){ throw 'Supplied source streams feed a front (-Front or -Whole).' }
    if($SuppliedSource -and $Source){ throw 'Supplied source streams replace the computed source.' }
    if($SuppliedSource -and $Schedule -eq 'Layer'){ throw 'Supplied source streams feed a depth-first front.' }
    if($ControllerContact -and $Whole){ throw 'The controller contact runs one section.' }
    if($Schedule -ne 'Layer' -and $HvxThreads -lt 3){ throw 'Depth-first schedules dispatch over at least three HVX threads.' }
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
            $chunkTilesOfSource=if($Schedule -ne 'Layer'){$SourceChunkTiles}else{0}
            $sourceFrames=$Frames; $sourceLayout=Get-KokoroHarmonicSource16Layout -Frames $sourceFrames -ChunkTiles $chunkTilesOfSource
            $tiles60=$sourceLayout.Tiles; $tiles10=[int][math]::Ceiling(($upFramesWhole+1)/32)
            $har60At=0L; $harPmAt=[long]([math]::Ceiling(2L*$tiles60*4096/4096)*4096); $sourceDdrBytes=[long]([math]::Ceiling(($harPmAt+2L*$tiles10*16384)/4096)*4096)
            $sections[0].HarReg=25; $sections[0].HarAt=$harPmAt; $sections[1].HarReg=25; $sections[1].HarAt=$har60At
        }
        if($Decoder){ if(-not $Source){throw '-Decoder needs -Whole -Source'}; $decIn=[int]((($Frames-1)/6)/20); if(20*$decIn -ne ($Frames-1)/6){throw 'The 10x frames are not 20 decoder frames each'}; $decLayout=Get-KokoroDecoder16Layout -Frames $decIn; $decSlot=$sourceDdrBytes; $sourceDdrBytes+=[long]([math]::Ceiling($decLayout.OutputBytes/4096)*4096) }
    } elseif($Source){ throw '-Source needs -Whole'
    } else { $sections=@(,@{Channels=$Channels;Frames=$Frames;Front=[bool]$Front;Tail=[bool]$Tail;Chained=$false;Suffix=''}) }
    # Span plan (depth-first with supplied sources). Per span: the 256-channel front's decoder tiles [D0, D1) and
    # slow-input tiles [In0, In1); the chunked section's steps [J0, J1); the 128-channel front's slow tiles [S0, S1) and
    # fast-input tiles [F0, F1); the 128-channel section's steps [K0, K1); the tail's tiles [T0, T1). A stage takes
    # what its upstream has finished: a step needs its block's input, a section's mean lags its steps by three tiles,
    # a front needs one mean tile of right halo and the tail two. At the end of the input every stage finishes.
    $spanMode=$Schedule -ne 'Layer' -and ($SuppliedSource -or $Source)
    $spans=@()
    if($spanMode){
        if($sections[0].Channels -ne 256 -or ($SpanTiles % 10) -or ($SpanTiles % $BatchTiles)){throw 'Spans start at the 256-channel section and hold whole decoder tiles and whole blocks.'}
        $slowFrames=$sections[0].Frames; $decFramesAll=[int]($slowFrames/10); $decTilesAll=[int][math]::Ceiling($decFramesAll/32)
        $slowTiles=[int][math]::Ceiling($slowFrames/32); $slowSteps=[int][math]::Ceiling(($slowTiles+3)/$BatchTiles)
        $two=$sections.Count -gt 1
        if($two){ $fastTiles=[int][math]::Ceiling($sections[1].Frames/32); $fastSteps=[int][math]::Ceiling(($fastTiles+3)/$BatchTiles); if([int][math]::Ceiling(($slowFrames+1)/32) -ne $slowTiles){throw 'The 256-channel mean does not cover the ups[1] input tiles'} }
        $perSpan=$SpanTiles/10; $reached=[ordered]@{D=0;In=0;J=0;S=0;F=0;K=0;T=0;C=0;R=0;G=0;H=0}
        for($k=0;;$k++){
            $d1=[math]::Min($decTilesAll,$perSpan*($k+1)); $in1=if($d1 -eq $decTilesAll){$slowTiles}else{10*$d1}
            $j1=if($in1 -eq $slowTiles){$slowSteps}else{[int][math]::Floor($in1/$BatchTiles)}
            $mean0=if($j1 -eq $slowSteps){$slowTiles}else{[math]::Max(0,$BatchTiles*$j1-3)}
            $span=[ordered]@{Index=$k;D0=$reached.D;D1=$d1;In0=$reached.In;In1=$in1;J0=$reached.J;J1=$j1}
            if($two){
                $s1=if($mean0 -eq $slowTiles){$slowTiles}else{[math]::Max(0,$mean0-1)}; $f1=if($s1 -eq $slowTiles){$fastTiles}else{6*$s1}
                $k1=if($f1 -eq $fastTiles){$fastSteps}else{[int][math]::Floor($f1/$BatchTiles)}
                $mean1=if($k1 -eq $fastSteps){$fastTiles}else{[math]::Max(0,$BatchTiles*$k1-3)}; $t1=if($mean1 -eq $fastTiles){$fastTiles}else{[math]::Max(0,$mean1-2)}
                $span+=[ordered]@{S0=$reached.S;S1=$s1;F0=$reached.F;F1=$f1;K0=$reached.K;K1=$k1;T0=$reached.T;T1=$t1}
                $reached.S=$s1; $reached.F=$f1; $reached.K=$k1; $reached.T=$t1
            }
            if($Source){
                # Computed sources: noise_res.0 steps [R0, R1) on noise_convs.0 tiles [C0, C1), far enough to give the
                # 256-channel front its source tiles (a step's output lags its input three tiles); likewise
                # noise_res.1 steps [H0, H1) on noise_convs.1 tiles [G0, G1) for the 128-channel front.
                $r1=if($in1 -eq $slowTiles){$slowSteps}else{[math]::Min($slowSteps,[int][math]::Ceiling(($in1+3)/$BatchTiles))}
                $c1=if($r1 -eq $slowSteps){$slowTiles}else{[math]::Min($slowTiles,$BatchTiles*$r1)}
                $span+=[ordered]@{C0=$reached.C;C1=$c1;R0=$reached.R;R1=$r1}; $reached.C=$c1; $reached.R=$r1
                if($two){
                    $h1=if($f1 -eq $fastTiles){$fastSteps}else{[math]::Min($fastSteps,[int][math]::Ceiling(($f1+3)/$BatchTiles))}
                    $g1=if($h1 -eq $fastSteps){$fastTiles}else{[math]::Min($fastTiles,$BatchTiles*$h1)}
                    $span+=[ordered]@{G0=$reached.G;G1=$g1;H0=$reached.H;H1=$h1}; $reached.G=$g1; $reached.H=$h1
                }
            }
            $spans+=[pscustomobject]$span; $reached.D=$d1; $reached.In=$in1; $reached.J=$j1
            if(($two -and $reached.T -eq $fastTiles) -or (-not $two -and $reached.J -eq $slowSteps)){ break }
        }
    }
    # Largest range of each span stage (VTCM is sized by them).
    $spanMax={param([string]$a,[string]$b) [int](@($spans | ForEach-Object { $_.$b-$_.$a }) | Measure-Object -Maximum).Maximum}
    # Depth-first layout of the bound section (dot-sourced at the end of $configure). Records and K/M/S of all 18 stages
    # stay in VTCM for the section; weights stay resident (Backward) or stream per stage (Chunked).
    $sectionLayout={
        $al={param([long]$v) [long]([math]::Ceiling($v/65536)*65536)}
        $tileStages=@(for($bb=0;$bb -lt $branches;$bb++){for($st=0;$st -lt 6;$st++){
            [pscustomobject]@{Branch=$bb;Stage=$st;Pair=[int][math]::Floor($st/2);Half=$st%2;Dilation=@(1,3,5)[[int][math]::Floor($st/2)]
                WeightOffset=$branchWeights[$bb]+$st*2L*$Channels*$Channels*$sectionKernels[$bb];WeightBytes=[long]$WeightPlanes*$Channels*$Channels*$sectionKernels[$bb];RecordOffset=$pBase+(6L*$bb+$st)*$recordBytes}}})
        $tilePlanes=4L+2*($WeightPlanes-1)
        $planesStride=& $al ($tilePlanes*$batch*$tileBytes)
        # Shifts of the runtime ring addressing (the step in r17): block and tile bytes, tiles per block.
        $blockBytes=[long]$batch*$tileBytes; $blockShift=[int][math]::Round([math]::Log($blockBytes,2)); $batchShift=[int][math]::Round([math]::Log($batch,2)); $tileShift=[int][math]::Round([math]::Log($tileBytes,2))
    if($sectionSchedule -eq 'Backward'){
        # Planes first (inside the first 1 MiB); per stage and plane the branches' conv-input rings (two guard tiles,
        # then two blocks), each group inside one 1 MiB page; the input ring, the level and stage rings (three per pair,
        # one per branch), the mean, K/M/S, records and weights.
        $ringTiles=2*$batch; $ringBytes=[long]$ringTiles*$tileBytes; $fillBytes=($ringTiles+2L)*$tileBytes; $guardBytes=2L*$tileBytes
        $tileRegions=[ordered]@{}; $at=0L
        $tileRegions.Planes=$at; $at+=& $al ($branches*$planesStride)
        if($at -gt 1048576){throw 'HMX planes must lie in the first 1 MiB of VTCM.'}
        $fillAt=@{}
        foreach($plane in 'High','Low'){ for($st=0;$st -lt 6;$st++){
            if([math]::Floor($at/1048576) -ne [math]::Floor(($at+$branches*$fillBytes-1)/1048576)){ $at=[long]([math]::Ceiling($at/1048576)*1048576) }
            $fillAt["$plane.$st"]=$at; $at+=$branches*$fillBytes } }
        $at=& $al $at
        foreach($r in @(@('Input',$ringBytes),@('Levels',(3L*$branches*$ringBytes)),@('Stage',(3L*$branches*$ringBytes)),@('Mean',([long]$batch*$tileBytes)),@('Moments',(16L*$Channels)),@('Kms',(6L*$branches*$kmsBytes)),@('Records',(6L*$branches*$recordBytes)),@('Controller',$(if($ControllerContact){$controllerBytes}else{0L})),@('Progress',128L))){ $tileRegions[$r[0]]=$at; $at+=& $al $r[1] }
        $tileWeightAt=[long[]]::new(6*$branches); foreach($g in $tileStages){ $tileWeightAt[6*$g.Branch+$g.Stage]=$at; $at+=$g.WeightBytes }
        $vtcmBytes=[math]::Max($vtcmBytes,(& $al $at))
        if($vtcmBytes -gt 8388608){throw 'The backward schedule does not fit VTCM.'}
    }
    if($sectionSchedule -eq 'Chunked'){
        # Planes first (inside the first 1 MiB); per plane the three branches' conv-input buffers (two history tiles, then
        # the block), each plane's group inside one 1 MiB page; per stage and plane the three branches' saved history
        # tiles; the input, level and stage rings (two blocks); the mean, K/M/S, records and one stage's weights.
        $ringTiles=2*$batch; $ringBytes=[long]$ringTiles*$tileBytes; $fillBytes=($batch+2L)*$tileBytes; $guardBytes=2L*$tileBytes
        $historyBytes=[long]$branches*$guardBytes
        $tileRegions=[ordered]@{}; $at=0L
        $tileRegions.Planes=$at; $at+=& $al ($branches*$planesStride)
        if($at -gt 1048576){throw 'HMX planes must lie in the first 1 MiB of VTCM.'}
        $fillAt=@{}
        foreach($plane in 'High','Low'){
            if([math]::Floor($at/1048576) -ne [math]::Floor(($at+$branches*$fillBytes-1)/1048576)){ $at=[long]([math]::Ceiling($at/1048576)*1048576) }
            $fillAt[$plane]=$at; $at+=$branches*$fillBytes }
        $at=& $al $at
        # One stage's branches of weight planes, branch b at streamAt[b].
        $streamAt=[long[]]::new($branches); $streamBytes=0L
        for($bb=0;$bb -lt $branches;$bb++){ $streamAt[$bb]=$streamBytes; $streamBytes+=$tileStages[6*$bb].WeightBytes }
        foreach($r in @(@('History',(12L*$historyBytes)),@('Input',$ringBytes),@('Levels',(3L*$branches*$ringBytes)),@('Stage',(3L*$branches*$ringBytes)),@('Mean',([long]$batch*$tileBytes)),@('Moments',(16L*$Channels)),@('Kms',(6L*$branches*$kmsBytes)),@('Records',(6L*$branches*$recordBytes)),@('Controller',$(if($ControllerContact){$controllerBytes}else{0L})),@('Weights',$streamBytes))){ $tileRegions[$r[0]]=$at; $at+=& $al $r[1] }
        $vtcmBytes=[math]::Max($vtcmBytes,(& $al $at))
        if($vtcmBytes -gt 8388608){throw "The chunked schedule needs $vtcmBytes bytes of VTCM."}
    }
    }
    # Span layout of the bound depth-first section (dot-sourced at the end of $configure). Its front's VTCM regions for
    # the largest span (used while no section state is in VTCM): the planes in the first 1 MiB, then each HMX source
    # inside one 1 MiB page. Its state, the VTCM bytes from the first ring to the last region the steps carry
    # (StateFrom, StateBytes), and the workspace slot it is saved to between spans.
    $spanSectionLayout={
        $frontRegions=[ordered]@{}; $at=0L; $al={param([long]$v) [long]([math]::Ceiling($v/65536)*65536)}
        $place={param([string]$regionName,[long]$regionBytes,[switch]$Hmx)
            if($Hmx -and [math]::Floor($at/1048576) -ne [math]::Floor(($at+$regionBytes-1)/1048576)){ $at=[long]([math]::Ceiling($at/1048576)*1048576) }
            $frontRegions[$regionName]=$at; $at+=& $al $regionBytes }
        if($front10){
            $n=$SpanTiles/10
            . $place Planes (6L*$planeStride); . $place Input (($n+2)*32768L); . $place High (($n+2)*32768L) -Hmx; . $place Low (($n+2)*32768L) -Hmx
            . $place PhaseA ($n*16384L); . $place PhaseB ($n*16384L); . $place Target ((10L*$n+1)*16384); . $place Sum (10L*$n*16384)
            . $place Weights 786432; . $place Tables 163840
        } elseif($Front){
            $n=& $spanMax 'S0' 'S1'
            . $place Planes (6L*$planeStride); . $place Input (($n+2)*16384L); . $place High (($n+2)*16384L) -Hmx; . $place Low (($n+2)*16384L) -Hmx
            . $place Phase ($n*16384L); . $place Target ((6L*$n+4)*8192); . $place Sum (6L*$n*8192)
            . $place Weights 393216; . $place Tables 65536
        }
        elseif($sec.Source){
            # noise_convs over a tile range in batches: har windows (a tile of halo each side), the sum, weights, tables.
            $harTile=if($Channels -eq 256){16384L}else{4096L}; $n=if($Channels -eq 256){& $spanMax 'C0' 'C1'}else{& $spanMax 'G0' 'G1'}
            . $place Planes (6L*$planeStride); . $place Window (($batch+2)*$harTile) -Hmx; . $place WindowLow (($batch+2)*$harTile) -Hmx
            . $place Sum ([long]$n*$tileBytes); . $place Weights $(if($Channels -eq 256){393216L}else{49152L}); . $place Tables $(if($Channels -eq 256){163840L}else{65536L})
        }
        if($Front -or $sec.Source){ if($frontRegions.Planes+6L*$planeStride -gt 1048576){throw 'Front planes must lie in the first 1 MiB of VTCM.'}; $vtcmBytes=[math]::Max($vtcmBytes,$at) }
        if($vtcmBytes -gt 8388608){throw "The span front needs $vtcmBytes bytes of VTCM."}
        $spanFront=$frontRegions
        if($sectionSchedule -eq 'Chunked'){ $stateFrom=$tileRegions.History; $stateBytes=$tileRegions.Weights-$tileRegions.History }
        else { $stateFrom=[long]($fillAt.Values | Measure-Object -Minimum).Minimum; $stateBytes=$tileWeightAt[-1]+$tileStages[-1].WeightBytes-$stateFrom }
        $stateSlot=[long]([math]::Ceiling($outputBytes/4096)*4096); $outputBytes=192+$stateSlot+$stateBytes
    }
    # Binds one section's sizes and offsets in this scope (dot-sourced). Inputs, weights and records start at the given
    # bases; the DDR workspace offsets (r25-relative, 4096-aligned base) are absolute.
    $configure={param($sec,[long]$ddrBase,[long]$inBase,[long]$wBase,[long]$pBase)
    $Channels=$sec.Channels; $Frames=$sec.Frames; $Front=[switch]$sec.Front; $Tail=[switch]$sec.Tail; $chained=$sec.Chained; $sfx=$sec.Suffix
    $sectionKernels=if($sec.ContainsKey('Kernels')){[int[]]$sec.Kernels}else{$Kernels}; $branches=$sectionKernels.Count; $withMean=$branches -eq 3
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
    for($b=0;$b -lt $branches;$b++){ $branchWeights[$b]=$weightBytes; $weightBytes+=6L*2*$Channels*$Channels*$sectionKernels[$b] }
    $parameterBytes=$pBase+6*$branches*$recordBytes
    $stride=[int]([math]::Ceiling($tensorBytes/128)*128); $finalOffset=$ddrBase+$(if($spanMode){0L}else{2L*$stride}); $coefOffset=$finalOffset+$tensorBytes
    $scratchOffset=[long]([math]::Ceiling(($coefOffset+18*$kmsBytes)/4096)*4096); $outputBytes=192+$scratchOffset+131072
    $vtcmBytes=$(if($spanMode){0L}else{$layout.VtcmBytes}); $inputBytes=$inBase+$tensorBytes
    $r0Base=20; $r0Offset=$inBase
    if($front10){
        # 256-channel front (tools/New-KokoroGeneratorFront10x16Fixture.ps1): input buffer = decoder output (512-channel
        # croutons), then phase-major har high and low planes (256-channel tiles).
        if(-not $withMean -or $StopAfterStage -ge 0){throw '-Front feeds the whole three-block stage'}
        $decFrames=[int]($Frames/10); if(10*$decFrames -ne $Frames){throw 'Frames is not 10 m'}
        $decTiles=[int][math]::Ceiling($decFrames/32); $qPairs=[int][math]::Ceiling(($decFrames+1)/2); $decBytes=$decTiles*32768L
        $inputBytes=$inBase+$(if($Decoder){0L}else{$decBytes})+$(if($harFromInput -and -not $spanMode){2L*$tiles*$tileBytes}else{0L})
        if($harFromInput){ $harReg=20; $harAt=$inBase+$decBytes } else { $harReg=$sec.HarReg; $harAt=$sec.HarAt }
        $al64={param([long]$v) [long]([math]::Ceiling($v/65536)*65536)}
        if(-not $spanMode){
            $offFrontWeights=& $al64 $layout.VtcmBytes; $offFrontTables=$offFrontWeights+786432; $offUpA=$offFrontTables+163840; $offUpB=$offUpA+$decTiles*16384L
            $vtcmBytes=[math]::Max($vtcmBytes,(& $al64 ($offUpB+$decTiles*16384L)))
            $upHi=$R.Residual.Offset; $upLo=$upHi+($decTiles+2)*32768L
            if($upLo+($decTiles+2)*32768L -gt $R.Residual.Offset+$R.Residual.Bytes){throw 'ups[0] input planes exceed the residual region'}
            if([math]::Floor($upHi/4194304) -ne [math]::Floor(($upLo+($decTiles+2)*32768L-1)/4194304)){throw 'ups[0] input planes cross a 4 MiB VTCM boundary'}
            if((10*$qPairs+5)/16 -gt [math]::Floor($R.ConvOutput.Bytes/$tileBytes)){throw 'The interleave writes past the target region'}
        }
        # Spans keep only the section input in the workspace (no source slot).
        if($spanMode){ $noiseSlot=-1L; $r0Slot=[long]([math]::Ceiling(($scratchOffset+131072)/4096)*4096) }
        else { $noiseSlot=[long]([math]::Ceiling(($scratchOffset+131072)/4096)*4096); $r0Slot=$noiseSlot+[long]([math]::Ceiling($tensorBytes/4096)*4096) }
        $outputBytes=192+$r0Slot+$tensorBytes; $r0Base=25; $r0Offset=$r0Slot
        # -ExportFrontTensors: U, the upsampled input of the add, also parks in the workspace.
        $upsSlot=-1L; if($ExportFrontTensors){ $upsSlot=[long]([math]::Ceiling($outputBytes/4096)*4096); $outputBytes=192+$upsSlot+$tensorBytes }
    }
    elseif($Front){
        if(-not $withMean -or $StopAfterStage -ge 0){throw '-Front feeds the whole three-block stage'}
        if($batch % 2){throw '-Front needs an even batch (ups[1] batches are half as many 256-channel tiles)'}
        $upFrames=[int](($Frames-1)/6)+1; if(6*($upFrames-1)+1 -ne $Frames){throw 'Frames is not 6 m + 1'}
        $upTiles=[int][math]::Ceiling($upFrames/32); $upBatch=$batch/2
        # Chained (-Whole): the ups[1] input planes come from the 10x section, not the input buffer.
        $inputBytes=$inBase+$(if($harFromInput -and -not $spanMode){2L*$tiles*4096}else{0L})+$(if($chained){0L}else{2L*$upTiles*16384})
        if($harFromInput){ $harReg=20; $harAt=$inBase } else { $harReg=$sec.HarReg; $harAt=$sec.HarAt }
        $al64={param([long]$v) [long]([math]::Ceiling($v/65536)*65536)}
        if(-not $spanMode){
            $offFrontWeights=& $al64 $layout.VtcmBytes; $offFrontTables=$offFrontWeights+393216; $offUpPhase=$offFrontTables+65536
            $vtcmBytes=[math]::Max($vtcmBytes,(& $al64 ($offUpPhase+$upTiles*16384L)))
            if($R.Residual.Offset+2L*($upTiles+2)*16384 -gt 4194304){throw 'ups[1] input planes cross a 4 MiB VTCM boundary'}
            if(($tiles+4)*8192L -gt $R.ConvOutput.Bytes){throw 'The interleave needs four tiles of slack after the stage input'}
        }
        # Spans keep only the section input in the workspace (no source slot).
        if($spanMode){ $noiseSlot=-1L; $r0Slot=[long]([math]::Ceiling(($scratchOffset+131072)/4096)*4096) }
        else { $noiseSlot=[long]([math]::Ceiling(($scratchOffset+131072)/4096)*4096); $r0Slot=$noiseSlot+[long]([math]::Ceiling($tensorBytes/4096)*4096) }
        $outputBytes=192+$r0Slot+$tensorBytes; $r0Base=25; $r0Offset=$r0Slot
        # -ExportFrontTensors: U, the upsampled input of the add, also parks in the workspace.
        $upsSlot=-1L; if($ExportFrontTensors){ $upsSlot=[long]([math]::Ceiling($outputBytes/4096)*4096); $outputBytes=192+$upsSlot+$tensorBytes }
    }
    if($sec.Source){
        # A computed source (noise_res of section $sec.Of): its input is the noise_convs output its span front writes to
        # the workspace; its output (the source N the section's front adds) is its final tensor.
        $r0Slot=[long]([math]::Ceiling(($scratchOffset+131072)/4096)*4096); $outputBytes=192+$r0Slot+$tensorBytes; $r0Base=25; $r0Offset=$r0Slot
    }
    $tailWeightOffset=$weightBytes; $tailParameterOffset=$parameterBytes
    if($Tail){
        if($StopAfterStage -ge 0){throw '-Tail runs only after the whole stage'}
        $tailLayout=Get-KokoroGeneratorTail16Layout -Frames $Frames -SpanTiles $(if($spanMode){& $spanMax 'T0' 'T1'}else{0})
        $vtcmBytes=[math]::Max($vtcmBytes,$tailLayout.VtcmBytes); $weightBytes+=172032; $parameterBytes+=16384
        $pcmOffset=[long]([math]::Ceiling($outputBytes/256)*256); $outputBytes=$pcmOffset+$tailLayout.OutputBytes-256
    }
    if($front10){ $noiseWeightOffset=$weightBytes; $weightBytes+=6L*2*256*256*7; $frontWeightOffset=$weightBytes; $weightBytes+=196608L*2+10*786432L
        $noiseParameterOffset=$parameterBytes; $parameterBytes+=6*$recordBytes; $frontParameterOffset=$parameterBytes; $parameterBytes+=163840 }
    elseif($Front){ $noiseWeightOffset=$weightBytes; $weightBytes+=6L*32768*11; $frontWeightOffset=$weightBytes; $weightBytes+=1228800
        $noiseParameterOffset=$parameterBytes; $parameterBytes+=6*16384; $frontParameterOffset=$parameterBytes; $parameterBytes+=65536 }
    $controllerBytes=[long]([math]::Ceiling(4L*$tiles/128)*128)
    $sectionSchedule=if($Schedule -eq 'Layer'){'Layer'}elseif($sec.Source -and $ResidentSourceChannels -contains $Channels){'Backward'}elseif($Channels -eq 256 -or $sec.Source){'Chunked'}else{$Schedule}
    if($sectionSchedule -ne 'Layer'){ . $sectionLayout }
    if($spanMode -and $sectionSchedule -ne 'Layer'){ . $spanSectionLayout }
    }
    # Place each section after the previous one, then bind the first. VTCM is shared: the job requests the largest.
    $bases=[Collections.Generic.List[long[]]]::new(); $ddrAt=$(if($Source){$sourceDdrBytes}else{0L}); $inAt=0L; $wAt=0L; $pAt=0L; $vtcmTotal=0L
    # Weight regions by part: Main is the path from x to PCM, Source the branch fed only by the excitation. Resblock
    # stages are W8 two-plane records (high plane, then low plane, Channels^2 K bytes each).
    $weightRegions=[Collections.Generic.List[object]]::new()
    foreach($sec in $sections){
        $bases.Add([long[]]@($ddrAt,$inAt,$wAt,$pAt)); . $configure $sec $ddrAt $inAt $wAt $pAt
        $vtcmTotal=[math]::Max($vtcmTotal,$vtcmBytes)
        for($b=0;$b -lt $branches;$b++){$weightRegions.Add([pscustomobject]@{Name="resblocks.c$Channels.k$($sectionKernels[$b])";Part='Main';Format='ResblockW16';Channels=$Channels;Kernel=$sectionKernels[$b];Offset=$branchWeights[$b];Bytes=6L*2*$Channels*$Channels*$sectionKernels[$b]})}
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
        # Spans lay out the phase-major har in chunks of 8 slow tiles ($harLayoutChunks), not whole.
        $vtcmTotal=[math]::Max($vtcmTotal,[math]::Max($sourceLayout.VtcmBytes,$(if($spanMode){4L*65536*[math]::Ceiling((6*8+1)*4096/65536.0)}else{$gPmLo+$tiles10*16384L})))
        if($Decoder){ $decInOff=$totalInput; $decWOff=$totalWeights; $decPOff=$totalParameters; $totalInput+=$decLayout.InputBytes; $totalWeights+=$decLayout.WeightBytes; $totalParameters+=$(if($DecoderMoments -eq 'Constants'){$decLayout.ConstantsParameterBytes}else{$decLayout.ParameterBytes}); $vtcmTotal=[math]::Max($vtcmTotal,$decLayout.VtcmBytes) }
    }
    $bind={param([int]$i) $q=$bases[$i]; . $configure $sections[$i] $q[0] $q[1] $q[2] $q[3]}
    # Computed sources under spans: each fronted section's noise_res as a one-branch section of its own, appended so the
    # sections before keep their places; its weights and records are the layer job's noise_res ones.
    $sourceSectionOf=@{}
    if($spanMode -and $Source){
        $mainSections=$sections.Count
        for($i=0;$i -lt $mainSections;$i++){
            . $bind $i
            if(-not $Front){ continue }
            $sections+=,@{Channels=$Channels;Frames=$Frames;Front=$false;Tail=$false;Chained=$false;Suffix="_n$Channels";Source=$true;Of=$i;Kernels=@($(if($front10){7}else{11}))
                NoiseWeights=$noiseWeightOffset;NoiseRecords=$noiseParameterOffset;HarReg=$harReg;HarAt=$harAt;ConvWeights=$frontWeightOffset;ConvTables=$frontParameterOffset}
        }
        for($i=$mainSections;$i -lt $sections.Count;$i++){
            $bases.Add([long[]]@($ddrAt,0L,[long]$sections[$i].NoiseWeights,[long]$sections[$i].NoiseRecords)); . $bind $i
            $vtcmTotal=[math]::Max($vtcmTotal,$vtcmBytes); $ddrAt=[long]([math]::Ceiling(($outputBytes-192)/4096)*4096); $sourceSectionOf[[int]$sections[$i].Of]=$i
        }
        $totalOutput=$outputBytes
    }
    # Supplied source streams after the other inputs: one tensor of each fronted section's tiles (biased u16), in section
    # order. The workspace slot where each front parks its source tensor is recorded for every front (layer jobs export it).
    $sourceStreams=[Collections.Generic.List[object]]::new()
    for($i=0;$i -lt $sections.Count;$i++){
        . $bind $i
        if(-not $Front){ $sourceStreams.Add($null); continue }
        $sourceStreams.Add([pscustomobject]@{Section=$i;Channels=$Channels;Tiles=$tiles;Bytes=$tensorBytes;InputOffset=$(if($SuppliedSource){$totalInput}else{-1L});WorkspaceOffset=$noiseSlot;UpsWorkspaceOffset=$upsSlot;AddRatioOffset=$frontParameterOffset+$(if($front10){149504L}else{59392L});AddRatioForm=$(if($front10){'HalfwordVectors'}else{'Words'})})
        if($SuppliedSource){ $totalInput+=[long]([math]::Ceiling($tensorBytes/128)*128) }
    }
    $anyChunked=@(for($i=0;$i -lt $sections.Count;$i++){ . $bind $i; if($sectionSchedule -eq 'Chunked'){ $i } }).Count -gt 0
    $runtimeFramesOffset=$totalInput
    if($RuntimeFrames){$totalInput+=4}
    # Site tables live in DDR. Only the active site's ratios occupy the existing
    # moments scratch; K/M/S retain their existing addresses and extent.
    $siteByRecord=[Collections.Generic.Dictionary[long,object]]::new()
    $momentSites=[Collections.Generic.List[object]]::new(); $momentAt=0L; $kmsAt=0L
    $constantsTableOffset=$totalParameters
    for($section=0;$section -lt $sections.Count;$section++){
        . $bind $section
        if($sections[$section].Source){ continue }
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
    if($HostCoefficients -and $AdaInMode -ne 'Constants'){throw 'HostCoefficients needs the Constants AdaIN mode.'}
    $hostCoefficientsOffset=$totalParameters
    if($HostCoefficients){$totalParameters+=$kmsAt}
    # Controller contact inputs: per stage P_K[C] then P_M[C] (int32), then one controller word per tile.
    $contactOffset=$totalParameters
    if($ControllerContact){$totalParameters+=18L*8*$Channels+$controllerBytes}
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
    $pmuCategories+=@('Source','Decoder','Tail','Boundary','Lockstep')
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
        if(-not $PmuEvents -or $marksOff){return}
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
        if($HvxThreads -eq 1 -or $count -lt 2){ for($i=0;$i -lt $n;$i++){ & $ptr $i 18 $off[$i] }; & $imm $n $count; & $call $body; return }
        $chunk=[int][math]::Ceiling($count/$HvxThreads)
        for($k=1;$k -lt $HvxThreads;$k++){
            $o=$k*$chunk; $c=[math]::Max(0,[math]::Min($chunk,$count-$o))
            if($c -gt 0 -and $Moments){ & $ptr 4 18 $privateMoments[$k]; $s.Add(@{Op='vxor';d=0;s=0;t=0}); for($v=0;$v -lt $momentVectors;$v++){$s.Add(@{Op='vstore';s=4;t=0;Offset=(128*($v%8))}); if($v%8 -eq 7 -and $v -lt $momentVectors-1){$s.Add(@{Op='addi';d=4;s=4;i=1024})}} }
            & $ptr 6 25 ($poolOffset+64*$k)
            if($c -gt 0){
                for($i=0;$i -lt $n;$i++){
                    $value=if($Moments -and $i -eq 1){$privateMoments[$k]}elseif($perTile[$i]){$off[$i]+$o*$tileBytes}else{$off[$i]}; & $ptr 0 18 $value
                    $s.Add(@{Op='store';s=6;t=0;Offset=(4*$i)})
                }
                # Offset 4 n is the count's slot below five arguments. At five it is the worker's report word (offset 20), which
                # the join reads: workers of a job with a chunked section take the count from slot 56 instead, and a count stored
                # at 20 could equal the pool sequence and end the join early. (Layer jobs keep their pinned emission.)
                & $imm 0 $c; if(-not ($anyChunked -and $n -ge 5)){ $s.Add(@{Op='store';s=6;t=0;Offset=(4*$n)}) }
                if($anyChunked -and $n -ge 5){ $s.Add(@{Op='store';s=6;t=0;Offset=56}) }
                & $addr 0 $body; $s.Add(@{Op='store';s=6;t=0;Offset=44})
            }
            & $imm 0 $c; $s.Add(@{Op='store';s=6;t=0;Offset=48})
        }
        & $wake
        for($i=0;$i -lt $n;$i++){ & $ptr $i 18 $off[$i] }; & $imm $n ([math]::Min($chunk,$count)); & $call $body
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
    $poolStart={
        if($HvxThreads -eq 1){return}
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
        }
    }

    # DMA ledger (Layout.DmaLedger): bytes each run moves, by section, span and class, every transfer counted as often as
    # it runs ($dmaRepeat: loops multiply it while their body is emitted). The tail's own transfers are not included.
    $dmaLedger=[Collections.Generic.List[object]]::new(); $dmaRepeat=1L; $ledgerSpan='-'
    $ledgerAdd={param([string]$class,[long]$length) $dmaLedger.Add([pscustomobject]@{Section="$Channels$sfx";Span=$ledgerSpan;Class=$class;Count=$dmaRepeat;Bytes=$dmaRepeat*$length}) }
    # Class by base register: r21 weights, r22 parameters, the bound section's state slot in r25, else tensors (VTCM r18).
    $dmaClass={param([int]$destBase,[long]$destOff,[int]$srcBase,[long]$srcOff)
        $slot=if(Test-Path variable:stateSlot){$stateSlot}else{-1L}
        if($srcBase -eq 21){'Weights'} elseif($srcBase -eq 22){'Parameters'}
        elseif($destBase -eq 18 -and $srcBase -eq 25 -and $srcOff -eq $slot){'StateRestore'}
        elseif($destBase -eq 25 -and $srcBase -eq 18 -and $destOff -eq $slot){'StateSave'}
        elseif($destBase -eq 18){'TensorIn'} else {'TensorOut'} }
    # DMA dest <- src, length bytes; r24 holds two 64-byte aligned descriptor slots in DDR.
    $dma={param([int]$destBase,[long]$destOff,[int]$srcBase,[long]$srcOff,[long]$length)
        if($length -lt 2 -or $length -ge 2*16777215){throw 'DMA length out of range'}
        & $ledgerAdd (& $dmaClass $destBase $destOff $srcBase $srcOff) $length
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
    $zeroRecord={param([long]$off) & $ptr 4 18 $off; $s.Add(@{Op='vxor';d=0;s=0;t=0}); for($k=0;$k -lt $momentVectors;$k++){$s.Add(@{Op='vstore';s=4;t=0;Offset=(128*($k%8))}); if($k%8 -eq 7 -and $k -lt $momentVectors-1){$s.Add(@{Op='addi';d=4;s=4;i=1024})}} }
    $copyRecord={param([long]$destOff,[long]$srcOff) for($half=0;$half -lt $momentVectors/8;$half++){ & $ptr 4 18 ($srcOff+1024*$half); & $ptr 5 18 ($destOff+1024*$half); for($k=0;$k -lt 8;$k++){$s.Add(@{Op='vload';d=$k;s=4;Offset=(128*$k)})}; for($k=0;$k -lt 8;$k++){$s.Add(@{Op='vstore';s=5;t=$k;Offset=(128*$k)})} } }
    # Rows firstRow to endRow - 1 of the tile at tileOff (default: rows >= Frames): every halfword of those rows <- value
    # (0x8000 or 0).
    $padRows={param([long]$tileOff,[long]$value,[int]$firstRow=-1,[int]$endRow=32)
        if($firstRow -lt 0){ if($Frames%32 -eq 0){return}; $firstRow=$Frames%32 }
        if($firstRow -ge $endRow){return}
        # Each vector contains two rows: low/high halfwords of its 32 words.
        # Construct each row-pair mask once and reuse it across channel blocks.
        $firstPair=[int][math]::Floor($firstRow/2); $lastPair=[int][math]::Floor(($endRow-1)/2)
        for($pair=$firstPair;$pair -le $lastPair;$pair++){
            $keep=0L
            if(2*$pair -lt $firstRow){ $keep=$keep -bor 0x0000ffffL }
            if(2*$pair+1 -ge $endRow){ $keep=$keep -bor 0xffff0000L }
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
        if($ExportFrontTensors){ & $sync; & $dma 25 $upsSlot 18 $offConv $tensorBytes }
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
        # The phase convolutions run over as many decoder tiles as one plane stride holds.
        $upBatch10=[int][math]::Floor($planeStride/16384)
        for($r=0;$r -lt 10;$r++){
            & $dma 18 $offFrontWeights 21 ($frontWeightOffset+393216+$r*786432L) 786432
            for($start=0;$start -lt $decTiles;$start+=$upBatch10){
                $count=[math]::Min($upBatch10,$decTiles-$start)
                & $ptr 0 18 ($upHi+32768+$start*32768L); & $ptr 1 18 ($upLo+32768+$start*32768L); & $ptr 2 18 $offFrontWeights; & $ptr 3 18 ($offFrontTables+16384+12288*$r); & $imm 4 $count; & $ptr 5 18 $offPlanes
                & $call 'body_conv_front10_up'; & $mark 'HmxConv'; & $mark 'Unmarked' -site 25; & $sync
                & $parallel $(if($WeightPlanes -eq 2){"body_combine_conv$sfx"}else{"body_combine_front$sfx"}) @($offPlanes,($(if($r%2){$offUpB}else{$offUpA})+$start*16384L),($offFrontTables+139264+1024*$r-1024)) @($true,$true,$false) $count
                & $mark 'Combine'
            }
            if($r%2){ & $mark 'Unmarked' -site 26; & $sync; & $ptr 0 18 $offUpA; & $ptr 1 18 $offConv; & $imm 2 (($r-1)/2); & $imm 3 $qPairs; & $ptr 4 18 $offUpB; & $call 'body_front10_interleave'; & $mark 'Combine'; & $mark 'Unmarked' -site 27; & $sync }
        }
        if($ExportFrontTensors){ & $sync; & $dma 25 $upsSlot 18 $offConv $tensorBytes }
        & $dma 18 $offResidual 25 $noiseSlot $tensorBytes
        & $ptr 0 18 $offConv; & $ptr 1 18 $offResidual; & $ptr 2 18 ($offFrontTables+149504); & $imm 3 $tiles
        & $call 'body_front10_add'; & $mark 'Combine'
        & $mark 'Unmarked' -site 28; & $padRows ($offResidual+($tiles-1)*$tileBytes) 0x8000
        & $mark 'Unmarked' -site 29; & $sync; & $dma 25 $r0Slot 18 $offResidual $tensorBytes
    }
    # The 10x front's phase-major har in chunks of slow tiles, so VTCM does not grow with the length (spans): each chunk
    # loads the 60x har tiles its rows read (output row m' reads har rows 6 m' .. 6 m' + 5; the last also row 6 m' + 6),
    # runs the same bodies with virtual base pointers (chunk buffer minus chunk start), and writes its tiles to the
    # workspace. Complete output tiles are independent; the partial tile and the last row are done where they fall.
    $harLayoutChunks={
        $chunk=8; $phaseTileCount=[int][math]::Floor($upFramesWhole/32)
        $al64={param([long]$v) [long]([math]::Ceiling($v/65536)*65536)}
        $cHi=0L; $cLo=& $al64 ((6L*$chunk+1)*4096); $cPmHi=2*$cLo; $cPmLo=$cPmHi+(& $al64 ([long]$chunk*16384))
        for($a=0;$a -lt $tiles10;$a+=$chunk){
            $b=[math]::Min($tiles10,$a+$chunk); $srcFirst=6*$a; $srcEnd=[math]::Min($tiles60,6*$b+1); $n=$srcEnd-$srcFirst
            & $dma 18 $cHi 25 ($har60At+$srcFirst*4096L) ($n*4096L); & $dma 18 $cLo 25 ($har60At+$tiles60*4096L+$srcFirst*4096L) ($n*4096L)
            & $fillVectors $cPmHi (($b-$a)*128) 0x80008000L; & $fillVectors $cPmLo (($b-$a)*128) 0
            & $sync
            $vHi=$cHi-$srcFirst*4096L; $vLo=$cLo-$srcFirst*4096L; $vPmHi=$cPmHi-$a*16384L; $vPmLo=$cPmLo-$a*16384L
            $full=[math]::Min($b,$phaseTileCount)-$a
            if(-not $RuntimeFrames -and $full -gt 0){ & $parallel 'body_har_phase_major_tiles' @($vHi,$vLo,$cPmHi,$cPmLo,$vPmHi) @($false,$false,$true,$true,$false) $full }
            if($upFramesWhole%32 -and $phaseTileCount -ge $a -and $phaseTileCount -lt $b){
                & $imm 0 ($upFramesWhole%32); & $ptr 1 18 $vHi; & $ptr 2 18 $vLo; & $ptr 3 18 $vPmHi; & $ptr 4 18 $vPmLo; & $imm 5 (32*$phaseTileCount)
                & $call 'body_har_phase_major'
            }
            if($b -eq $tiles10){ & $imm 0 1; & $ptr 1 18 $vHi; & $ptr 2 18 $vLo; & $ptr 3 18 $vPmHi; & $ptr 4 18 $vPmLo; & $imm 5 $upFramesWhole; & $call 'body_har_phase_major_last' }
            & $sync
            & $dma 25 ($harPmAt+$a*16384L) 18 $cPmHi (($b-$a)*16384L); & $dma 25 ($harPmAt+$tiles10*16384L+$a*16384L) 18 $cPmLo (($b-$a)*16384L)
        }
    }
    & $poolStart
    $stopped=$false
    if($Decoder){ & $mark 'Boundary' 'Decoder'; $decJob=Add-KokoroDecoder16JobSteps -Steps $s -Calls $calls -Frames $decIn -InputBase 20 -InputOffset $decInOff -WeightsBase 21 -WeightsOffset $decWOff -TablesBase 22 -TablesOffset $decPOff -OutputBase 25 -OutputOffset $decSlot -Moments $DecoderMoments; & $mark 'Decoder' 'Setup'; & $mark 'Unmarked' -site 30; & $sync }
    if($Source){
        & $mark 'Boundary' 'Source'
        Add-KokoroHarmonicSource16JobSteps -Steps $s -Calls $calls -Frames $sourceFrames -InputBase 20 -InputOffset $sourceIn -WeightsBase 21 -WeightsOffset $sourceW -TablesBase 22 -TablesOffset $sourceP -HarBase 25 -HarOffset $har60At -SeededNoise:$SeededNoise -ChunkTiles $chunkTilesOfSource
        & $mark 'Source' 'HarLayout'
        & $mark 'Unmarked' -site 31; & $sync
        if($spanMode){ . $harLayoutChunks }
        else {
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
        }
        & $mark 'Unmarked' -site 34; & $sync
    }
    # Backward schedule (see -Schedule). A step moves a block of $batch tiles. A block operand is a constant block index
    # (the unrolled edge steps) or $null, the runtime step in r17 (free in every body this schedule calls).
    # Controller contact: register r <- the controller word of tile `within` of block (block + delta), one word per tile.
    $controllerPointer={param([int]$r,$block,[int]$delta,[int]$within)
        if($null -ne $block){ & $ptr $r 18 ($tileRegions.Controller+4L*(($block+$delta)*$batch+$within)); return }
        $s.Add(@{Op='addi';d=$r;s=17;i=$delta}); $s.Add(@{Op='asl-i';d=$r;s=$r;i=($batchShift+2)})
        & $imm 15 ($tileRegions.Controller+4L*$within); $s.Add(@{Op='add';d=$r;s=$r;t=15}); $s.Add(@{Op='add';d=$r;s=$r;t=18})
    }
    $dmaRegisters={param([long]$length) & $ledgerAdd 'Tensor' $length; & $imm 3 $length; $s.Add(@{Op='addi';d=0;s=24;i=0}); foreach($step in @(New-KokoroDmaCopySteps -NoReturn)){$s.Add($step)} }
    # Backward schedule. Register r <- tile (BatchTiles block + delta) of a ring of ringTiles tiles (a power of two) at
    # base: a constant block, or at run time the step in r17. Tiles are virtual; the mask is the wrap.
    $tileAt={param([int]$r,[long]$base,[int]$ringTiles,$block,[int]$delta)
        if($null -ne $block){ & $ptr $r 18 ($base+(((($batch*$block+$delta) % $ringTiles)+$ringTiles) % $ringTiles)*[long]$tileBytes); return }
        $s.Add(@{Op='asl-i';d=$r;s=17;i=$batchShift}); $s.Add(@{Op='addi';d=$r;s=$r;i=$delta})
        & $imm 15 ($ringTiles-1); $s.Add(@{Op='and';d=$r;s=$r;t=15}); $s.Add(@{Op='asl-i';d=$r;s=$r;i=$tileShift})
        & $imm 15 $base; $s.Add(@{Op='add';d=$r;s=$r;t=15}); $s.Add(@{Op='add';d=$r;s=$r;t=18})
    }
    $tileArg={param([long]$base,$block,[int]$delta) @{Base=$base;RingTiles=$ringTiles;Block=$block;Delta=$delta}}
    # Segmented call: segment k runs its body on HVX thread k (0 the main thread) with its own arguments (VTCM offsets,
    # @{Register=r} the caller's register r, ring tiles from $tileArg, controller words) and count; an optional Extra
    # argument reaches the body in r5 (pool slot 56, loaded by the chunked schedule's workers).
    $dispatch={param([string]$body,[object[]]$segments)
        if($HvxThreads -lt 3 -or $segments.Count -gt $HvxThreads){throw 'A segmented dispatch needs one HVX thread per segment, at least three.'}
        $value={param([int]$r,$a)
            if($a -is [hashtable] -and $a.ContainsKey('Register')){ $s.Add(@{Op='addi';d=$r;s=$a.Register;i=0}) }
            elseif($a -is [hashtable] -and $a.ContainsKey('RingTiles')){ & $tileAt $r $a.Base $a.RingTiles $a.Block $a.Delta }
            elseif($a -is [hashtable] -and $a.Controller){ & $controllerPointer $r $a.Block $a.Delta $a.Within }
            else { & $ptr $r 18 $a } }
        if(@($segments | Where-Object { $_.Contains('Extra') }).Count -and -not $anyChunked){ throw 'Only the chunked schedule loads the Extra argument.' }
        $n=$segments[0].Arguments.Count
        for($k=1;$k -lt $HvxThreads;$k++){
            & $ptr 6 25 ($poolOffset+64*$k)
            $c=if($k -lt $segments.Count){$segments[$k].Count}else{0}
            if($c -gt 0){
                for($i=0;$i -lt $n;$i++){ & $value 0 $segments[$k].Arguments[$i]; $s.Add(@{Op='store';s=6;t=0;Offset=(4*$i)}) }
                if($segments[$k].Contains('Extra')){ & $value 0 $segments[$k].Extra; $s.Add(@{Op='store';s=6;t=0;Offset=56}) }
                & $imm 0 $c; $s.Add(@{Op='store';s=6;t=0;Offset=(4*$n)})
                if($anyChunked -and $n -ge 5 -and -not $segments[$k].Contains('Extra')){ $s.Add(@{Op='store';s=6;t=0;Offset=56}) }
                & $addr 0 $(if($segments[$k].Contains('Body')){$segments[$k].Body}else{$body}); $s.Add(@{Op='store';s=6;t=0;Offset=44})
            }
            & $imm 0 $c; $s.Add(@{Op='store';s=6;t=0;Offset=48})
        }
        & $wake
        for($i=0;$i -lt $n;$i++){ & $value $i $segments[0].Arguments[$i] }
        if($segments[0].Contains('Extra')){ & $value 5 $segments[0].Extra }
        & $imm $n $segments[0].Count; & $call $(if($segments[0].Contains('Body')){$segments[0].Body}else{$body})
        & $join
    }
    # Setup of both depth-first schedules: every stage's record, weights and supplied AdaIN values, its K/M/S computed once.
    $stageSetup={
        foreach($g in $tileStages){
            $index=6*$g.Branch+$g.Stage; $rAt=$tileRegions.Records+$index*$recordBytes
            & $dma 18 $rAt 22 $g.RecordOffset $recordBytes
            if($sectionSchedule -eq 'Backward'){ & $dma 18 $tileWeightAt[$index] 21 $g.WeightOffset $g.WeightBytes }
            $site=$siteByRecord[[long]$g.RecordOffset]
            if($HostCoefficients){ & $dma 18 ($tileRegions.Kms+$index*$kmsBytes) 22 ($hostCoefficientsOffset+$site.KmOffset) $site.KmBytes; & $mark 'Coefficients' }
            else {
                & $dma 18 $tileRegions.Moments 22 ($constantsTableOffset+$site.Offset) $site.Bytes
                & $ptr 0 18 $tileRegions.Moments; & $ptr 1 18 $rAt; & $ptr 2 18 ($tileRegions.Kms+$index*$kmsBytes); & $call "body_constant$sfx"; & $mark 'Coefficients'
            }
            if($ControllerContact){ & $dma 18 ($tileRegions.Kms+$index*$kmsBytes+12L*$Channels) 22 ($contactOffset+$index*8L*$Channels) (8L*$Channels) }
        }
        if($ControllerContact){ & $dma 18 $tileRegions.Controller 22 ($contactOffset+18L*8*$Channels) $controllerBytes }
    }
    # Backward schedule geometry. Pair p of branch b (kernel K; dilation 1 + 2p, then 1): the first convolution taps
    # r1 = (1 + 2p)(K - 1)/2 rows late and the second 32 - r1, so every pair emerges exactly one tile late and r1 + r2 <= 30
    # keeps both backward. Stage st's conv-input row R of branch b holds position row R - stageRows; level p's residual
    # tile m holds position tile m - p; the mean tile m holds position tile m - 3.
    $pairReach={param([int]$branch,[int]$p) [int]((1+2*$p)*($sectionKernels[$branch]-1)/2)}
    $stageRows={param([int]$branch,[int]$st) $p=[int][math]::Floor($st/2); if($st % 2){ 32*$p+(& $pairReach $branch $p) } else { 32*$p }}
    $tapDelay={param([int]$branch,[int]$st) $p=[int][math]::Floor($st/2); if($st % 2){ 32-(& $pairReach $branch $p) } else { & $pairReach $branch $p }}
    # A conv-input tile's edge treatment: $null inside the section's frames, 'Zero' wholly outside, else the row range
    # (first, end) outside, set to the conv-input zero after the fill.
    $edgeFix={param([int]$tile,[int]$rows)
        $lo=32*$tile-$rows; $hi=$lo+31
        if($hi -lt 0 -or $lo -ge $Frames){ return 'Zero' }
        if($lo -lt 0){ return ,@(0,(-$lo)) }
        if($hi -ge $Frames){ return ,@(($Frames-$lo),32) }
        $null
    }
    # A step that needs any edge treatment, a partial input or output block, or a residual's padded rows is unrolled.
    $edgeStep={param([int]$block)
        if($batch*$block+$batch -gt $tiles -or $batch*$block -lt 3){ return $true }
        for($w=0;$w -lt $batch;$w++){
            for($st=0;$st -lt 6;$st++){ for($branch=0;$branch -lt $branches;$branch++){ if($null -ne (& $edgeFix ($batch*$block+$w) (& $stageRows $branch $st))){ return $true } } }
            for($p=0;$p -lt 3;$p++){ $lo=32*($batch*$block+$w-$p-1); if($lo -lt $Frames -and $lo+31 -ge $Frames){ return $true } }
        }
        $false
    }
    $fillSource={param([int]$st)
        if($st -eq 0){ return ,@($tileRegions.Input,'shared') }
        if($st % 2){ return ,@(($tileRegions.Stage+[long]$branches*(($st-1)/2)*$ringBytes),'branch') }
        ,@(($tileRegions.Levels+[long]$branches*($st/2-1)*$ringBytes),'branch')
    }
    # Lockstep threads. QuRT matrix lock traps (Kokoro.HmxMatrixProbe.ps1): try-lock is r5 = 2, trap0(#0x1d), 0 in
    # r0 on success; unlock2(0) is r0 = 0, r5 = 1.
    $matrixLock={ $again=& $label; $held=& $label
        $s.Add(@{Op='label';Name=$again}); $s.Add(@{Op='imm';d=5;i=2}); $s.Add(@{Op='trap0';i=0x1d})
        $s.Add(@{Op='imm';d=1;i=0}); $s.Add(@{Op='eq';d=0;s=0;t=1}); $s.Add(@{Op='jump-p';u=0;Label=$held})
        $s.Add(@{Op='pause';i=$poolPause}); & $jump $again
        $s.Add(@{Op='label';Name=$held}) }
    $matrixUnlock={ $s.Add(@{Op='imm';d=0;i=0}); $s.Add(@{Op='imm';d=5;i=1}); $s.Add(@{Op='trap0';i=0x1d}) }
    # Register r <- 6 block + add: a thread's progress count after a stage (block constant, or r17 at run time).
    $progressValue={param([int]$r,$block,[int]$add)
        if($null -ne $block){ & $imm $r (6L*$block+$add); return }
        $s.Add(@{Op='imm';d=15;i=6}); $s.Add(@{Op='mpyi';d=$r;s=17;t=15}); $s.Add(@{Op='addi';d=$r;s=$r;i=$add}) }
    # Wait until the thread holding tile 4 j + k - 1 has completed stage st (its progress word > 6 j' + st).
    $waitNeighbor={param($block,[int]$thread,[int]$st)
        if($null -ne $block -and $thread -eq 0 -and $block -eq 0){ return }
        $neighbor=($thread+$batch-1) % $batch
        & $progressValue 1 $block $(if($thread -eq 0){$st-6}else{$st})
        & $ptr 2 18 ($tileRegions.Progress+4*$neighbor)
        $again=& $label; $ready=& $label
        $s.Add(@{Op='label';Name=$again}); $s.Add(@{Op='load';d=3;s=2;Offset=0}); $s.Add(@{Op='gt';d=0;s=3;t=1}); $s.Add(@{Op='jump-p';u=0;Label=$ready})
        $s.Add(@{Op='pause';i=$poolPause}); & $jump $again
        $s.Add(@{Op='label';Name=$ready}) }
    $publish={param($block,[int]$thread,[int]$st)
        $s.Add(@{Op='syncht'}); & $progressValue 1 $block ($st+1); & $ptr 2 18 ($tileRegions.Progress+4*$thread); $s.Add(@{Op='store';s=2;t=1;Offset=0}) }
    # Thread k's tile of block j through every stage, the mean and its output.
    $lockstepTile={param($block,[int]$parity,[int]$thread)
        $w=$thread; $tile=if($null -eq $block){$null}else{$batch*$block+$w}
        if($null -eq $block -or $tile -lt $tiles){
            if($null -ne $block){ & $dma 18 ($tileRegions.Input+($tile % $ringTiles)*[long]$tileBytes) $r0Base ($r0Offset+$tile*[long]$tileBytes) $tileBytes }
            else {
                $s.Add(@{Op='asl-i';d=1;s=17;i=$blockShift}); & $imm 15 ($r0Offset+$w*[long]$tileBytes); $s.Add(@{Op='add';d=1;s=1;t=15}); $s.Add(@{Op='add';d=1;s=1;t=$r0Base})
                & $tileAt 2 $tileRegions.Input $ringTiles $null $w
                & $dmaRegisters $tileBytes
            }
        }
        for($st=0;$st -lt 6;$st++){
            $p=[int][math]::Floor($st/2); $half=$st % 2; $src=& $fillSource $st
            $highBase=$fillAt["High.$st"]+$guardBytes; $lowBase=$fillAt["Low.$st"]+$guardBytes
            & $tileAt 0 $src[0] $ringTiles $block $w; & $tileAt 1 $highBase $ringTiles $block $w; & $tileAt 2 $lowBase $ringTiles $block $w
            & $ptr 3 18 ($tileRegions.Kms+$st*$kmsBytes); $s.Add(@{Op='imm';d=4;i=1})
            if($ControllerContact){ & $controllerPointer 5 $block 0 ($w-$p) }
            & $call $(if($parity -and $w -ge $batch-2){"body_turnsB_$($src[1])_mirror$sfx"}else{"body_turnsB_$($src[1])$sfx"})
            if($null -ne $block){
                $phys=$tile % $ringTiles
                for($branch=0;$branch -lt $branches;$branch++){
                    $fx=& $edgeFix $tile (& $stageRows $branch $st); if($null -eq $fx){ continue }
                    $deltas=@(0L); if($phys -ge $ringTiles-2){ $deltas+=-$ringBytes }
                    foreach($delta in $deltas){
                        $hiAt=$highBase+$branch*$fillBytes+$phys*[long]$tileBytes+$delta; $loAt=$lowBase+$branch*$fillBytes+$phys*[long]$tileBytes+$delta
                        if($fx -is [string]){ & $fill $hiAt 1 0x80008000L; & $fill $loAt 1 0 } else { & $padRows $hiAt 0x8000 $fx[0] $fx[1]; & $padRows $loAt 0 $fx[0] $fx[1] }
                    }
                }
            }
            & $waitNeighbor $block $thread $st
            $s.Add(@{Op='syncht'}); & $matrixLock
            for($branch=0;$branch -lt $branches;$branch++){
                $at=6*$branch+$st
                & $tileAt 0 ($highBase+$branch*$fillBytes) $ringTiles $block $w; & $tileAt 1 ($lowBase+$branch*$fillBytes) $ringTiles $block $w
                & $ptr 2 18 $tileWeightAt[$at]; & $ptr 3 18 ($tileRegions.Records+$at*$recordBytes+$tablesAt); $s.Add(@{Op='imm';d=4;i=1}); & $ptr 5 18 ($tileRegions.Planes+$branch*$planesStride+$w*[long]$tileBytes)
                & $call "body_convB_b${branch}_s$st$sfx"
            }
            & $matrixUnlock; $s.Add(@{Op='syncht'})
            $rAt=$tileRegions.Records+$st*$recordBytes
            & $ptr 0 18 ($tileRegions.Planes+$w*[long]$tileBytes); & $ptr 2 18 ($rAt+$ratiosAt); $s.Add(@{Op='imm';d=3;i=1})
            if($half -eq 0){ & $tileAt 1 ($tileRegions.Stage+[long]$branches*$p*$ringBytes) $ringTiles $block $w; & $call "body_combine_convB$sfx" }
            else {
                $residual=if($p -eq 0){@($tileRegions.Input,'shared')}else{@(($tileRegions.Levels+[long]$branches*($p-1)*$ringBytes),'branch')}
                & $tileAt 1 ($tileRegions.Levels+[long]$branches*$p*$ringBytes) $ringTiles $block $w; & $tileAt 5 $residual[0] $ringTiles $block ($w-1)
                & $call "body_combine_residualB_$($residual[1])$sfx"
                if($null -ne $block){
                    $lo=32*($tile-$p-1)
                    if($lo -lt $Frames -and $lo+31 -ge $Frames){ for($branch=0;$branch -lt $branches;$branch++){ & $padRows ($tileRegions.Levels+([long]$branches*$p+$branch)*$ringBytes+($tile % $ringTiles)*[long]$tileBytes) 0x8000 ($Frames-$lo) 32 } }
                }
            }
            & $publish $block $thread $st
        }
        # The output tile (position m - 3): the three branches' mean, or one branch's last level.
        if($branches -eq 3){
            for($branch=0;$branch -lt 3;$branch++){ & $tileAt $branch ($tileRegions.Levels+(6L+$branch)*$ringBytes) $ringTiles $block $w }
            & $ptr 3 18 ($tileRegions.Mean+$w*[long]$tileBytes); $s.Add(@{Op='imm';d=4;i=1}); & $call "body_mean$sfx"; $s.Add(@{Op='syncht'})
        }
        $outRing=$tileRegions.Levels+2L*$ringBytes
        if($null -ne $block){
            $outAt=if($branches -eq 3){$tileRegions.Mean+$w*[long]$tileBytes}else{$outRing+($tile % $ringTiles)*[long]$tileBytes}
            if($tile-3 -ge 0 -and $tile-3 -lt $tiles){ & $dma 25 ($finalOffset+($tile-3)*[long]$tileBytes) 18 $outAt $tileBytes }
        } else {
            if($branches -eq 3){ & $ptr 1 18 ($tileRegions.Mean+$w*[long]$tileBytes) } else { & $tileAt 1 $outRing $ringTiles $null $w }
            $s.Add(@{Op='asl-i';d=2;s=17;i=$blockShift}); & $imm 15 ($finalOffset+($w-3L)*$tileBytes); $s.Add(@{Op='add';d=2;s=2;t=15}); $s.Add(@{Op='add';d=2;s=2;t=25})
            & $dmaRegisters $tileBytes
        }
    }
    # Thread k's program: r0 VTCM base, r1 the DDR workspace, r2 the input buffer; r16 to r27 saved; r24 its own DMA
    # descriptor slots in its frame. It runs the section's steps j0 .. j1 - 1.
    # Steps j0 .. j1 - 1 of the bound section: a step that needs edge treatment unrolled at its block, each run of
    # uniform steps as a loop over r17 whose body is `period` steps (ring slot parities), steps the period leaves over
    # unrolled. step: {param($block, $parity)}.
    $stepRange={param([int]$j0,[int]$j1,[scriptblock]$step,[int]$period)
        $j=$j0
        while($j -lt $j1){
            if(& $edgeStep $j){ & $step $j ($j % 2); $j++; continue }
            $end=$j; while($end -lt $j1 -and -not (& $edgeStep $end)){ $end++ }
            $loopEnd=$j+$period*[int][math]::Floor(($end-$j)/$period)
            if($loopEnd -gt $j){
                & $imm 17 $j
                $steps=& $label; $stepsDone=& $label
                $s.Add(@{Op='label';Name=$steps})
                $outerRepeat=$dmaRepeat; $dmaRepeat=$outerRepeat*[long](($loopEnd-$j)/$period)
                for($i=0;$i -lt $period;$i++){ & $step $null (($j+$i) % 2); $s.Add(@{Op='addi';d=17;s=17;i=1}) }
                $dmaRepeat=$outerRepeat
                & $imm 15 $loopEnd; $s.Add(@{Op='eq';d=0;s=17;t=15}); $s.Add(@{Op='jump-p';u=0;Label=$stepsDone}); & $jump $steps
                $s.Add(@{Op='label';Name=$stepsDone})
            }
            for($k=$loopEnd;$k -lt $end;$k++){ & $step $k ($k % 2) }
            $j=$end
        }
    }
    # Runtime: the steps start at r3 and number r4 (the dispatch's register argument and segment count), all uniform,
    # an even count starting on the parity of j0.
    $lockstepProgram={param([int]$thread,[int]$j0,[int]$j1,[switch]$Runtime)
        $s.Add(@{Op='allocframe';Bytes=256})
        foreach($r in 16,18,20,22,24,26){ $s.Add(@{Op='store-d';s=29;t=$r;Offset=(($r-16)*4)}) }
        $s.Add(@{Op='addi';d=18;s=0;i=0}); $s.Add(@{Op='addi';d=25;s=1;i=0}); $s.Add(@{Op='addi';d=20;s=2;i=0})
        $s.Add(@{Op='addi';d=24;s=29;i=(64+63)}); & $imm 0 -64; $s.Add(@{Op='and';d=24;s=24;t=0})
        if($Runtime){
            $s.Add(@{Op='addi';d=17;s=3;i=0}); $s.Add(@{Op='add';d=16;s=3;t=4})
            $steps=& $label; $stepsDone=& $label
            $s.Add(@{Op='label';Name=$steps})
            $dmaRepeat=$dmaRepeat*[long][math]::Floor(($j1-$j0)/2)
            foreach($stepInPair in 0,1){ & $lockstepTile $null (($j0+$stepInPair) % 2) $thread; $s.Add(@{Op='addi';d=17;s=17;i=1}) }
            $s.Add(@{Op='eq';d=0;s=17;t=16}); $s.Add(@{Op='jump-p';u=0;Label=$stepsDone}); & $jump $steps
            $s.Add(@{Op='label';Name=$stepsDone})
        }
        # The loop body is two steps (an even and an odd ring slot).
        else { & $stepRange $j0 $j1 { param($block,$parity) & $lockstepTile $block $parity $thread } 2 }
        foreach($r in 16,18,20,22,24,26){ $s.Add(@{Op='load-d';d=$r;s=29;Offset=(($r-16)*4)}) }
        $s.Add(@{Op='dealloc-return'})
    }
    $backwardInit={
        . $stageSetup
        # Conv-input rings and guards start as the conv-input zero; residual and stage rings as x = 0.
        foreach($plane in 'High','Low'){ for($st=0;$st -lt 6;$st++){ & $fill $fillAt["$plane.$st"] ($branches*($ringTiles+2)) $(if($plane -eq 'High'){0x80008000L}else{0L}) } }
        & $fill $tileRegions.Input $ringTiles 0x80008000L; & $fill $tileRegions.Levels (3*$branches*$ringTiles) 0x80008000L; & $fill $tileRegions.Stage (3*$branches*$ringTiles) 0x80008000L
        & $mark 'Boundary' "Res${Channels}_0"
    }
    # Steps j0 .. j1 - 1: thread programs as bodies named by runName (no PMU marks inside: four threads would share the
    # records), then one dispatch. The progress words start at zero with the first step and carry across runs.
    # Runtime (a uniform span run in the span loop): the first step goes to the threads in r19 (an immediate the span loop
    # makes span-relative) and the step count as the segment count.
    $backwardRun={param([int]$j0,[int]$j1,[string]$runName,[switch]$Runtime)
        $runSteps=$s; $marksOff=$true
        for($thread=0;$thread -lt $batch;$thread++){ $s=[Collections.Generic.List[hashtable]]::new(); & $lockstepProgram $thread $j0 $j1 -Runtime:$Runtime; $lockstepBodies.Add(@("body_lockstep_t$thread$sfx$runName",$s.ToArray())) }
        $s=$runSteps; $marksOff=$false
        if($j0 -eq 0){ & $ptr 2 18 $tileRegions.Progress; $s.Add(@{Op='imm';d=1;i=0}); for($k=0;$k -lt $batch;$k++){ $s.Add(@{Op='store';s=2;t=1;Offset=(4*$k)}) } }
        $s.Add(@{Op='syncht'}); & $matrixUnlock
        if($Runtime){
            if(($j1-$j0) % 2 -or ($j1-$j0) -lt 2){throw 'A runtime lockstep run is an even number of steps.'}
            & $imm 19 $j0
            & $dispatch "body_lockstep_t0$sfx$runName" @(for($thread=0;$thread -lt $batch;$thread++){ @{Count=($j1-$j0);Body="body_lockstep_t$thread$sfx$runName";Arguments=@(@{Register=18},@{Register=25},@{Register=20},@{Register=19})} })
        }
        else { & $dispatch "body_lockstep_t0$sfx$runName" @(for($thread=0;$thread -lt $batch;$thread++){ @{Count=1;Body="body_lockstep_t$thread$sfx$runName";Arguments=@(@{Register=18},@{Register=25},@{Register=20})} }) }
        & $matrixLock; & $mark 'Lockstep'
    }
    # Chunked schedule. VTCM bytes srcOff -> destOff on the main thread, 1 KiB at a time.
    $copyTiles={param([long]$destOff,[long]$srcOff,[long]$bytes)
        & $ptr 4 18 $srcOff; & $ptr 5 18 $destOff; & $imm 6 ($bytes/1024); $s.Add(@{Op='imm';d=7;i=0})
        $n=& $label; $s.Add(@{Op='label';Name=$n})
        for($k=0;$k -lt 8;$k++){ $s.Add(@{Op='vload';d=$k;s=4;Offset=(128*$k)}) }
        for($k=0;$k -lt 8;$k++){ $s.Add(@{Op='vstore';s=5;t=$k;Offset=(128*$k)}) }
        $s.Add(@{Op='addi';d=4;s=4;i=1024}); $s.Add(@{Op='addi';d=5;s=5;i=1024}); $s.Add(@{Op='addi';d=6;s=6;i=-1}); $s.Add(@{Op='gtu';d=0;s=6;t=7}); $s.Add(@{Op='jump-p';u=0;Label=$n})
        & $mark 'TileFix'
    }
    # Stage st's saved history of branch b in plane (0 high, 1 low), and its conv-input buffer's tile i (0 and 1 history,
    # 2 + w tile w of the block).
    $historyAt={param([int]$st,[int]$plane,[int]$branch) $tileRegions.History+(2L*$st+$plane)*$historyBytes+$branch*$guardBytes}
    $workAt={param([int]$plane,[int]$branch,[int]$i) $fillAt[@('High','Low')[$plane]]+$branch*$fillBytes+$i*[long]$tileBytes}
    # Step: block j (a constant, or $null for the runtime step in r17) through every stage, stage by stage.
    $chunkedStep={param($block)
        $inputTiles=if($null -eq $block){$batch}else{[math]::Max(0,[math]::Min($batch,$tiles-$batch*$block))}
        if($inputTiles -gt 0){
            if($null -ne $block){ & $dma 18 ($tileRegions.Input+(($batch*$block) % $ringTiles)*[long]$tileBytes) $r0Base ($r0Offset+$batch*$block*[long]$tileBytes) ($inputTiles*[long]$tileBytes) }
            else {
                $s.Add(@{Op='asl-i';d=1;s=17;i=$blockShift}); & $imm 15 $r0Offset; $s.Add(@{Op='add';d=1;s=1;t=15}); $s.Add(@{Op='add';d=1;s=1;t=$r0Base})
                & $tileAt 2 $tileRegions.Input $ringTiles $null 0
                & $dmaRegisters $blockBytes; & $mark 'Dma'
            }
        }
        for($st=0;$st -lt 6;$st++){
            $p=[int][math]::Floor($st/2); $half=$st % 2; $src=& $fillSource $st
            for($branch=0;$branch -lt $branches;$branch++){ & $dma 18 ($tileRegions.Weights+$streamAt[$branch]) 21 $tileStages[6*$branch+$st].WeightOffset $tileStages[6*$branch+$st].WeightBytes }
            for($plane=0;$plane -lt 2;$plane++){ for($branch=0;$branch -lt $branches;$branch++){ & $copyTiles (& $workAt $plane $branch 0) (& $historyAt $st $plane $branch) $guardBytes } }
            $segments=[Collections.Generic.List[object]]::new()
            for($w=0;$w -lt $batch;$w++){
                $segment=@{Count=1;Body="body_turnsB_$($src[1])$sfx";Arguments=@((& $tileArg $src[0] $block $w),(& $workAt 0 0 (2+$w)),(& $workAt 1 0 (2+$w)),($tileRegions.Kms+$st*$kmsBytes))}
                if($ControllerContact){ $segment.Extra=@{Controller=$true;Block=$block;Delta=0;Within=($w-$p)} }
                $segments.Add($segment)
            }
            & $dispatch $segments[0].Body $segments.ToArray(); & $mark 'AdaInSnake'
            if($null -ne $block){
                for($w=0;$w -lt $batch;$w++){ for($branch=0;$branch -lt $branches;$branch++){
                    $fx=& $edgeFix ($batch*$block+$w) (& $stageRows $branch $st); if($null -eq $fx){ continue }
                    $hiAt=& $workAt 0 $branch (2+$w); $loAt=& $workAt 1 $branch (2+$w)
                    if($fx -is [string]){ & $fill $hiAt 1 0x80008000L; & $fill $loAt 1 0 } else { & $padRows $hiAt 0x8000 $fx[0] $fx[1]; & $padRows $loAt 0 $fx[0] $fx[1] }
                } }
            }
            & $sync
            for($branch=0;$branch -lt $branches;$branch++){
                $at=6*$branch+$st
                & $ptr 0 18 (& $workAt 0 $branch 2); & $ptr 1 18 (& $workAt 1 $branch 2)
                & $ptr 2 18 ($tileRegions.Weights+$streamAt[$branch]); & $ptr 3 18 ($tileRegions.Records+$at*$recordBytes+$tablesAt); & $imm 4 $batch; & $ptr 5 18 ($tileRegions.Planes+$branch*$planesStride)
                & $call "body_convB_b${branch}_s$st$sfx"
            }
            & $mark 'HmxConv'; & $sync
            for($plane=0;$plane -lt 2;$plane++){ for($branch=0;$branch -lt $branches;$branch++){ & $copyTiles (& $historyAt $st $plane $branch) (& $workAt $plane $branch $batch) $guardBytes } }
            $rAt=$tileRegions.Records+$st*$recordBytes; $segments=[Collections.Generic.List[object]]::new()
            for($w=0;$w -lt $batch;$w++){
                $planes=$tileRegions.Planes+$w*[long]$tileBytes
                if($half -eq 0){ $segments.Add(@{Count=1;Body="body_combine_convB$sfx";Arguments=@($planes,(& $tileArg ($tileRegions.Stage+[long]$branches*$p*$ringBytes) $block $w),($rAt+$ratiosAt))}) }
                else {
                    $residual=if($p -eq 0){@($tileRegions.Input,'shared')}else{@(($tileRegions.Levels+[long]$branches*($p-1)*$ringBytes),'branch')}
                    $segments.Add(@{Count=1;Body="body_combine_residualB_$($residual[1])$sfx";Arguments=@($planes,(& $tileArg ($tileRegions.Levels+[long]$branches*$p*$ringBytes) $block $w),($rAt+$ratiosAt));Extra=(& $tileArg $residual[0] $block ($w-1))})
                }
            }
            & $dispatch $segments[0].Body $segments.ToArray(); & $mark 'Combine'
            if($half -eq 1 -and $null -ne $block){
                for($w=0;$w -lt $batch;$w++){
                    $lo=32*($batch*$block+$w-$p-1); if($lo -ge $Frames -or $lo+31 -lt $Frames){ continue }
                    for($branch=0;$branch -lt $branches;$branch++){ & $padRows ($tileRegions.Levels+([long]$branches*$p+$branch)*$ringBytes+(($batch*$block+$w) % $ringTiles)*[long]$tileBytes) 0x8000 ($Frames-$lo) 32 }
                }
            }
        }
        # The output: the three branches' mean, or one branch's last level (a block's ring tiles are contiguous).
        if($branches -eq 3){
            $segments=@(for($w=0;$w -lt $batch;$w++){ @{Count=1;Body="body_mean$sfx";Arguments=@((& $tileArg ($tileRegions.Levels+6L*$ringBytes) $block $w),(& $tileArg ($tileRegions.Levels+7L*$ringBytes) $block $w),(& $tileArg ($tileRegions.Levels+8L*$ringBytes) $block $w),($tileRegions.Mean+$w*[long]$tileBytes))} })
            & $dispatch "body_mean$sfx" $segments; & $mark 'Mean'; & $sync
        }
        $outRing=$tileRegions.Levels+2L*$ringBytes
        if($null -ne $block){
            $first=[math]::Max(0,3-$batch*$block); $last=[math]::Min($batch-1,$tiles+2-$batch*$block)
            $outAt=if($branches -eq 3){$tileRegions.Mean+$first*[long]$tileBytes}else{$outRing+((($batch*$block) % $ringTiles)+$first)*[long]$tileBytes}
            if($first -le $last){ & $dma 25 ($finalOffset+($batch*$block+$first-3)*[long]$tileBytes) 18 $outAt (($last-$first+1)*[long]$tileBytes) }
        } else {
            if($branches -eq 3){ & $ptr 1 18 $tileRegions.Mean } else { & $tileAt 1 $outRing $ringTiles $null 0 }
            $s.Add(@{Op='asl-i';d=2;s=17;i=$blockShift}); & $imm 15 ($finalOffset-3L*$tileBytes); $s.Add(@{Op='add';d=2;s=2;t=15}); $s.Add(@{Op='add';d=2;s=2;t=25})
            & $dmaRegisters $blockBytes; & $mark 'Dma'
        }
    }
    $chunkedInit={
        . $stageSetup
        # Conv-input buffers and saved history start as the conv-input zero; residual and stage rings as x = 0.
        & $fill $fillAt.High ($branches*($batch+2)) 0x80008000L; & $fill $fillAt.Low ($branches*($batch+2)) 0L
        for($st=0;$st -lt 6;$st++){ & $fill (& $historyAt $st 0 0) (2*$branches) 0x80008000L; & $fill (& $historyAt $st 1 0) (2*$branches) 0L }
        & $fill $tileRegions.Input $ringTiles 0x80008000L; & $fill $tileRegions.Levels (3*$branches*$ringTiles) 0x80008000L; & $fill $tileRegions.Stage (3*$branches*$ringTiles) 0x80008000L
        & $mark 'Boundary' "Res${Channels}_0"
    }
    $chunkedRun={param([int]$j0,[int]$j1) & $stepRange $j0 $j1 { param($block,$parity) & $chunkedStep $block } 1 }
    # The bound section's schedule: its initial state, and its steps j0 .. j1 - 1.
    $sectionInit={ if($sectionSchedule -eq 'Backward'){ . $backwardInit } else { . $chunkedInit } }
    $sectionRun={param([int]$j0,[int]$j1,[string]$runName) if($sectionSchedule -eq 'Backward'){ . $backwardRun $j0 $j1 $runName } else { . $chunkedRun $j0 $j1 } }
    # The tail on the section's final tensor (DDR workspace): PCM into the output buffer.
    $tailSteps={
        & $mark 'Boundary' 'Tail'
        & $mark 'Unmarked' -site 51; & $sync
        Add-KokoroGeneratorTail16JobSteps -Steps $s -Calls $calls -Frames $Frames -InputBase 25 -InputOffset $finalOffset -WeightsBase 21 -WeightsOffset $tailWeightOffset -TablesBase 22 -TablesOffset $tailParameterOffset -PcmBase 23 -PcmOffset $pcmOffset
        & $mark 'Tail' 'Exit'
    }
    $lockstepBodies=[Collections.Generic.List[object]]::new()
    # Span fronts (the layer fronts' arithmetic over a tile range, $spanFront regions). Each reads its input tiles with
    # one tile of halo from the full-length tensor (zero planes past either end), adds the section's supplied source
    # stream and writes the section input to the workspace (r25 + r0Slot) at its tiles.
    # 256-channel front over decoder tiles d0 .. d1 - 1: LeakyReLU(0.1) of x, the ten ups[0] phases, interleave.
    $spanFront0={param([int]$d0,[int]$d1)
        $F=$spanFront; $n=$d1-$d0; $first=[math]::Max(0,$d0-1); $last=[math]::Min($decTiles,$d1+1)
        $t0=10*$d0; $t1=[math]::Min($tiles,10*$d1)
        $pairs=if($d1 -eq $decTiles){[int][math]::Ceiling(($decFrames-32*$d0+1)/2)}else{16*$n}
        & $dma 18 $F.Tables 22 $frontParameterOffset 163840
        & $dma 18 ($F.Input+($first-$d0+1)*32768L) 20 ($inBase+$first*32768L) (($last-$first)*32768L)
        & $ptr 0 18 ($F.Input+($first-$d0+1)*32768L); & $ptr 1 18 ($F.High+($first-$d0+1)*32768L); & $ptr 2 18 ($F.Low+($first-$d0+1)*32768L); & $imm 3 (($last-$first)*256)
        & $call 'body_leaky_up'
        if($d0 -eq 0){ & $fill $F.High 2 0x80008000L; & $fill $F.Low 2 0 }
        if($d1 -eq $decTiles){ & $fill ($F.High+($n+1)*32768L) 2 0x80008000L; & $fill ($F.Low+($n+1)*32768L) 2 0 }
        & $sync
        $upBatch10=[int][math]::Floor($planeStride/16384)
        for($r=0;$r -lt 10;$r++){
            & $dma 18 $F.Weights 21 ($frontWeightOffset+393216+$r*786432L) 786432
            for($start=0;$start -lt $n;$start+=$upBatch10){
                $count=[math]::Min($upBatch10,$n-$start)
                & $ptr 0 18 ($F.High+32768+$start*32768L); & $ptr 1 18 ($F.Low+32768+$start*32768L); & $ptr 2 18 $F.Weights; & $ptr 3 18 ($F.Tables+16384+12288*$r); & $imm 4 $count; & $ptr 5 18 $F.Planes
                & $call 'body_conv_front10_up'; & $mark 'HmxConv'; & $sync
                & $parallel $(if($WeightPlanes -eq 2){"body_combine_conv$sfx"}else{"body_combine_front$sfx"}) @($F.Planes,($(if($r%2){$F.PhaseB}else{$F.PhaseA})+$start*16384L),($F.Tables+139264+1024*$r-1024)) @($true,$true,$false) $count
                & $mark 'Combine'
            }
            if($r%2){ & $sync; & $ptr 0 18 $F.PhaseA; & $ptr 1 18 $F.Target; & $imm 2 (($r-1)/2); & $imm 3 $pairs; & $ptr 4 18 $F.PhaseB; & $call 'body_front10_interleave'; & $mark 'Combine'; & $sync }
        }
        if($ExportFrontTensors){ & $sync; & $dma 25 ($upsSlot+$t0*16384L) 18 $F.Target (($t1-$t0)*16384L) }
        & $dma 18 $F.Sum $sourceBase ($sourceAt+$t0*16384L) (($t1-$t0)*16384L); & $sync
        if(0 -notin $SuppliedSectionInputs){
            & $ptr 0 18 $F.Target; & $ptr 1 18 $F.Sum; & $ptr 2 18 ($F.Tables+149504); & $imm 3 ($t1-$t0)
            & $call 'body_front10_add'; & $mark 'Combine'
        }
        if($t1 -eq $tiles){ & $padRows ($F.Sum+($tiles-1-$t0)*16384L) 0x8000 }
        & $sync; & $dma 25 ($r0Slot+$t0*16384L) 18 $F.Sum (($t1-$t0)*16384L)
    }
    # 128-channel front over 256-channel mean tiles s0 .. s1 - 1 (mean at chainOffset): LeakyReLU(0.1), the three ups[1]
    # phase pairs, interleave, the reflection of frame 0 at the start.
    $spanFront1={param([int]$s0,[int]$s1)
        $F=$spanFront; $n=$s1-$s0; $first=[math]::Max(0,$s0-1); $last=[math]::Min($upTiles,$s1+1)
        $t0=6*$s0; $t1=[math]::Min($tiles,6*$s1)
        $pairs=if($s1 -eq $upTiles){[int][math]::Ceiling(($upFrames-32*$s0)/2)}else{16*$n}
        & $dma 18 $F.Tables 22 $frontParameterOffset 65536
        & $dma 18 ($F.Input+($first-$s0+1)*16384L) 25 ($chainOffset+$first*16384L) (($last-$first)*16384L)
        & $ptr 0 18 ($F.Input+($first-$s0+1)*16384L); & $ptr 1 18 ($F.High+($first-$s0+1)*16384L); & $ptr 2 18 ($F.Low+($first-$s0+1)*16384L); & $imm 3 (($last-$first)*128)
        & $call 'body_leaky_up'
        if($s0 -eq 0){ & $fillVectors $F.High 128 0x80008000L; & $fillVectors $F.Low 128 0 }
        if($s1 -eq $upTiles){ & $fillVectors ($F.High+($n+1)*16384L) 128 0x80008000L; & $fillVectors ($F.Low+($n+1)*16384L) 128 0 }
        & $sync
        for($c=0;$c -lt 3;$c++){
            & $dma 18 $F.Weights 21 ($frontWeightOffset+49152+$c*393216L) 393216
            for($start=0;$start -lt $n;$start+=$upBatch){
                $count=[math]::Min($upBatch,$n-$start)
                & $ptr 0 18 ($F.High+($start+1)*16384L); & $ptr 1 18 ($F.Low+($start+1)*16384L); & $ptr 2 18 $F.Weights; & $ptr 3 18 ($F.Tables+16384+12288*$c); & $imm 4 $count; & $ptr 5 18 $F.Planes
                & $call 'body_conv_front_up'; & $mark 'HmxConv'; & $sync
                & $ptr 0 18 $F.Planes; & $ptr 1 18 ($F.Phase+$start*16384L); & $ptr 2 18 ($F.Tables+53248+2048*$c-1024); & $imm 3 $count
                & $call 'body_combine_conv256'; & $mark 'Combine'; & $sync
            }
            & $ptr 0 18 $F.Phase; & $ptr 1 18 $F.Target; & $imm 2 $c; & $imm 3 $pairs
            & $call 'body_front_interleave'; & $mark 'Combine'; & $sync
        }
        if($s0 -eq 0){
            # Reflection: padded frame 0 is padded frame 2 (even halfwords of row pairs 0 and 1 of tile 0).
            & $imm 6 0xFFFF0000L; $s.Add(@{Op='vsplat';d=30;s=6}); & $imm 6 0x0000FFFFL; $s.Add(@{Op='vsplat';d=31;s=6})
            for($blk=0;$blk -lt 4;$blk++){
                & $ptr 4 18 ($F.Target+2048*$blk); $s.Add(@{Op='vload';d=0;s=4;Offset=0}); $s.Add(@{Op='vload';d=1;s=4;Offset=128})
                $s.Add(@{Op='vand';d=0;s=0;t=30}); $s.Add(@{Op='vand';d=1;s=1;t=31}); $s.Add(@{Op='vor';d=0;s=0;t=1}); $s.Add(@{Op='vstore';s=4;t=0;Offset=0})
            }
        }
        if($ExportFrontTensors){ & $sync; & $dma 25 ($upsSlot+$t0*8192L) 18 $F.Target (($t1-$t0)*8192L) }
        & $dma 18 $F.Sum $sourceBase ($sourceAt+$t0*8192L) (($t1-$t0)*8192L); & $sync
        if(1 -notin $SuppliedSectionInputs){
            & $ptr 0 18 $F.Target; & $ptr 1 18 $F.Sum; & $ptr 2 18 ($F.Tables+59392); & $imm 3 ($t1-$t0)
            & $call 'body_front_add'; & $mark 'Combine'
        }
        if($t1 -eq $tiles){ & $padRows ($F.Sum+($tiles-1-$t0)*8192L) 0x8000 }
        & $sync; & $dma 25 ($r0Slot+$t0*8192L) 18 $F.Sum (($t1-$t0)*8192L)
    }
    # noise_convs of the bound source section over its tiles c0 .. c1 - 1, from har in the workspace with a tile of halo
    # each side (zero past either end), in batches; the sum goes to the section's input in the workspace.
    $spanNoise={param([int]$c0,[int]$c1)
        $F=$spanFront; $n=$c1-$c0; $harTile=if($Channels -eq 256){16384L}else{4096L}
        & $dma 18 $F.Weights 21 $sec.ConvWeights $(if($Channels -eq 256){393216L}else{49152L}); & $dma 18 $F.Tables 22 $sec.ConvTables $(if($Channels -eq 256){163840L}else{65536L})
        & $fill $F.Sum $n 0x80008000L
        for($start=$c0;$start -lt $c1;$start+=$batch){
            $count=[math]::Min($batch,$c1-$start); $first=[math]::Max(0,$start-1); $last=[math]::Min($tiles,$start+$count+1)
            if($start -eq 0){ & $fillVectors $F.Window ($harTile/128) 0x80008000L; & $fillVectors $F.WindowLow ($harTile/128) 0 }
            if($start+$count -eq $tiles){ & $fillVectors ($F.Window+($count+1)*$harTile) ($harTile/128) 0x80008000L; & $fillVectors ($F.WindowLow+($count+1)*$harTile) ($harTile/128) 0 }
            & $dma 18 ($F.Window+($first-$start+1)*$harTile) $sec.HarReg ($sec.HarAt+$first*$harTile) (($last-$first)*$harTile)
            & $dma 18 ($F.WindowLow+($first-$start+1)*$harTile) $sec.HarReg ($sec.HarAt+$tiles*$harTile+$first*$harTile) (($last-$first)*$harTile)
            & $ptr 0 18 ($F.Window+$harTile); & $ptr 1 18 ($F.WindowLow+$harTile); & $ptr 2 18 $F.Weights; & $ptr 3 18 $F.Tables; & $imm 4 $count; & $ptr 5 18 $F.Planes
            & $call $(if($Channels -eq 256){'body_conv_front10_noise'}else{'body_conv_front_noise'}); & $mark 'HmxConv'; & $sync
            & $parallel "body_combine_noise$sfx" @($F.Planes,($F.Sum+($start-$c0)*[long]$tileBytes),($F.Tables+$(if($Channels -eq 256){12288}else{8192}))) @($true,$true,$false) $count
            & $mark 'Combine'
        }
        if($c1 -eq $tiles){ & $padRows ($F.Sum+($tiles-1-$c0)*[long]$tileBytes) 0x8000 }
        & $sync; & $dma 25 ($r0Slot+$c0*[long]$tileBytes) 18 $F.Sum ($n*[long]$tileBytes)
    }
    # A computed source's steps in a span: noise_convs over its tiles, then noise_res steps from its saved state.
    $sourceSpan={param([int]$c0,[int]$c1,[int]$j0,[int]$j1,[int]$stepCount)
        if($c1 -gt $c0){ & $spanNoise $c0 $c1 }
        if($j1 -gt $j0){
            if($j0 -eq 0){ . $sectionInit } else { & $dma 18 $stateFrom 25 $stateSlot $stateBytes; & $sync }
            . $sectionRun $j0 $j1 $runName
            if($j1 -lt $stepCount){ & $sync; & $dma 25 $stateSlot 18 $stateFrom $stateBytes }
        }
    }
    # The tail over output tiles t0 .. t1 - 1 of the bound section's final tensor.
    $tailRange={param([int]$t0,[int]$t1)
        & $mark 'Boundary' 'Tail'; & $sync
        Add-KokoroGeneratorTail16JobSteps -Steps $s -Calls $calls -Frames $Frames -InputBase 25 -InputOffset $finalOffset -WeightsBase 21 -WeightsOffset $tailWeightOffset -TablesBase 22 -TablesOffset $tailParameterOffset -PcmBase 23 -PcmOffset $pcmOffset -FirstTile $t0 -EndTile $t1 -SpanTiles (& $spanMax 'T0' 'T1') -LabelPrefix "t16r$t0"
    }
    # Spans ($spans): per span the 256-channel front and section, then the 128-channel front, section and tail. A
    # section's first steps start from its initial state; later ones restore the state its previous steps saved.
    # One span. Generic: the uniform span's code for the span loop (its lockstep runs take their steps at run time).
    $emitSpan={param($span,[switch]$Generic)
        $runName=if($Generic){'_su'}else{"_s$($span.Index)"}
        $ledgerSpan=if($Generic){"$u0-$($u1-1)"}else{"$($span.Index)"}
        if($StopAfterSpanStage -eq 'Start'){ $spanStopped=$true }
        if($spanStopped){ return }
        if($Source){
            . $bind $sourceSectionOf[0]; $sourceAt=$finalOffset; $sourceBase=25; & $mark 'Boundary' 'Noise256'
            if($span.C1 -gt $span.C0){ & $spanNoise $span.C0 $span.C1; if($StopAfterSpanStage -eq 'Noise256'){ $spanStopped=$true; return } }
            . $sourceSpan $span.C0 $span.C0 $span.R0 $span.R1 $slowSteps; if($span.R1 -gt $span.R0 -and $StopAfterSpanStage -eq 'Source256'){ $spanStopped=$true; return }
        }
        else { $sourceBase=20; $sourceAt=$sourceStreams[0].InputOffset }
        . $bind 0; $slowMean=$finalOffset
        & $mark 'Boundary' 'Front256'
        if($span.D1 -gt $span.D0){ & $spanFront0 $span.D0 $span.D1; if($StopAfterSpanStage -eq 'Front256'){ $spanStopped=$true; return } }
        if($span.J1 -gt $span.J0){
            if($span.J0 -eq 0){ . $sectionInit } else { & $dma 18 $stateFrom 25 $stateSlot $stateBytes; & $sync }
            . $sectionRun $span.J0 $span.J1 $runName
            if($span.J1 -lt $slowSteps){ & $sync; & $dma 25 $stateSlot 18 $stateFrom $stateBytes }
            if($StopAfterSpanStage -eq 'Section256'){ $spanStopped=$true; return }
        }
        if($sections.Count -lt 2){ return }
        if($Source){
            . $bind $sourceSectionOf[1]; $sourceAt=$finalOffset; $sourceBase=25; & $mark 'Boundary' 'Noise128'
            if($span.G1 -gt $span.G0){ & $spanNoise $span.G0 $span.G1; if($StopAfterSpanStage -eq 'Noise128'){ $spanStopped=$true; return } }
            . $sourceSpan $span.G0 $span.G0 $span.H0 $span.H1 $fastSteps; if($span.H1 -gt $span.H0 -and $StopAfterSpanStage -eq 'Source128'){ $spanStopped=$true; return }
        }
        else { $sourceBase=20; $sourceAt=$sourceStreams[1].InputOffset }
        . $bind 1; $chainOffset=$slowMean
        & $mark 'Boundary' 'Front128'
        if($span.S1 -gt $span.S0){ & $spanFront1 $span.S0 $span.S1; if($StopAfterSpanStage -eq 'Front128'){ $spanStopped=$true; return } }
        if($span.K1 -gt $span.K0){
            if($span.K0 -eq 0){ . $sectionInit } else { & $dma 18 $stateFrom 25 $stateSlot $stateBytes; & $sync }
            if($Generic -and $sectionSchedule -eq 'Backward'){ . $backwardRun $span.K0 $span.K1 $runName -Runtime } else { . $sectionRun $span.K0 $span.K1 $runName }
            if($span.K1 -lt $fastSteps){ & $sync; & $dma 25 $stateSlot 18 $stateFrom $stateBytes }
            if($StopAfterSpanStage -eq 'Section128'){ $spanStopped=$true; return }
        }
        if($span.T1 -gt $span.T0){ & $tailRange $span.T0 $span.T1 }
    }
    # A uniform span: every range a constant step from the previous span's, and no stage at an edge of the input (no
    # step with edge treatment, no front or tail range touching either end), so its code differs from its neighbours'
    # only in immediates that advance by a constant per span.
    $rangeNames=@('D0','D1','In0','In1','J0','J1','S0','S1','F0','F1','K0','K1','T0','T1') | Where-Object { $spans[0].PSObject.Properties.Name -contains $_ }
    $spanRejections=[Collections.Generic.List[string]]::new()
    $uniformSpan={param([int]$k)
        $no={param([string]$why) $spanRejections.Add("span ${k}: $why"); $false}
        if($k -lt 1 -or $k+1 -ge $spans.Count){ return (& $no 'first or last') }
        $spanBefore=$spans[$k-1]; $spanHere=$spans[$k]; $spanAfter=$spans[$k+1]
        foreach($n in $rangeNames){ $before=$spanHere.$n-$spanBefore.$n; $after=$spanAfter.$n-$spanHere.$n; if($before -ne $after -or $before -le 0){ return (& $no "$n steps $before then $after") } }
        . $bind 0
        if($spanHere.D0 -lt 1 -or $spanHere.D1 -ge $decTiles -or 10*$spanHere.D1 -ge $tiles){ return (& $no '256-channel front at an edge') }
        for($j=$spanHere.J0;$j -lt $spanHere.J1;$j++){ if(& $edgeStep $j){ return (& $no "256-channel step $j at an edge") } }
        if($Source){
            . $bind $sourceSectionOf[0]
            # A resident source's lockstep runs take their steps as constants, not at run time.
            foreach($i in $sourceSectionOf.Values){ . $bind $i; if($sectionSchedule -eq 'Backward'){ return (& $no 'resident source section') } }
            . $bind $sourceSectionOf[0]
            if($spanHere.C0 -lt 1 -or $spanHere.C1 -ge $tiles){ return (& $no 'noise_convs.0 at an edge') }
            for($j=$spanHere.R0;$j -lt $spanHere.R1;$j++){ if(& $edgeStep $j){ return (& $no "noise_res.0 step $j at an edge") } }
            if($sections.Count -gt 3){
                . $bind $sourceSectionOf[1]
                if($spanHere.G0 -lt 1 -or $spanHere.G1 -ge $tiles){ return (& $no 'noise_convs.1 at an edge') }
                for($j=$spanHere.H0;$j -lt $spanHere.H1;$j++){ if(& $edgeStep $j){ return (& $no "noise_res.1 step $j at an edge") } }
            }
            . $bind 0
        }
        if($sections.Count -gt 1){
            . $bind 1
            if($spanHere.S0 -lt 1 -or $spanHere.S1 -ge $upTiles -or 6*$spanHere.S1 -ge $tiles -or $spanHere.T0 -lt 2 -or $spanHere.T1+2 -gt $tiles -or [math]::Floor(($Frames-2)/32) -lt $spanHere.T1){ return (& $no '128-channel front or tail at an edge') }
            if(($spanHere.K1-$spanHere.K0) % 2 -or ($spanHere.K0 % 2) -ne ($spanBefore.K0 % 2)){ return (& $no 'odd lockstep run') }
            for($j=$spanHere.K0;$j -lt $spanHere.K1;$j++){ if(& $edgeStep $j){ return (& $no "128-channel step $j at an edge") } }
        }
        $true
    }
    # Span-relative code from three consecutive uniform spans' code: identical operations, and each lo/hi immediate
    # pair either equal in all three or advancing by one constant stride, which becomes base + r16 * stride (r16 the
    # span index; r14 the scratch, free between an immediate and its use).
    $spanRelative={param($A,$B,$C,[int]$first)
        if($A.Count -ne $B.Count -or $A.Count -ne $C.Count){throw 'Uniform spans emit different instruction counts.'}
        $out=[Collections.Generic.List[hashtable]]::new()
        for($i=0;$i -lt $A.Count;$i++){
            $x=$A[$i]
            if($x.Op -ceq 'lo' -and $i+1 -lt $A.Count -and $A[$i+1].Op -ceq 'hi' -and $A[$i+1].x -eq $x.x){
                $v=foreach($list in $A,$B,$C){ [long]$list[$i].i -bor ([long]$list[$i+1].i -shl 16) }
                $stride=($v[1]-$v[0]) -band 0xffffffffL
                if($stride -ne (($v[2]-$v[1]) -band 0xffffffffL)){throw "Immediate at step $i does not advance by one stride."}
                if($stride -eq 0){ $out.Add($x); $out.Add($A[$i+1]); $i++; continue }
                if($x.x -in 14,16){throw 'A span-relative immediate cannot use r14 or r16.'}
                $base=($v[0]-$first*$stride) -band 0xffffffffL
                $out.Add(@{Op='lo';x=$x.x;i=($base -band 65535)}); $out.Add(@{Op='hi';x=$x.x;i=($base -shr 16)})
                $out.Add(@{Op='lo';x=14;i=($stride -band 65535)}); $out.Add(@{Op='hi';x=14;i=($stride -shr 16)})
                $out.Add(@{Op='mpyi';d=14;s=14;t=16}); $out.Add(@{Op='add';d=$x.x;s=$x.x;t=14})
                $i++; continue
            }
            foreach($key in @($x.Keys) + @($B[$i].Keys) | Select-Object -Unique){
                if($key -in 'Name','Label'){ continue }
                if("$($x[$key])" -cne "$($B[$i][$key])" -or "$($x[$key])" -cne "$($C[$i][$key])"){throw "Uniform spans differ at step $i ($($x.Op).$key)."}
            }
            $out.Add($x)
        }
        , $out.ToArray()
    }
    $spanBodies=[Collections.Generic.List[object]]::new()
    $spanStopped=$false
    $spanJob={
        # The longest run of uniform spans [u0, u1), looped when it holds at least three spans.
        $u0=-1; $u1=-1
        for($spanAt=0;$spanAt -lt $spans.Count;$spanAt++){ if(& $uniformSpan $spanAt){ if($u0 -lt 0){$u0=$spanAt}; $u1=$spanAt+1 } elseif($u0 -ge 0){ break } }
        if($u1-$u0 -lt 3){ $u0=$spans.Count; $u1=$spans.Count }
        for($spanAt=0;$spanAt -lt $u0;$spanAt++){ . $emitSpan $spans[$spanAt] }
        if($u0 -lt $spans.Count){
            $jobSteps=$s; $callsAt=$calls.Count; $bodiesAt=$lockstepBodies.Count; $spanCode=@()
            # The ledger keeps the first uniform span's transfers, counted once per looped span.
            $dmaRepeat=[long]($u1-$u0); $ledgerAt=$dmaLedger.Count
            foreach($spanAt in $u0,($u0+1),($u0+2)){
                $s=[Collections.Generic.List[hashtable]]::new(); . $emitSpan $spans[$spanAt] -Generic; $spanCode+=,$s
                if($spanAt -eq $u0){ $callsAt=$calls.Count; $bodiesAt=$lockstepBodies.Count; $ledgerAt=$dmaLedger.Count }
            }
            $calls.RemoveRange($callsAt,$calls.Count-$callsAt); $lockstepBodies.RemoveRange($bodiesAt,$lockstepBodies.Count-$bodiesAt)
            $dmaLedger.RemoveRange($ledgerAt,$dmaLedger.Count-$ledgerAt); $dmaRepeat=1L
            $body=[Collections.Generic.List[hashtable]]::new(); $body.Add(@{Op='allocframe';Bytes=16})
            foreach($step in (& $spanRelative $spanCode[0] $spanCode[1] $spanCode[2] $u0)){ $body.Add($step) }
            $body.Add(@{Op='dealloc-return'}); $spanBodies.Add(@('body_span_uniform',$body.ToArray()))
            $s=$jobSteps
            & $imm 16 $u0
            $spansLoop=& $label; $spansDone=& $label
            $s.Add(@{Op='label';Name=$spansLoop}); & $call 'body_span_uniform'; $s.Add(@{Op='addi';d=16;s=16;i=1})
            & $imm 15 $u1; $s.Add(@{Op='eq';d=0;s=16;t=15}); $s.Add(@{Op='jump-p';u=0;Label=$spansDone}); & $jump $spansLoop
            $s.Add(@{Op='label';Name=$spansDone})
        }
        for($spanAt=$u1;$spanAt -lt $spans.Count;$spanAt++){ . $emitSpan $spans[$spanAt] }
        $spanLoop=[pscustomobject]@{First=$u0;End=$u1}
    }
    for($section=0;$section -lt $sections.Count;$section++){
    if($section -gt 0){ $chainOffset=$finalOffset; $chainTiles=$tiles; . $bind $section }
    & $mark 'Boundary' "Front$Channels"
    if($sectionSchedule -ne 'Layer'){
        if($spanMode){ . $spanJob; break }
        . $sectionInit; . $sectionRun 0 ([int][math]::Ceiling(($tiles+3)/$batch)) ''
        continue
    }
    # Blocks: noise_res[1] first with -Front (index -1: its own weights and records, input computed in VTCM, kernel 11
    # bodies of branch 2), then the stage's branches.
    $blocks=[Collections.Generic.List[object]]::new()
    if($front10){ $blocks.Add(@{B=-1;K=7;W=$noiseWeightOffset;P=$noiseParameterOffset;Body=1}) }
    elseif($Front){ $blocks.Add(@{B=-1;K=11;W=$noiseWeightOffset;P=$noiseParameterOffset;Body=2}) }
    for($bb=0;$bb -lt $branches;$bb++){ $blocks.Add(@{B=$bb;K=$sectionKernels[$bb];W=$branchWeights[$bb];P=$pBase+$bb*6L*$recordBytes;Body=$bb}) }
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
    if($Tail){ . $tailSteps }
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
    # ups.0 convolves both weight planes: with one resblock weight plane its combine is the three-group form.
    if($front10 -and $WeightPlanes -eq 1){ $bodies.Add(@("body_combine_front$sfx",@(New-KokoroPlaneCombineSteps -Mode Conv -Channels $Channels -Groups 3 -Group3Shifts -PlaneStride $planeStride -LabelPrefix "combinefront$sfx"))) }
    $bodies.Add(@("body_combine_residual$sfx",@(New-KokoroPlaneCombineSteps -Mode Residual -Channels $Channels @combineGroups -PlaneStride $planeStride -LabelPrefix "combineresidual$sfx")))
    if($sectionSchedule -ne 'Layer'){
        # This section's thread programs (body_lockstep_t<k><suffix>_s<run>).
        if($sectionSchedule -eq 'Backward'){ foreach($pair in $lockstepBodies){ if($pair[0] -cmatch "^body_lockstep_t\d+$([regex]::Escape($sfx))_s"){ $bodies.Add($pair) } } }
        # A computed source's noise_convs convolves both weight planes: its sum is the three-group combine.
        if($sec.Source){ $bodies.Add(@("body_combine_noise$sfx",@(New-KokoroPlaneCombineSteps -Mode Residual -Channels $Channels -Groups 3 -Group3Shifts -PlaneStride $planeStride -LabelPrefix "combinenoise$sfx"))) }
        # A body over three branches: the inner body for branch 0 with the caller's r0 to r5, then for branches 1 and 2
        # with each argument advanced by its branch stride (bytes; 0 keeps it). Arguments live in the frame between calls.
        $branchBodies={param([string]$name,[string]$inner,[long[]]$strides)
            $w=[Collections.Generic.List[hashtable]]::new()
            $w.Add(@{Op='allocframe';Bytes=32}); for($k=0;$k -lt 6;$k++){ $w.Add(@{Op='store';s=29;t=$k;Offset=(4*$k)}) }
            for($b=0;$b -lt $branches;$b++){
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
        # Fill: source ring tile, conv-input tiles (high, low), K/M/S, count, mirror delta; the input ring is shared by the
        # branches (stride 0). Combines: planes, target ring tile, record, count, residual source.
        if($sectionSchedule -eq 'Backward'){ $bodies.Add(@("body_turns_mirror$sfx",@(& $packets @(New-KokoroAdaInSnakeTurnsSteps -TurnsBits 22 -Channels $Channels -LabelPrefix "adainsnaketurnsmirror$sfx" -ControllerContact:$ControllerContact -MirrorDelta (-$ringBytes))))) }
        $bodies.Add(@("body_combine_residual_separate$sfx",@(New-KokoroPlaneCombineSteps -Mode Residual -Channels $Channels @combineGroups -PlaneStride $planeStride -LabelPrefix "combineresidualseparate$sfx" -SeparateResidual)))
        foreach($sharing in @(@('shared',0L),@('branch',$ringBytes))){
            $bodies.Add((& $branchBodies "body_turnsB_$($sharing[0])$sfx" "body_turns$sfx" @($sharing[1],$fillBytes,$fillBytes,(6L*$kmsBytes),0L,0L)))
            if($sectionSchedule -eq 'Backward'){ $bodies.Add((& $branchBodies "body_turnsB_$($sharing[0])_mirror$sfx" "body_turns_mirror$sfx" @($sharing[1],$fillBytes,$fillBytes,(6L*$kmsBytes),0L,0L))) }
            $bodies.Add((& $branchBodies "body_combine_residualB_$($sharing[0])$sfx" "body_combine_residual_separate$sfx" @($planesStride,$ringBytes,(6L*$recordBytes),0L,0L,$sharing[1])))
        }
        $bodies.Add((& $branchBodies "body_combine_convB$sfx" "body_combine_conv$sfx" @($planesStride,$ringBytes,(6L*$recordBytes),0L,0L,0L)))
        for($branch=0;$branch -lt $branches;$branch++){ for($st=0;$st -lt 6;$st++){ $bodies.Add(@("body_convB_b${branch}_s$st$sfx",@(New-KokoroHmxConvPlanesSteps -InputChannels $Channels -OutputChannels $Channels -Kernel $sectionKernels[$branch] -Dilation $(if($st % 2){1}else{1+$st}) @convPlanes -PlaneStride $planeStride -TapDelay (& $tapDelay $branch $st) -LabelPrefix "g16b_b${branch}_s$st$sfx"))) } }
    }
    $bodies.Add(@("body_mean$sfx",@(New-KokoroBranchMean16Steps -Channels $Channels -LabelPrefix "branchmean16$sfx")))
    for($b=0;$b -lt $branches;$b++){foreach($d in 1,3,5){$bodies.Add(@("body_conv_b${b}_d$d$sfx",@(New-KokoroHmxConvPlanesSteps -InputChannels $Channels -OutputChannels $Channels -Kernel $sectionKernels[$b] -Dilation $d @convPlanes -PlaneStride $planeStride -LabelPrefix "g16_b${b}_d$d$sfx")))}}
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
        foreach($pair in (Get-KokoroHarmonicSource16Bodies -PlaneStride $sourceLayout.Stft.PlaneStride -SeededNoise:$SeededNoise -Chunked:($chunkTilesOfSource -gt 0))){ $bodies.Add($pair) }
        $bodies.Add(@('body_har_phase_major',@(New-KokoroHarPhaseMajor16Steps -Phases 6)))
        $bodies.Add(@('body_har_phase_major_tiles',@(New-KokoroHarPhaseMajor16Steps -Phases 6 -TileBatch -LabelPrefix 'harphasemajor16tiles')))
        $bodies.Add(@('body_har_phase_major_last',@(New-KokoroHarPhaseMajor16Steps -Phases 1 -LabelPrefix 'harphasemajor16last')))
    }
    foreach($pair in $spanBodies){ $bodies.Add($pair) }
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
        $s.Add(@{Op='label';Name=$loop})
        $s.Add(@{Op='load';d=0;s=17;Offset=0}); $s.Add(@{Op='eq';d=0;s=0;t=18}); $s.Add(@{Op='jump-p';u=0;Label=$idle})
        $s.Add(@{Op='addi';d=18;s=0;i=0})
        $s.Add(@{Op='load';d=1;s=17;Offset=4}); $s.Add(@{Op='gtu';d=0;s=1;t=19}); $s.Add(@{Op='jump-p';u=0;Label=$quit})
        $s.Add(@{Op='load';d=5;s=16;Offset=48}); $s.Add(@{Op='eq';d=0;s=5;t=19}); $s.Add(@{Op='jump-p';u=0;Label=$done})
        foreach($k in 0..4){ $s.Add(@{Op='load';d=$k;s=16;Offset=(4*$k)}) }
        if($anyChunked){ $s.Add(@{Op='load';d=5;s=16;Offset=56}) }
        $s.Add(@{Op='load';d=20;s=16;Offset=44}); $s.Add(@{Op='callr';s=20})
        $s.Add(@{Op='syncht'})
        $s.Add(@{Op='label';Name=$done})
        $s.Add(@{Op='store';s=16;t=18;Offset=20})
        if($PoolWait -eq 'Futex'){ $s.Add(@{Op='addi';d=0;s=16;i=20}); $s.Add(@{Op='imm';d=1;i=1}); $s.Add(@{Op='trap0';i=0x11}) }
        & $jump $loop
        $s.Add(@{Op='label';Name=$idle})
        if($PoolWait -eq 'Futex'){ & $futexWait 17 18 } else { $s.Add(@{Op='pause';i=$poolPause}) }
        & $jump $loop
        $s.Add(@{Op='label';Name=$quit})
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
    # The layout describes the last main section (computed sources follow it in $sections).
    . $bind (@(for($i=0;$i -lt $sections.Count;$i++){ if(-not $sections[$i].Source){ $i } })[-1])
    $resultLayout=[ordered]@{Frames=$Frames;Tiles=$tiles;InputBytes=$totalInput;WeightBytes=$totalWeights;ParameterBytes=$totalParameters;OutputBytes=$totalOutput;VtcmBytes=$vtcmTotal;Samples=$(if($Tail){5*($Frames-1)}else{1});PcmOffset=$(if($Tail){$pcmOffset}else{256});BranchStride=$stride;FinalWorkspaceOffset=$finalOffset;CoefficientOffset=$coefOffset;ScratchOffset=$scratchOffset;CompletedStages=$(6*$branches+[int]$withMean);BatchTiles=$batch;HvxThreads=$HvxThreads;Regions=$layout.Regions}
    $resultLayout.AdaInMode=$AdaInMode
    $resultLayout.WeightRegions=$weightRegions.ToArray()
    $resultLayout.SourceStreams=@($sourceStreams | Where-Object { $null -ne $_ })
    $resultLayout.Spans=$spans
    $resultLayout.SpanLoop=$spanLoop; $resultLayout.SpanRejections=$spanRejections.ToArray()
$resultLayout.DmaLedger=@($dmaLedger | Group-Object Section,Span,Class | ForEach-Object { $first=$_.Group[0]; [pscustomobject]@{Section=$first.Section;Span=$first.Span;Class=$first.Class;Transfers=[long]($_.Group | Measure-Object Count -Sum).Sum;Bytes=[long]($_.Group | Measure-Object Bytes -Sum).Sum} })
    # Each section's tensors in the workspace: its input after the front (fronted sections) and its output.
    $resultLayout.Sections=@(for($i=0;$i -lt $sections.Count;$i++){ . $bind $i
        [pscustomobject]@{Section=$i;Channels=$Channels;Tiles=$tiles;Bytes=$tensorBytes;InputWorkspaceOffset=$(if($Front){$r0Slot}else{-1L});FinalWorkspaceOffset=$finalOffset;SourceOf=$(if($sec.Source){[int]$sec.Of}else{-1});Schedule=$sectionSchedule;StateBytes=$(if($spanMode -and $sectionSchedule -ne 'Layer'){[long]$stateBytes}else{0L})} })
    # The har tensors in the workspace: the 60x planes and the 10x front's phase-major planes.
    if($Source){ $resultLayout.Har=[pscustomobject]@{SixtyOffset=$har60At;SixtyBytes=2L*$tiles60*4096;PhaseMajorOffset=$harPmAt;PhaseMajorBytes=2L*$tiles10*16384} }
    if($Source){ $resultLayout.SourceNoise=[pscustomobject]@{InputOffset=$sourceIn+$sourceLayout.F0Bytes;Bytes=$sourceLayout.HalfwordBytes;Seeded=$SeededNoise.IsPresent} }
    if($ControllerContact){ $resultLayout.ControllerContact=[pscustomobject]@{Offset=$contactOffset;SensitivityBytesPerStage=8L*$Channels;ControllerOffset=$contactOffset+18L*8*$Channels;ControllerBytes=$controllerBytes;Tiles=$tiles} }
    if($PmuEvents){$resultLayout.PmuProfile=[pscustomobject]@{Categories=$pmuCategories;SiteRecordOffset=$pmuSiteOffset;SiteRecordCount=$pmuSiteRecordCount;Sites=$pmuSites}}
    $resultLayout.ConstantPacking=[pscustomobject]@{Frames=$Frames;ParameterBytes=$constantsTableOffset;ConstantsTableOffset=$constantsTableOffset;
        ConstantsBytes=$momentAt;ConstantsParameterBytes=$constantsTableOffset+$momentAt;OutputBytes=$exportOffset;
        MomentSites=$momentSites.ToArray();MomentsBytes=$momentAt;KmBytes=$kmsAt;HostCoefficientsOffset=$(if($HostCoefficients){$hostCoefficientsOffset}else{-1L})}
    [pscustomobject]@{Steps=$s.ToArray();Layout=$resultLayout}
}
