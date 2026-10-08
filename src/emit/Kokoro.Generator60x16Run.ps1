#requires -Version 7.4
# Stock generator resblocks.3/4/5 and their three-way mean at 16 bits, activations resident in VTCM.
# Source: hexgrad/kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec, istftnet.py AdaINResBlock1.forward and
# Generator.forward. Numeric design: docs/generator60x-16bit-design.md; pass order as the 8-bit resident
# stage (docs/generator60x-resident-design.md, Kokoro.Generator60xResidentRun.ps1).
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
    # HMX activation reads must not straddle a 4 MiB VTCM page: both windows come first.
    $list=@(@('Window',(($BatchTiles+2)*$tileBytes)),@('WindowLow',(($BatchTiles+2)*$tileBytes)),@('Planes',(6L*$BatchTiles*$tileBytes)),@('Weights',(2L*$Channels*$Channels*11)),@('Small',$smallBytes),@('Residual',$bytes),@('ConvOutput',$bytes))
    foreach($r in $list){ $regions[$r[0]]=[ordered]@{Offset=$at;Bytes=[long]$r[1]}; $at+=& $al $r[1] }
    $page=4194304
    foreach($name in 'Window','WindowLow'){ $w=$regions[$name]; if([math]::Floor($w.Offset/$page) -ne [math]::Floor(($w.Offset+$w.Bytes-1)/$page)){throw 'Conv-input window crosses a 4 MiB VTCM boundary'} }
    [pscustomobject]@{Frames=$Frames;Tiles=$tiles;TensorBytes=$bytes;BatchTiles=$BatchTiles;Regions=$regions;Small=$small;VtcmBytes=$at;PlaneStride=([long]$BatchTiles*$tileBytes);Channels=$Channels;TileBytes=$tileBytes;RecordBytes=$record}
}

function New-KokoroGenerator60x16RunSteps {
    param([ValidateRange(2,32768)][int]$Frames=7801,[ValidateRange(1,64)][int]$BatchTiles=22,[ValidateRange(1,4)][int]$HvxThreads=4,
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
        [switch]$GenericHarness)
    $branches=$Kernels.Count; $withMean=$branches -eq 3
    if($Channels -ne 128 -and ($Front -or $Tail)){throw '-Front and -Tail are 128-channel'}
    if($branches -eq 2){throw 'Two blocks have no stock combination here.'}
    if(-not $withMean -and $Tail){throw '-Tail follows the three-block stage'}
    . (Join-Path $PSScriptRoot 'Kokoro.ResBlockRun.ps1')
    foreach($file in 'Kokoro.GeneratorFront16.ps1','Kokoro.GeneratorTail16Run.ps1','Kokoro.LeakyRelu16.ps1','Kokoro.TailSpectrum16.ps1','Kokoro.HmxConvPlanes.ps1','Kokoro.PlaneCombine.ps1','Kokoro.AdaInMoments16.ps1','Kokoro.AdaInTurnsCoefficients.ps1','Kokoro.AdaInSnakeTurns.ps1','Kokoro.BranchMean16.ps1','Kokoro.DmaCopy.ps1') { . (Join-Path $PSScriptRoot $file) }
    $layout=Get-KokoroGenerator60x16Layout -Frames $Frames -BatchTiles $BatchTiles -Channels $Channels
    $tileBytes=$layout.TileBytes; $recordBytes=$layout.RecordBytes; $blocksPerTile=$Channels/32; $kmsBytes=12*$Channels; $momentVectors=$Channels/8
    $tablesAt=32*$Channels; $ratiosAt=80*$Channels
    $tiles=$layout.Tiles; $tensorBytes=$layout.TensorBytes; $batch=$BatchTiles; $R=$layout.Regions; $planeStride=$layout.PlaneStride
    $offResidual=$R.Residual.Offset; $offConv=$R.ConvOutput.Offset; $offWin=$R.Window.Offset; $offLow=$R.WindowLow.Offset; $offPlanes=$R.Planes.Offset; $offWeights=$R.Weights.Offset
    $offSmall=$R.Small.Offset; $offParams=$offSmall+$layout.Small.Parameters; $offMoments=$offSmall+$layout.Small.Moments; $offInputMoments=$offSmall+$layout.Small.InputMoments; $offKms=$offSmall+$layout.Small.Kms
    $privateMoments=@(0,0,1,2) | ForEach-Object { $offSmall+$layout.Small.PrivateMoments+16*$Channels*$_ }
    $branchWeights=[long[]]::new($branches); $weightBytes=0L
    for($b=0;$b -lt $branches;$b++){ $branchWeights[$b]=$weightBytes; $weightBytes+=6L*2*$Channels*$Channels*$Kernels[$b] }
    $parameterBytes=6*$branches*$recordBytes
    $stride=[int]([math]::Ceiling($tensorBytes/128)*128); $finalOffset=2*$stride; $coefOffset=$finalOffset+$tensorBytes
    $scratchOffset=[long]([math]::Ceiling(($coefOffset+18*$kmsBytes)/4096)*4096); $outputBytes=192+$scratchOffset+131072
    $vtcmBytes=$layout.VtcmBytes; $stageWeightBytes=$weightBytes; $stageParameterBytes=$parameterBytes; $inputBytes=$tensorBytes
    $r0Base=20; $r0Offset=0L
    if($Front){
        if(-not $withMean -or $StopAfterStage -ge 0){throw '-Front feeds the whole three-block stage'}
        if($batch % 2){throw '-Front needs an even batch (ups[1] batches are half as many 256-channel tiles)'}
        $upFrames=[int](($Frames-1)/6)+1; if(6*($upFrames-1)+1 -ne $Frames){throw 'Frames is not 6 m + 1'}
        $upTiles=[int][math]::Ceiling($upFrames/32); $upBatch=$batch/2
        $inputBytes=2L*$tiles*4096+2L*$upTiles*16384
        $al64={param([long]$v) [long]([math]::Ceiling($v/65536)*65536)}
        $offFrontWeights=& $al64 $layout.VtcmBytes; $offFrontTables=$offFrontWeights+393216; $offUpPhase=$offFrontTables+65536
        $vtcmBytes=[math]::Max($vtcmBytes,(& $al64 ($offUpPhase+$upTiles*16384L)))
        if($R.Residual.Offset+2L*($upTiles+2)*16384 -gt 4194304){throw 'ups[1] input planes cross a 4 MiB VTCM boundary'}
        if(($tiles+4)*8192L -gt (& $al64 $tensorBytes)){throw 'The interleave needs four tiles of slack after the stage input'}
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
    if($Front){ $noiseWeightOffset=$weightBytes; $weightBytes+=6L*32768*11; $frontWeightOffset=$weightBytes; $weightBytes+=1228800
        $noiseParameterOffset=$parameterBytes; $parameterBytes+=6*16384; $frontParameterOffset=$parameterBytes; $parameterBytes+=65536 }

    $s=[Collections.Generic.List[hashtable]]::new()
    $calls=[Collections.Generic.List[object]]::new()
    $imm={param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL);$s.Add(@{Op='lo';x=$r;i=($u -band 65535)});$s.Add(@{Op='hi';x=$r;i=($u -shr 16)})}
    $ptr={param([int]$r,[int]$baseReg,[long]$offset) $offsetReg=if($r -eq $baseReg){15}else{$r}; & $imm $offsetReg $offset;$s.Add(@{Op='add';d=$r;s=$baseReg;t=$offsetReg}) }
    $call={param([string]$label) $pc=@{Op='add-pc';d=14;i=0};$lo=@{Op='lo';x=15;i=0};$hi=@{Op='hi';x=15;i=0};$s.Add($pc);$s.Add($lo);$s.Add($hi);$s.Add(@{Op='add';d=14;s=14;t=15});$s.Add(@{Op='callr';s=14});$calls.Add(@{pc=$pc;low=$lo;high=$hi;label=$label})}
    $addr={param([int]$r,[string]$target) $pc=@{Op='add-pc';d=$r;i=0};$lo=@{Op='lo';x=15;i=0};$hi=@{Op='hi';x=15;i=0};$s.Add($pc);$s.Add($lo);$s.Add($hi);$s.Add(@{Op='add';d=$r;s=$r;t=15});$calls.Add(@{pc=$pc;low=$lo;high=$hi;label=$target})}
    $label={ $script:__u16++; "g16_$($script:__u16)" }
    $script:__u16=0
    $jump={param([string]$target) $s.Add(@{Op='eq';d=0;s=0;t=0}); $s.Add(@{Op='jump-p';u=0;Label=$target}) }

    # Performance counters (as Kokoro.Generator60xResidentRun.ps1; record at r25 + scratch).
    $pmuCategories=@('Setup','Dma','Coefficients','AdaInSnake','HmxConv','Combine','Moments','Mean','Sync','TileFix')
    $pmuOffset=$scratchOffset
    $mark={param([string]$category)
        if(-not $PmuEvents){return}
        $c=[array]::IndexOf($pmuCategories,$category); if($c -lt 0){throw "Unknown PMU category $category"}
        & $ptr 0 25 ($pmuOffset+256+64*$c); & $call 'body_pmu_mark'
    }

    # HVX worker pool (as Kokoro.Generator60xResidentRun.ps1): block at r25 + scratch + 4096, stacks at
    # + 65536 - 4096 + 16384*k. Futex, HVX lock and unlock are the libqurt.a trap stubs (SDK 6.4.0.2
    # computev73 pic/libqurt.a 8e0ba5fd...); thread create/join/exit are imports.
    $poolOffset=$scratchOffset+4096; $stackOffset=$scratchOffset+65536
    $futexWait={param([int]$addrReg,[int]$valueReg) $s.Add(@{Op='addi';d=1;s=$valueReg;i=0}); $s.Add(@{Op='addi';d=0;s=$addrReg;i=0}); $s.Add(@{Op='imm';d=3;i=0}); $s.Add(@{Op='imm';d=4;i=-1}); $s.Add(@{Op='imm';d=5;i=-1}); $s.Add(@{Op='trap0';i=0x20}) }
    # Tile-parallel call: arguments are VTCM offsets (r18-relative); perTile ones advance 8192 bytes per tile.
    # With -Moments the second argument is the job's moments record: each worker accumulates into its own
    # zeroed 2048-byte record, added into the job's after the join (wrapping int32 sums, order-free).
    $parallel={param([string]$body,[long[]]$off,[bool[]]$perTile,[int]$count,[switch]$Moments)
        $n=$off.Count
        if($HvxThreads -eq 1 -or $count -lt 2){ for($i=0;$i -lt $n;$i++){ & $ptr $i 18 $off[$i] }; & $imm $n $count; & $call $body; return }
        $chunk=[int][math]::Ceiling($count/$HvxThreads)
        for($k=1;$k -lt $HvxThreads;$k++){
            $o=$k*$chunk; $c=[math]::Max(0,[math]::Min($chunk,$count-$o))
            if($c -gt 0 -and $Moments){ & $ptr 4 18 $privateMoments[$k]; $s.Add(@{Op='vxor';d=0;s=0;t=0}); for($v=0;$v -lt $momentVectors;$v++){$s.Add(@{Op='vstore';s=4;t=0;Offset=(128*($v%8))}); if($v%8 -eq 7 -and $v -lt $momentVectors-1){$s.Add(@{Op='addi';d=4;s=4;i=1024})}} }
            & $ptr 6 25 ($poolOffset+64*$k)
            if($c -gt 0){
                for($i=0;$i -lt $n;$i++){
                    $value=if($Moments -and $i -eq 1){$privateMoments[$k]}elseif($perTile[$i]){$off[$i]+$o*$tileBytes}else{$off[$i]}
                    & $ptr 0 18 $value; $s.Add(@{Op='store';s=6;t=0;Offset=(4*$i)})
                }
                & $imm 0 $c; $s.Add(@{Op='store';s=6;t=0;Offset=(4*$n)})
                & $addr 0 $body; $s.Add(@{Op='store';s=6;t=0;Offset=44})
            }
            & $imm 0 $c; $s.Add(@{Op='store';s=6;t=0;Offset=48})
        }
        $s.Add(@{Op='syncht'})
        & $ptr 6 25 $poolOffset; $s.Add(@{Op='load';d=0;s=6;Offset=0}); $s.Add(@{Op='addi';d=0;s=0;i=1}); $s.Add(@{Op='store';s=6;t=0;Offset=0})
        $s.Add(@{Op='addi';d=0;s=6;i=0}); & $imm 1 ($HvxThreads-1); $s.Add(@{Op='trap0';i=0x11})
        for($i=0;$i -lt $n;$i++){ & $ptr $i 18 $off[$i] }; & $imm $n ([math]::Min($chunk,$count)); & $call $body
        for($k=1;$k -lt $HvxThreads;$k++){
            $wait=& $label; $done=& $label
            $s.Add(@{Op='label';Name=$wait})
            & $ptr 6 25 ($poolOffset+64*$k); & $ptr 7 25 $poolOffset; $s.Add(@{Op='load';d=8;s=6;Offset=20}); $s.Add(@{Op='load';d=9;s=7;Offset=0})
            $s.Add(@{Op='eq';d=0;s=8;t=9}); $s.Add(@{Op='jump-p';u=0;Label=$done})
            $s.Add(@{Op='addi';d=6;s=6;i=20}); & $futexWait 6 8; & $jump $wait
            $s.Add(@{Op='label';Name=$done})
        }
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

    # DMA dest <- src, length bytes; r24 holds two 64-byte aligned descriptor slots in DDR.
    $dma={param([int]$destBase,[long]$destOff,[int]$srcBase,[long]$srcOff,[long]$length)
        if($length -lt 2 -or $length -ge 2*16777215){throw 'DMA length out of range'}
        & $ptr 1 $srcBase $srcOff; & $ptr 2 $destBase $destOff; & $imm 3 $length; $s.Add(@{Op='addi';d=0;s=24;i=0})
        foreach($step in @(New-KokoroDmaCopySteps -NoReturn)){$s.Add($step)}
        & $mark 'Dma'
    }
    $sync={ $s.Add(@{Op='syncht'}); & $mark 'Sync' }
    # VTCM tiles <- one 32-bit pattern (0x80008000: x = 0 or the high-window zero; 0: the low-window zero).
    $fill={param([long]$off,[int]$count,[long]$pattern)
        & $ptr 4 18 $off; & $imm 6 $pattern; $s.Add(@{Op='vsplat';d=0;s=6}); & $imm 5 ($count*$tileBytes/128); $s.Add(@{Op='imm';d=7;i=0})
        $n=& $label; $s.Add(@{Op='label';Name=$n});$s.Add(@{Op='vstore';s=4;t=0;Offset=0});$s.Add(@{Op='addi';d=4;s=4;i=128});$s.Add(@{Op='addi';d=5;s=5;i=-1});$s.Add(@{Op='gtu';d=0;s=5;t=7});$s.Add(@{Op='jump-p';u=0;Label=$n})
        & $mark 'TileFix'
    }
    $zeroRecord={param([long]$off) & $ptr 4 18 $off; $s.Add(@{Op='vxor';d=0;s=0;t=0}); for($k=0;$k -lt $momentVectors;$k++){$s.Add(@{Op='vstore';s=4;t=0;Offset=(128*($k%8))}); if($k%8 -eq 7 -and $k -lt $momentVectors-1){$s.Add(@{Op='addi';d=4;s=4;i=1024})}} }
    $copyRecord={param([long]$destOff,[long]$srcOff) for($half=0;$half -lt $momentVectors/8;$half++){ & $ptr 4 18 ($srcOff+1024*$half); & $ptr 5 18 ($destOff+1024*$half); for($k=0;$k -lt 8;$k++){$s.Add(@{Op='vload';d=$k;s=4;Offset=(128*$k)})}; for($k=0;$k -lt 8;$k++){$s.Add(@{Op='vstore';s=5;t=$k;Offset=(128*$k)})} } }
    # Rows >= Frames of the tile at tileOff: every halfword of those rows <- value (0x8000 or 0).
    $padRows={param([long]$tileOff,[long]$value)
        if($Frames%32 -eq 0){return}
        for($t=$Frames%32;$t -lt 32;$t++){
            for($block=0;$block -lt $blocksPerTile;$block++){
                $lane=$tileOff+$block*2048+[int][math]::Floor($t/2)*128
                & $ptr 4 18 $lane; & $imm 6 $(if($t%2){0x0000ffffL}else{0xffff0000L}); & $imm 8 $(if($t%2){$value -shl 16}else{$value})
                $s.Add(@{Op='imm';d=5;i=32});$s.Add(@{Op='imm';d=7;i=0});$n=& $label
                $s.Add(@{Op='label';Name=$n});$s.Add(@{Op='load';d=0;s=4;Offset=0});$s.Add(@{Op='and';d=0;s=0;t=6});$s.Add(@{Op='or';d=0;s=0;t=8});$s.Add(@{Op='store';s=4;t=0;Offset=0});$s.Add(@{Op='addi';d=4;s=4;i=4});$s.Add(@{Op='addi';d=5;s=5;i=-1});$s.Add(@{Op='gtu';d=0;s=5;t=7});$s.Add(@{Op='jump-p';u=0;Label=$n})
            }
        }
        & $mark 'TileFix'
    }
    $moments={param([long]$srcOff,[int]$count) & $parallel 'body_moments' @($srcOff,$offMoments) @($true,$false) $count -Moments; & $mark 'Moments' }

    # Checked resource wrapper of the frozen K=11 resblock runner (as the resident stage), with admission
    # sizes and the VTCM request changed.
    $wrapperSource=New-KokoroResBlockRunSteps -Frames $Frames -Kernel 11
    $base=@($wrapperSource.Steps);$start=-1
    for($i=0;$i -lt $base.Count;$i++){if($base[$i].Op -eq 'label' -and $base[$i].Name -eq 'connected_job'){$start=$i;break}}
    if($start -lt 0){throw 'Connected wrapper anchor changed'}
    $minimum=@(4,$inputBytes,$weightBytes,$parameterBytes,$outputBytes)
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
        & $ptr 4 25 $pmuOffset; $s.Add(@{Op='vxor';d=0;s=0;t=0}); for($k=0;$k -lt 8;$k++){$s.Add(@{Op='vstore';s=4;t=0;Offset=(128*$k)})}
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
        & $fill $offResidual $tiles 0x80008000L
        & $dma 18 $offFrontWeights 21 $frontWeightOffset 49152
        & $dma 18 $offFrontTables 22 $frontParameterOffset 65536
        for($start=0;$start -lt $tiles;$start+=$batch){
            $count=[math]::Min($batch,$tiles-$start); $first=[math]::Max(0,$start-1); $last=[math]::Min($tiles,$start+$count+1)
            if($start -eq 0){ & $fillVectors $offWin 32 0x80008000L; & $fillVectors $offLow 32 0 }
            if($start+$count -eq $tiles){ & $fillVectors ($offWin+($count+1)*4096) 32 0x80008000L; & $fillVectors ($offLow+($count+1)*4096) 32 0 }
            & $dma 18 ($offWin+($first-$start+1)*4096) 20 ($first*4096L) (($last-$first)*4096L)
            & $dma 18 ($offLow+($first-$start+1)*4096) 20 ($tiles*4096L+$first*4096L) (($last-$first)*4096L)
            & $ptr 0 18 ($offWin+4096); & $ptr 1 18 ($offLow+4096); & $ptr 2 18 $offFrontWeights; & $ptr 3 18 $offFrontTables; & $imm 4 $count; & $ptr 5 18 $offPlanes
            & $call 'body_conv_front_noise'; & $mark 'HmxConv'; & $sync
            & $parallel 'body_combine_residual' @($offPlanes,($offResidual+$start*8192),($offFrontTables+8192)) @($true,$true,$false) $count
            & $mark 'Combine'
        }
        & $padRows ($offResidual+($tiles-1)*8192) 0x8000
    }
    $frontUps={
        & $sync; & $dma 25 $noiseSlot 18 $offResidual $tensorBytes
        $upHi=$offResidual; $upLo=$offResidual+($upTiles+2)*16384L; $harBytes=2L*$tiles*4096
        & $fillVectors $upHi 128 0x80008000L; & $fillVectors ($upHi+($upTiles+1)*16384L) 128 0x80008000L
        & $fillVectors $upLo 128 0; & $fillVectors ($upLo+($upTiles+1)*16384L) 128 0
        & $dma 18 ($upHi+16384) 20 $harBytes ($upTiles*16384L); & $dma 18 ($upLo+16384) 20 ($harBytes+$upTiles*16384L) ($upTiles*16384L)
        for($c=0;$c -lt 3;$c++){
            & $dma 18 $offFrontWeights 21 ($frontWeightOffset+49152+$c*393216L) 393216
            for($start=0;$start -lt $upTiles;$start+=$upBatch){
                $count=[math]::Min($upBatch,$upTiles-$start)
                & $ptr 0 18 ($upHi+($start+1)*16384L); & $ptr 1 18 ($upLo+($start+1)*16384L); & $ptr 2 18 $offFrontWeights; & $ptr 3 18 ($offFrontTables+16384+12288*$c); & $imm 4 $count; & $ptr 5 18 $offPlanes
                & $call 'body_conv_front_up'; & $mark 'HmxConv'; & $sync
                & $ptr 0 18 $offPlanes; & $ptr 1 18 ($offUpPhase+$start*16384L); & $ptr 2 18 ($offFrontTables+53248+2048*$c-1024); & $imm 3 $count
                & $call 'body_combine_conv256'; & $mark 'Combine'; & $sync
            }
            & $ptr 0 18 $offUpPhase; & $ptr 1 18 $offConv; & $imm 2 $c; & $imm 3 ([math]::Ceiling($upFrames/2))
            & $call 'body_front_interleave'; & $mark 'Combine'; & $sync
        }
        # Reflection: padded frame 0 is padded frame 2 (even halfwords of row pairs 0 and 1 of tile 0).
        & $imm 6 0xFFFF0000L; $s.Add(@{Op='vsplat';d=30;s=6}); & $imm 6 0x0000FFFFL; $s.Add(@{Op='vsplat';d=31;s=6})
        for($blk=0;$blk -lt 4;$blk++){
            & $ptr 4 18 ($offConv+2048*$blk); $s.Add(@{Op='vload';d=0;s=4;Offset=0}); $s.Add(@{Op='vload';d=1;s=4;Offset=128})
            $s.Add(@{Op='vand';d=0;s=0;t=30}); $s.Add(@{Op='vand';d=1;s=1;t=31}); $s.Add(@{Op='vor';d=0;s=0;t=1}); $s.Add(@{Op='vstore';s=4;t=0;Offset=0})
        }
        & $sync; & $dma 18 $offResidual 25 $noiseSlot $tensorBytes
        & $ptr 0 18 $offConv; & $ptr 1 18 $offResidual; & $ptr 2 18 ($offFrontTables+59392); & $imm 3 $tiles
        & $call 'body_front_add'; & $mark 'Combine'
        & $padRows ($offResidual+($tiles-1)*8192) 0x8000
        & $sync; & $dma 25 $r0Slot 18 $offResidual $tensorBytes
    }
    & $poolStart
    $stopped=$false
    # Blocks: noise_res[1] first with -Front (index -1: its own weights and records, input computed in VTCM, kernel 11
    # bodies of branch 2), then the stage's branches.
    $blocks=[Collections.Generic.List[object]]::new()
    if($Front){ $blocks.Add(@{B=-1;K=11;W=$noiseWeightOffset;P=$noiseParameterOffset;Body=2}) }
    for($bb=0;$bb -lt $branches;$bb++){ $blocks.Add(@{B=$bb;K=$Kernels[$bb];W=$branchWeights[$bb];P=$bb*6L*$recordBytes;Body=$bb}) }
    foreach($blk in $blocks){
        if($stopped){break}
        $b=$blk.B; $K=$blk.K
        if($b -lt 0){ & $frontNoise } else { & $dma 18 $offResidual $r0Base $r0Offset $tensorBytes }
        if($b -le 0){ & $zeroRecord $offMoments; & $moments $offResidual $tiles; if($b -eq 0){ & $copyRecord $offInputMoments $offMoments } }
        else { & $copyRecord $offMoments $offInputMoments }
        for($p=0;$p -lt 3 -and -not $stopped;$p++){
            $dilation=@(1,3,5)[$p]
            foreach($half in 0,1){
                if($stopped){continue}
                $st=2*$p+$half
                & $dma 18 $offParams 22 ($blk.P+$st*$recordBytes) $recordBytes
                & $dma 18 $offWeights 21 ($blk.W+$st*2L*$Channels*$Channels*$K) (2L*$Channels*$Channels*$K)
                & $ptr 0 18 $offMoments; & $ptr 1 18 $offParams; & $ptr 2 18 $offKms; & $imm 3 $Frames; & $call 'body_coeff'; & $mark 'Coefficients'
                if($b -ge 0){ & $dma 25 ($coefOffset+($b*6+$st)*$kmsBytes) 18 $offKms $kmsBytes }
                & $zeroRecord $offMoments
                $source=if($half -eq 0){$offResidual}else{$offConv}
                $convLabel="body_conv_b$($blk.Body)_d$(if($half -eq 0){$dilation}else{1})"
                for($start=0;$start -lt $tiles;$start+=$batch){
                    $count=[math]::Min($batch,$tiles-$start)
                    $first=[math]::Max(0,$start-1);$last=[math]::Min($tiles,$start+$count+1)
                    if($start -eq 0){ & $fill $offWin 1 0x80008000L; & $fill $offLow 1 0 }
                    if($start+$count -eq $tiles){ & $fill ($offWin+($count+1)*$tileBytes) 1 0x80008000L; & $fill ($offLow+($count+1)*$tileBytes) 1 0 }
                    & $parallel 'body_turns' @(($source+$first*$tileBytes),($offWin+($first-$start+1)*$tileBytes),($offLow+($first-$start+1)*$tileBytes),$offKms) @($true,$true,$true,$false) ($last-$first)
                    & $mark 'AdaInSnake'
                    if($last -eq $tiles){ & $padRows ($offWin+($tiles-$start)*$tileBytes) 0x8000; & $padRows ($offLow+($tiles-$start)*$tileBytes) 0 }
                    & $sync
                    if($b -ge 0 -and $b*6+$st -eq $StopAfterStage -and $start -eq 0 -and $DumpPoint -eq 'Windows'){ & $dma 25 $finalOffset 18 $offWin (($batch+2)*[long]$tileBytes); & $dma 25 ($finalOffset+($batch+2)*[long]$tileBytes) 18 $offLow (($batch+2)*[long]$tileBytes); $stopped=$true; break }
                    & $ptr 0 18 ($offWin+$tileBytes); & $ptr 1 18 ($offLow+$tileBytes); & $ptr 2 18 $offWeights; & $ptr 3 18 ($offParams+$tablesAt); & $imm 4 $count; & $ptr 5 18 $offPlanes
                    & $call $convLabel; & $mark 'HmxConv'
                    & $sync
                    if($b -ge 0 -and $b*6+$st -eq $StopAfterStage -and $start -eq 0 -and $DumpPoint -eq 'Planes'){ & $dma 25 $finalOffset 18 $offPlanes (6L*$planeStride); $stopped=$true; break }
                    $hasLast=($start+$count -eq $tiles)
                    if($half -eq 0){
                        & $parallel 'body_combine_conv' @($offPlanes,($offConv+$start*$tileBytes),($offParams+$ratiosAt)) @($true,$true,$false) $count
                        & $mark 'Combine'
                        if($hasLast){ & $padRows ($offConv+($tiles-1)*$tileBytes) 0x8000 }
                        & $moments ($offConv+$start*$tileBytes) $count
                    } else {
                        & $parallel 'body_combine_residual' @($offPlanes,($offResidual+$start*$tileBytes),($offParams+$ratiosAt)) @($true,$true,$false) $count
                        & $mark 'Combine'
                        if($hasLast){ & $padRows ($offResidual+($tiles-1)*$tileBytes) 0x8000 }
                        if($p -lt 2){ & $moments ($offResidual+$start*$tileBytes) $count }
                    }
                }
                if($b -ge 0 -and $b*6+$st -eq $StopAfterStage -and -not $stopped){
                    & $sync; & $dma 25 $finalOffset 18 $(if($half -eq 0){$offConv}else{$offResidual}) $tensorBytes; $stopped=$true
                }
            }
        }
        if($b -lt 0 -and -not $stopped){ & $frontUps }
        elseif($b -lt $branches-1 -and -not $stopped){ & $sync; & $dma 25 ($b*$stride) 18 $offResidual $tensorBytes }
    }
    # One block: its output is the final tensor.
    if(-not $stopped -and -not $withMean){ & $sync; & $dma 25 $finalOffset 18 $offResidual $tensorBytes }
    # Three-branch mean in two chunks: branches 0 and 1 come back from DDR into the free C region.
    if(-not $stopped -and $withMean){
    & $sync
    $chunk=[int][math]::Ceiling($tiles/2)
    for($j=0;$j*$chunk -lt $tiles;$j++){
        $chunkTiles=[math]::Min($chunk,$tiles-$j*$chunk)
        & $dma 18 $offConv 25 ($j*$chunk*$tileBytes) ($chunkTiles*$tileBytes)
        & $dma 18 ($offConv+$chunk*$tileBytes) 25 ($stride+$j*$chunk*$tileBytes) ($chunkTiles*$tileBytes)
        & $parallel 'body_mean' @($offConv,($offConv+$chunk*$tileBytes),($offResidual+$j*$chunk*$tileBytes),$offConv) @($true,$true,$true,$true) $chunkTiles
        & $mark 'Mean'; & $sync
        & $dma 25 ($finalOffset+$j*$chunk*$tileBytes) 18 $offConv ($chunkTiles*$tileBytes)
    }
    }
    if($Tail){
        & $sync
        Add-KokoroGeneratorTail16JobSteps -Steps $s -Calls $calls -Frames $Frames -InputBase 25 -InputOffset $finalOffset -WeightsBase 21 -WeightsOffset $tailWeightOffset -TablesBase 22 -TablesOffset $tailParameterOffset -PcmBase 23 -PcmOffset $pcmOffset
    }
    & $poolStop
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
    $bodies.Add(@('body_turns',@(New-KokoroAdaInSnakeTurnsSteps -TurnsBits 22 -Channels $Channels)))
    $bodies.Add(@('body_moments',@(New-KokoroAdaInMoments16Steps -Channels $Channels)))
    $bodies.Add(@('body_coeff',@(New-KokoroAdaInTurnsCoefficientsSteps -Channels $Channels)))
    $bodies.Add(@('body_combine_conv',@(New-KokoroPlaneCombineSteps -Mode Conv -Channels $Channels -Groups 3 -Group3Shifts -PlaneStride $planeStride -LabelPrefix 'combineconv')))
    $bodies.Add(@('body_combine_residual',@(New-KokoroPlaneCombineSteps -Mode Residual -Channels $Channels -Groups 3 -Group3Shifts -PlaneStride $planeStride -LabelPrefix 'combineresidual')))
    $bodies.Add(@('body_mean',@(New-KokoroBranchMean16Steps -Channels $Channels)))
    for($b=0;$b -lt $branches;$b++){foreach($d in 1,3,5){$bodies.Add(@("body_conv_b${b}_d$d",@(New-KokoroHmxConvPlanesSteps -InputChannels $Channels -OutputChannels $Channels -Kernel $Kernels[$b] -Dilation $d -WeightPlanes 2 -PlaneStride $planeStride -LabelPrefix "g16_b${b}_d$d")))}}
    if($Front){
        $bodies.Add(@('body_conv_front_noise',@(New-KokoroHmxConvPlanesSteps -InputChannels 64 -OutputChannels 128 -Kernel 3 -Dilation 1 -WeightPlanes 2 -PlaneStride $planeStride -LabelPrefix 'g16fn')))
        $bodies.Add(@('body_conv_front_up',@(New-KokoroHmxConvPlanesSteps -InputChannels 256 -OutputChannels 256 -Kernel 3 -Dilation 1 -WeightPlanes 2 -PlaneStride $planeStride -LabelPrefix 'g16fu')))
        $bodies.Add(@('body_combine_conv256',@(New-KokoroPlaneCombineSteps -Mode Conv -Channels 256 -Groups 3 -Group3Shifts -PlaneStride $planeStride -LabelPrefix 'combine256')))
        $bodies.Add(@('body_front_interleave',@(New-KokoroFrontInterleaveSteps)))
        $bodies.Add(@('body_front_add',@(New-KokoroFrontAddSteps)))
    }
    if($Tail){ foreach($pair in (Get-KokoroGeneratorTail16Bodies -PlaneStride $tailLayout.PlaneStride)){ $bodies.Add($pair) } }
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
        $s.Add(@{Op='load';d=20;s=16;Offset=44}); $s.Add(@{Op='callr';s=20})
        $s.Add(@{Op='syncht'})
        $s.Add(@{Op='label';Name=$done})
        $s.Add(@{Op='store';s=16;t=18;Offset=20}); $s.Add(@{Op='addi';d=0;s=16;i=20}); $s.Add(@{Op='imm';d=1;i=1}); $s.Add(@{Op='trap0';i=0x11})
        & $jump $loop
        $s.Add(@{Op='label';Name=$idle})
        & $futexWait 17 18; & $jump $loop
        $s.Add(@{Op='label';Name=$quit})
        $s.Add(@{Op='imm';d=0;i=3}); $s.Add(@{Op='imm';d=5;i=0}); $s.Add(@{Op='trap0';i=0x55})
        $s.Add(@{Op='imm';d=0;i=0}); $s.Add(@{Op='got-call';Import='qurt_thread_exit';d=14})
    }
    if($PmuEvents){
        $s.Add(@{Op='label';Name='body_pmu_mark'}); $s.Add(@{Op='allocframe';Bytes=16}); $s.Add(@{Op='store';s=29;t=0;Offset=0})
        $s.Add(@{Op='imm';d=5;i=0}); $s.Add(@{Op='trap0';i=0x63})
        & $ptr 9 25 ($pmuOffset+128); for($k=0;$k -lt 8;$k++){ $s.Add(@{Op='store';s=9;t=(1+$k);Offset=(4*$k)}) }
        & $ptr 2 25 $pmuOffset; $s.Add(@{Op='load';d=4;s=2;Offset=28}); $s.Add(@{Op='or';d=4;s=4;t=0}); $s.Add(@{Op='store';s=2;t=4;Offset=28})
        & $ptr 2 25 ($pmuOffset+128); & $ptr 3 25 ($pmuOffset+64); $s.Add(@{Op='load';d=1;s=29;Offset=0})
        $s.Add(@{Op='hwticks';d=6}); $s.Add(@{Op='store-d';s=2;t=6;Offset=32})
        $s.Add(@{Op='upcycle';d=6}); $s.Add(@{Op='store-d';s=2;t=6;Offset=40})
        for($k=0;$k -lt 8;$k++){
            $s.Add(@{Op='load';d=4;s=2;Offset=(4*$k)}); $s.Add(@{Op='load';d=5;s=3;Offset=(4*$k)}); $s.Add(@{Op='sub';d=6;s=4;t=5})
            $s.Add(@{Op='load';d=7;s=1;Offset=(4*$k)}); $s.Add(@{Op='add';d=7;s=7;t=6}); $s.Add(@{Op='store';s=1;t=7;Offset=(4*$k)}); $s.Add(@{Op='store';s=3;t=4;Offset=(4*$k)})
        }
        foreach($o in 32,40){
            $s.Add(@{Op='load-d';d=4;s=2;Offset=$o}); $s.Add(@{Op='load-d';d=6;s=3;Offset=$o}); $s.Add(@{Op='sub-d';d=8;s=4;t=6})
            $s.Add(@{Op='load-d';d=10;s=1;Offset=$o}); $s.Add(@{Op='add-d';d=10;s=10;t=8}); $s.Add(@{Op='store-d';s=1;t=10;Offset=$o}); $s.Add(@{Op='store-d';s=3;t=4;Offset=$o})
        }
        $s.Add(@{Op='load';d=4;s=1;Offset=48}); $s.Add(@{Op='addi';d=4;s=4;i=1}); $s.Add(@{Op='store';s=1;t=4;Offset=48})
        $s.Add(@{Op='dealloc-return'})
    }
    $labels=@{};$pcs=[Collections.Generic.Dictionary[object,long]]::new();$pc=0L;$isa=Get-InstructionSet
    foreach($step in $s){if($step.Op -eq 'label'){if($labels.ContainsKey($step.Name)){throw "Duplicate label $($step.Name)"};$labels[$step.Name]=$pc};$pcs[$step]=$pc;$pc+=& $isa.Length $step}
    foreach($c in $calls){$delta=[uint32](($labels[$c.label]-$pcs[$c.pc]) -band 0xffffffffL);$c.low.i=$delta -band 65535;$c.high.i=$delta -shr 16}
    [pscustomobject]@{Steps=$s.ToArray();Layout=[ordered]@{Frames=$Frames;Tiles=$tiles;InputBytes=$inputBytes;WeightBytes=$weightBytes;ParameterBytes=$parameterBytes;OutputBytes=$outputBytes;VtcmBytes=$vtcmBytes;Samples=$(if($Tail){5*($Frames-1)}else{1});PcmOffset=$(if($Tail){$pcmOffset}else{256});BranchStride=$stride;FinalWorkspaceOffset=$finalOffset;CoefficientOffset=$coefOffset;ScratchOffset=$scratchOffset;CompletedStages=$(6*$branches+[int]$withMean);BatchTiles=$batch;HvxThreads=$HvxThreads;Regions=$layout.Regions}}
}
