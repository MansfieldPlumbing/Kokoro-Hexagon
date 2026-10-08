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
    param([ValidateRange(2,32768)][int]$Frames=7801,[ValidateRange(1,64)][int]$BatchTiles=22)
    $tiles=[int][math]::Ceiling($Frames/32); $bytes=$tiles*8192
    $al={param([long]$v) [long]([math]::Ceiling($v/65536)*65536)}
    $small=[ordered]@{Parameters=0;Moments=16384;InputMoments=18432;PrivateMoments=20480;Kms=26624}
    $regions=[ordered]@{}; $at=0L
    # HMX activation reads must not straddle a 4 MiB VTCM page: both windows come first.
    $list=@(@('Window',(($BatchTiles+2)*8192)),@('WindowLow',(($BatchTiles+2)*8192)),@('Planes',(6L*$BatchTiles*8192)),@('Weights',(32768*11)),@('Small',32768),@('Residual',$bytes),@('ConvOutput',$bytes))
    foreach($r in $list){ $regions[$r[0]]=[ordered]@{Offset=$at;Bytes=[long]$r[1]}; $at+=& $al $r[1] }
    $page=4194304
    foreach($name in 'Window','WindowLow'){ $w=$regions[$name]; if([math]::Floor($w.Offset/$page) -ne [math]::Floor(($w.Offset+$w.Bytes-1)/$page)){throw 'Conv-input window crosses a 4 MiB VTCM boundary'} }
    [pscustomobject]@{Frames=$Frames;Tiles=$tiles;TensorBytes=$bytes;BatchTiles=$BatchTiles;Regions=$regions;Small=$small;VtcmBytes=$at;PlaneStride=([long]$BatchTiles*8192)}
}

function New-KokoroGenerator60x16RunSteps {
    param([ValidateRange(2,32768)][int]$Frames=7801,[ValidateRange(1,64)][int]$BatchTiles=22,[ValidateRange(1,4)][int]$HvxThreads=4,
        [ValidateCount(8,8)][ValidateRange(0,1023)][int[]]$PmuEvents,
        # Diagnosis: end after stage StopAfterStage (b*6 + s) with its output (C after a first half, R after a
        # second half) in the final-tensor slot.
        [ValidateRange(-1,17)][int]$StopAfterStage=-1,
        # With StopAfterStage: Windows dumps the first batch's conv-input windows (high, then low), Planes its
        # six HMX byte planes, into the final-tensor slot instead of finishing the stage.
        [ValidateSet('Stage','Windows','Planes')][string]$DumpPoint='Stage')
    . (Join-Path $PSScriptRoot 'Kokoro.ResBlockRun.ps1')
    foreach($file in 'Kokoro.HmxConvPlanes.ps1','Kokoro.PlaneCombine.ps1','Kokoro.AdaInMoments16.ps1','Kokoro.AdaInTurnsCoefficients.ps1','Kokoro.AdaInSnakeTurns.ps1','Kokoro.BranchMean16.ps1','Kokoro.DmaCopy.ps1') { . (Join-Path $PSScriptRoot $file) }
    $layout=Get-KokoroGenerator60x16Layout -Frames $Frames -BatchTiles $BatchTiles
    $tiles=$layout.Tiles; $tensorBytes=$layout.TensorBytes; $batch=$BatchTiles; $R=$layout.Regions; $planeStride=$layout.PlaneStride
    $offResidual=$R.Residual.Offset; $offConv=$R.ConvOutput.Offset; $offWin=$R.Window.Offset; $offLow=$R.WindowLow.Offset; $offPlanes=$R.Planes.Offset; $offWeights=$R.Weights.Offset
    $offSmall=$R.Small.Offset; $offParams=$offSmall+$layout.Small.Parameters; $offMoments=$offSmall+$layout.Small.Moments; $offInputMoments=$offSmall+$layout.Small.InputMoments; $offKms=$offSmall+$layout.Small.Kms
    $privateMoments=@(0,0,1,2) | ForEach-Object { $offSmall+$layout.Small.PrivateMoments+2048*$_ }
    $kernels=@(3,7,11)
    $branchWeights=@(0L,(6L*32768*3),(6L*32768*10)); $weightBytes=6L*32768*21; $parameterBytes=18*16384
    $stride=[int]([math]::Ceiling($tensorBytes/128)*128); $finalOffset=2*$stride; $coefOffset=$finalOffset+$tensorBytes
    $scratchOffset=[long]([math]::Ceiling(($coefOffset+18*1536)/4096)*4096); $outputBytes=192+$scratchOffset+131072

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
            if($c -gt 0 -and $Moments){ & $ptr 4 18 $privateMoments[$k]; $s.Add(@{Op='vxor';d=0;s=0;t=0}); for($v=0;$v -lt 16;$v++){$s.Add(@{Op='vstore';s=4;t=0;Offset=(128*($v%8))}); if($v -eq 7){$s.Add(@{Op='addi';d=4;s=4;i=1024})}} }
            & $ptr 6 25 ($poolOffset+64*$k)
            if($c -gt 0){
                for($i=0;$i -lt $n;$i++){
                    $value=if($Moments -and $i -eq 1){$privateMoments[$k]}elseif($perTile[$i]){$off[$i]+$o*8192}else{$off[$i]}
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
                for($half=0;$half -lt 2;$half++){
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
        & $ptr 4 18 $off; & $imm 6 $pattern; $s.Add(@{Op='vsplat';d=0;s=6}); & $imm 5 ($count*64); $s.Add(@{Op='imm';d=7;i=0})
        $n=& $label; $s.Add(@{Op='label';Name=$n});$s.Add(@{Op='vstore';s=4;t=0;Offset=0});$s.Add(@{Op='addi';d=4;s=4;i=128});$s.Add(@{Op='addi';d=5;s=5;i=-1});$s.Add(@{Op='gtu';d=0;s=5;t=7});$s.Add(@{Op='jump-p';u=0;Label=$n})
        & $mark 'TileFix'
    }
    $zeroRecord={param([long]$off) & $ptr 4 18 $off; $s.Add(@{Op='vxor';d=0;s=0;t=0}); for($k=0;$k -lt 16;$k++){$s.Add(@{Op='vstore';s=4;t=0;Offset=(128*($k%8))}); if($k -eq 7){$s.Add(@{Op='addi';d=4;s=4;i=1024})}} }
    $copyRecord={param([long]$destOff,[long]$srcOff) for($half=0;$half -lt 2;$half++){ & $ptr 4 18 ($srcOff+1024*$half); & $ptr 5 18 ($destOff+1024*$half); for($k=0;$k -lt 8;$k++){$s.Add(@{Op='vload';d=$k;s=4;Offset=(128*$k)})}; for($k=0;$k -lt 8;$k++){$s.Add(@{Op='vstore';s=5;t=$k;Offset=(128*$k)})} } }
    # Rows >= Frames of the tile at tileOff: every halfword of those rows <- value (0x8000 or 0).
    $padRows={param([long]$tileOff,[long]$value)
        if($Frames%32 -eq 0){return}
        for($t=$Frames%32;$t -lt 32;$t++){
            for($block=0;$block -lt 4;$block++){
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
    $minimum=@(4,$tensorBytes,$weightBytes,$parameterBytes,$outputBytes)
    $oldVtcm=[long]$wrapperSource.Layout.VtcmBytes
    $patched=@{request=0;check=0}
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
    & $poolStart
    $stopped=$false
    for($b=0;$b -lt 3 -and -not $stopped;$b++){
        $K=$kernels[$b]
        & $dma 18 $offResidual 20 0 $tensorBytes
        if($b -eq 0){ & $zeroRecord $offMoments; & $moments $offResidual $tiles; & $copyRecord $offInputMoments $offMoments }
        else { & $copyRecord $offMoments $offInputMoments }
        for($p=0;$p -lt 3 -and -not $stopped;$p++){
            $dilation=@(1,3,5)[$p]
            foreach($half in 0,1){
                if($stopped){continue}
                $st=2*$p+$half
                & $dma 18 $offParams 22 (($b*6+$st)*16384) 16384
                & $dma 18 $offWeights 21 ($branchWeights[$b]+$st*32768L*$K) (32768L*$K)
                & $ptr 0 18 $offMoments; & $ptr 1 18 $offParams; & $ptr 2 18 $offKms; & $imm 3 $Frames; & $call 'body_coeff'; & $mark 'Coefficients'
                & $dma 25 ($coefOffset+($b*6+$st)*1536) 18 $offKms 1536
                & $zeroRecord $offMoments
                $source=if($half -eq 0){$offResidual}else{$offConv}
                $convLabel="body_conv_b${b}_d$(if($half -eq 0){$dilation}else{1})"
                for($start=0;$start -lt $tiles;$start+=$batch){
                    $count=[math]::Min($batch,$tiles-$start)
                    $first=[math]::Max(0,$start-1);$last=[math]::Min($tiles,$start+$count+1)
                    if($start -eq 0){ & $fill $offWin 1 0x80008000L; & $fill $offLow 1 0 }
                    if($start+$count -eq $tiles){ & $fill ($offWin+($count+1)*8192) 1 0x80008000L; & $fill ($offLow+($count+1)*8192) 1 0 }
                    & $parallel 'body_turns' @(($source+$first*8192),($offWin+($first-$start+1)*8192),($offLow+($first-$start+1)*8192),$offKms) @($true,$true,$true,$false) ($last-$first)
                    & $mark 'AdaInSnake'
                    if($last -eq $tiles){ & $padRows ($offWin+($tiles-$start)*8192) 0x8000; & $padRows ($offLow+($tiles-$start)*8192) 0 }
                    & $sync
                    if($b*6+$st -eq $StopAfterStage -and $start -eq 0 -and $DumpPoint -eq 'Windows'){ & $dma 25 $finalOffset 18 $offWin (($batch+2)*8192L); & $dma 25 ($finalOffset+($batch+2)*8192L) 18 $offLow (($batch+2)*8192L); $stopped=$true; break }
                    & $ptr 0 18 ($offWin+8192); & $ptr 1 18 ($offLow+8192); & $ptr 2 18 $offWeights; & $ptr 3 18 ($offParams+4096); & $imm 4 $count; & $ptr 5 18 $offPlanes
                    & $call $convLabel; & $mark 'HmxConv'
                    & $sync
                    if($b*6+$st -eq $StopAfterStage -and $start -eq 0 -and $DumpPoint -eq 'Planes'){ & $dma 25 $finalOffset 18 $offPlanes (6L*$planeStride); $stopped=$true; break }
                    $hasLast=($start+$count -eq $tiles)
                    if($half -eq 0){
                        & $parallel 'body_combine_conv' @($offPlanes,($offConv+$start*8192),($offParams+10240)) @($true,$true,$false) $count
                        & $mark 'Combine'
                        if($hasLast){ & $padRows ($offConv+($tiles-1)*8192) 0x8000 }
                        & $moments ($offConv+$start*8192) $count
                    } else {
                        & $parallel 'body_combine_residual' @($offPlanes,($offResidual+$start*8192),($offParams+10240)) @($true,$true,$false) $count
                        & $mark 'Combine'
                        if($hasLast){ & $padRows ($offResidual+($tiles-1)*8192) 0x8000 }
                        if($p -lt 2){ & $moments ($offResidual+$start*8192) $count }
                    }
                }
                if($b*6+$st -eq $StopAfterStage -and -not $stopped){
                    & $sync; & $dma 25 $finalOffset 18 $(if($half -eq 0){$offConv}else{$offResidual}) $tensorBytes; $stopped=$true
                }
            }
        }
        if($b -lt 2 -and -not $stopped){ & $sync; & $dma 25 ($b*$stride) 18 $offResidual $tensorBytes }
    }
    # Three-branch mean in two chunks: branches 0 and 1 come back from DDR into the free C region.
    if(-not $stopped){
    & $sync
    $chunk=[int][math]::Ceiling($tiles/2)
    for($j=0;$j*$chunk -lt $tiles;$j++){
        $chunkTiles=[math]::Min($chunk,$tiles-$j*$chunk)
        & $dma 18 $offConv 25 ($j*$chunk*8192) ($chunkTiles*8192)
        & $dma 18 ($offConv+$chunk*8192) 25 ($stride+$j*$chunk*8192) ($chunkTiles*8192)
        & $parallel 'body_mean' @($offConv,($offConv+$chunk*8192),($offResidual+$j*$chunk*8192),$offConv) @($true,$true,$true,$true) $chunkTiles
        & $mark 'Mean'; & $sync
        & $dma 25 ($finalOffset+$j*$chunk*8192) 18 $offConv ($chunkTiles*8192)
    }
    }
    & $poolStop
    if($PmuEvents){
        $s.Add(@{Op='imm';d=0;i=0}); $s.Add(@{Op='imm';d=1;i=0}); $s.Add(@{Op='imm';d=2;i=0}); $s.Add(@{Op='trap0';i=0x4a})
        & $ptr 2 25 $pmuOffset; & $imm 4 0x31554D50L; $s.Add(@{Op='store';s=2;t=4;Offset=0})
    }
    $s.Add(@{Op='hwticks';d=0});$s.Add(@{Op='store-d';s=23;t=26;Offset=0});$s.Add(@{Op='store-d';s=23;t=0;Offset=8})
    $s.Add(@{Op='sub';d=0;s=25;t=23});& $imm 1 $finalOffset;$s.Add(@{Op='add';d=0;s=0;t=1});$s.Add(@{Op='store';s=23;t=0;Offset=40})
    $s.Add(@{Op='imm';d=0;i=19});$s.Add(@{Op='store';s=23;t=0;Offset=44})
    foreach($r in 16,18,20,22,24,26){$s.Add(@{Op='load-d';d=$r;s=29;Offset=(($r-16)*4)})}
    $s.Add(@{Op='dealloc-return'})

    $bodies=[Collections.Generic.List[object]]::new()
    $bodies.Add(@('body_turns',@(New-KokoroAdaInSnakeTurnsSteps)))
    $bodies.Add(@('body_moments',@(New-KokoroAdaInMoments16Steps)))
    $bodies.Add(@('body_coeff',@(New-KokoroAdaInTurnsCoefficientsSteps)))
    $bodies.Add(@('body_combine_conv',@(New-KokoroPlaneCombineSteps -Mode Conv -Groups 2 -PlaneStride $planeStride -LabelPrefix 'combineconv')))
    $bodies.Add(@('body_combine_residual',@(New-KokoroPlaneCombineSteps -Mode Residual -Groups 2 -PlaneStride $planeStride -LabelPrefix 'combineresidual')))
    $bodies.Add(@('body_mean',@(New-KokoroBranchMean16Steps)))
    for($b=0;$b -lt 3;$b++){foreach($d in 1,3,5){$bodies.Add(@("body_conv_b${b}_d$d",@(New-KokoroHmxConvPlanesSteps -Kernel $kernels[$b] -Dilation $d -WeightPlanes 2 -PlaneStride $planeStride -LabelPrefix "g16_b${b}_d$d")))}}
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
    [pscustomobject]@{Steps=$s.ToArray();Layout=[ordered]@{Frames=$Frames;Tiles=$tiles;InputBytes=$tensorBytes;WeightBytes=$weightBytes;ParameterBytes=$parameterBytes;OutputBytes=$outputBytes;VtcmBytes=$layout.VtcmBytes;BranchStride=$stride;FinalWorkspaceOffset=$finalOffset;CoefficientOffset=$coefOffset;ScratchOffset=$scratchOffset;CompletedStages=19;BatchTiles=$batch;HvxThreads=$HvxThreads;Regions=$layout.Regions}}
}
