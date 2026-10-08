#requires -Version 7.4
# Stock generator resblocks.3/4/5 and their three-way mean with the activations resident
# in VTCM. Source: hexgrad/kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec, istftnet.py
# AdaINResBlock1.forward and Generator.forward. Design: docs/generator60x-resident-design.md.
#
# Same method-2 contract and output layout as Kokoro.Generator60xRun.ps1, so the frozen
# fixture, simulator runner and device harness apply unchanged. DDR is touched only by
# user DMA (descriptors in DDR, the job's own frame): the stage input in, per-stage weights
# and parameter records in, branch 0/1 outputs out and back, the final tensor and the
# coefficients out. Every HVX pass runs on VTCM.
#
# Per branch (kernel 3, 7, 11), per dilation pair (1, 3, 5):
#   first half:  coefficients from R moments; per batch fused AdaIN+Snake R -> window,
#                HMX conv window -> C; epilogue: moments of C.
#   second half: coefficients from C moments; per batch fused AdaIN+Snake C -> window,
#                HMX conv window -> O; epilogue: residual R += O, moments of the new R.
# Rows past the frame count follow the frozen worker exactly: zero for moments, zero point
# 128 at the conv input, and the residual skip keeps its unmasked padded rows (saved tile S).
function Get-KokoroGenerator60xResidentLayout {
    param([ValidateRange(2,32768)][int]$Frames=7801,[ValidateRange(1,64)][int]$BatchTiles=16,[ValidateSet(2048,65536)][int]$RegionAlign=65536,[switch]$CostProbe)
    $tiles=[int][math]::Ceiling($Frames/32); $bytes=$tiles*8192
    $al={param([long]$v) [long]([math]::Ceiling($v/$RegionAlign)*$RegionAlign)}
    $small=[ordered]@{Parameters=0;Moments=8192;InputMoments=9216;MeanParameters=10240;SavedTile=16384;Coefficients=24576}
    $smallBytes=24576+18432
    $regions=[ordered]@{}
    $at=0L
    # HMX activation reads span a crouton and the next tile; in the V73 simulator a read that
    # straddles a 4 MiB VTCM boundary faults (exception 0x26), while HMX output stores and
    # weight reads across it do not. The conv-input window therefore sits inside one 4 MiB
    # page: small regions first, then the two resident tensors (HVX-only reads).
    $list=@(,@('Window',(($BatchTiles+2)*8192)))
    if($CostProbe){ $list+=,@('WindowLow',(($BatchTiles+2)*8192)) }
    $list+=@(@('Staging',($BatchTiles*8192)),@('Weights',180224),@('Small',$smallBytes),@('Residual',$bytes),@('ConvOutput',$bytes))
    if($CostProbe){ $list+=@(@('ProbeHigh',($BatchTiles*8192)),@('ProbeLow',($BatchTiles*8192)),@('ProbeMerged',($BatchTiles*8192))) }
    foreach($r in $list){
        $regions[$r[0]]=[ordered]@{Offset=$at;Bytes=[long]$r[1]}; $at+=& $al $r[1]
    }
    $page=4194304
    foreach($name in @('Window','WindowLow')){ if(-not $regions.Contains($name)){continue}; $window=$regions[$name]
        if([math]::Floor($window.Offset/$page) -ne [math]::Floor(($window.Offset+$window.Bytes-1)/$page)){throw 'Conv-input window crosses a 4 MiB VTCM boundary'} }
    [pscustomobject]@{Frames=$Frames;Tiles=$tiles;TensorBytes=$bytes;BatchTiles=$BatchTiles;RegionAlign=$RegionAlign;Regions=$regions;Small=$small;VtcmBytes=$at}
}

function New-KokoroGenerator60xResidentRunSteps {
    # CostProbePasses > 0 times the work of byte-plane precision without changing the output:
    # a second fused AdaIN+Snake pass into WindowLow, CostProbePasses extra HMX passes per conv
    # with two-plane stores into scratch, and an HVX merge of the scratch planes. Measurement only.
    # CostProbeTurnsBody (with CostProbePasses > 0) replaces the fused body by the phase-turns body
    # (Kokoro.AdaInSnakeTurns.ps1), which writes the high plane to Window and the low plane to WindowLow
    # in one call; its constants are stand-ins, so the output is not the stock tensor. Timing only.
    # PmuEvents (eight hardware event selects) adds a performance-counter record; without it the
    # emitted bytes are unchanged. See the PMU block below for the record layout.
    param([ValidateRange(2,32768)][int]$Frames=7801,[ValidateRange(1,64)][int]$BatchTiles=16,[ValidateRange(0,3)][int]$CostProbePasses=0,[switch]$CostProbeTurnsBody,
        [ValidateCount(8,8)][ValidateRange(0,1023)][int[]]$PmuEvents,[ValidateRange(1,4)][int]$HvxThreads=1)
    if($CostProbeTurnsBody -and $CostProbePasses -lt 1){throw 'CostProbeTurnsBody needs CostProbePasses >= 1'}
    . (Join-Path $PSScriptRoot 'Kokoro.ResBlockRun.ps1')
    foreach($file in 'Kokoro.HmxConv.ps1','Kokoro.AdaInInteger.ps1','Kokoro.ResidualInteger.ps1','Kokoro.AdaInSnakeInteger.ps1','Kokoro.AdaInSnakeTurns.ps1','Kokoro.AdaInStatisticsAccumulate.ps1','Kokoro.DmaCopy.ps1','Kokoro.BranchAverageInteger.ps1') { . (Join-Path $PSScriptRoot $file) }
    $layout=Get-KokoroGenerator60xResidentLayout -Frames $Frames -BatchTiles $BatchTiles -CostProbe:($CostProbePasses -gt 0)
    $tiles=$layout.Tiles; $tensorBytes=$layout.TensorBytes; $batch=$BatchTiles
    $offResidual=$layout.Regions.Residual.Offset; $offConvOutput=$layout.Regions.ConvOutput.Offset; $offWindow=$layout.Regions.Window.Offset; $offStaging=$layout.Regions.Staging.Offset; $offWeights=$layout.Regions.Weights.Offset
    $offSmall=$layout.Regions.Small.Offset
    $offParameters=$offSmall+$layout.Small.Parameters; $offMoments=$offSmall+$layout.Small.Moments; $offInputMoments=$offSmall+$layout.Small.InputMoments; $offMeanParameters=$offSmall+$layout.Small.MeanParameters; $offSaved=$offSmall+$layout.Small.SavedTile; $offCoefficients=$offSmall+$layout.Small.Coefficients
    # Frozen output contract (Kokoro.Generator60xRun.ps1).
    $branchOutputBytes=192+5*$tensorBytes+6144
    $stride=[int]([math]::Ceiling($branchOutputBytes/128)*128)
    $finalOffset=3*$stride
    $outputBytes=192+$finalOffset+$tensorBytes+18432
    $weightOffsets=@(0,294912,983040);$weightBytes=2064384;$parameterBytes=147472
    $kernels=@(3,7,11)

    $s=[Collections.Generic.List[hashtable]]::new()
    $calls=[Collections.Generic.List[object]]::new()
    $imm={param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL);$s.Add(@{Op='lo';x=$r;i=($u -band 65535)});$s.Add(@{Op='hi';x=$r;i=($u -shr 16)})}
    $ptr={param([int]$r,[int]$baseReg,[long]$offset)
        $offsetReg=if($r -eq $baseReg){15}else{$r}
        & $imm $offsetReg $offset;$s.Add(@{Op='add';d=$r;s=$baseReg;t=$offsetReg})
    }
    $call={param([string]$label) $pc=@{Op='add-pc';d=14;i=0};$lo=@{Op='lo';x=15;i=0};$hi=@{Op='hi';x=15;i=0};$s.Add($pc);$s.Add($lo);$s.Add($hi);$s.Add(@{Op='add';d=14;s=14;t=15});$s.Add(@{Op='callr';s=14});$calls.Add(@{pc=$pc;low=$lo;high=$hi;label=$label})}
    $uid=0
    $label={ $script:__u++; "r60_$($script:__u)" }
    $script:__u=0
    # Performance counters (PmuEvents). Record at DDR workspace r25 + 2*stride, the branch-2 slot
    # this resident stage never writes:
    #   +0 magic 'PMU1'; +4 qurt_hvx_get_units(); +8 and +12 reserved (zero); +16 PMUCFG, +20 PMUEVTCFG, +24 PMUEVTCFG1 as written;
    #   +28 OR of the counter-read return codes; +64 previous snapshot, +128 current snapshot
    #   (8 x u32 counters, u64 UTIMER ticks at +32, u64 UPCYCLE at +40);
    #   +256 + 64*category: 8 x u32 counter deltas, u64 ticks at +32, u64 cycles at +40, u32 marks at +48.
    # A mark charges the counts since the previous mark to the named category. Register packing of
    # the eight event selects follows llama.cpp ad2156533102a0d3c4e5fbdf422dc25fba4d03ba
    # ggml/src/ggml-hexagon/htp/main.c htp_iface_profiler; register ids and process classes from
    # SDK 6.4.0.2 rtos/qurt/computev73/include/qurt/qurt_pmu.h and qurt_consts.h.
    $pmuCategories=@('Setup','Dma','Coefficients','AdaInSnake','HmxConv','Moments','Residual','Average','Sync','TileFix','CostProbe')
    $pmuOffset=2L*$stride
    $mark={param([string]$category)
        if(-not $PmuEvents){return}
        $c=[array]::IndexOf($pmuCategories,$category); if($c -lt 0){throw "Unknown PMU category $category"}
        & $ptr 0 25 ($pmuOffset+256+64*$c); & $call 'body_pmu_mark'
    }
    # HVX worker threads (HvxThreads > 1). Each fused AdaIN+Snake call splits its tiles into
    # HvxThreads contiguous parts; the job thread runs part 0, workers 1..HvxThreads-1 the rest.
    # Pool block at DDR workspace r25 + 2*stride + 4096:
    #   +0 dispatch sequence, +4 quit, +8 'POOL', +12 HvxThreads;
    #   +64*k worker k: +0 source, +4 destination, +8 coefficients, +12 parameters (absolute),
    #   +16 tile count, +20 completed sequence, +24 thread id, +28 qurt_thread_create rc,
    #   +32 pool block address, +36 exit status, +40 qurt_thread_join rc;
    #   +512 + 64*k: qurt_thread_attr_t (SDK 6.4.0.2 computev73 qurt_thread.h: name[16], tcb 0,
    #   stid 0, priority 127 at +18 (QURT_THREAD_ATTR_PRIORITY_DEFAULT/2, as the SDK
    #   multithreading example), bus priority 255 at +21, timetest -2 at +22, stack size at +24,
    #   stack address at +28, detach 0 at +32). Stacks of 16 KiB at + 65536 - 4096 + 16384*k.
    # qurt_thread_create/join/exit are imports (the SDK examples call them from skels); futex
    # wait/wake and HVX lock/unlock are the libqurt.a trap stubs (SDK 6.4.0.2 computev73
    # pic/libqurt.a 8e0ba5fd...): futex_wait r0 addr, r1 value, r3 = 0, r4 = r5 = -1,
    # trap0(#0x20); futex_wake r0 addr, r1 count, trap0(#0x11); hvx lock r0 = 1 (128 B),
    # r5 = 0, trap0(#0x55); unlock r0 = 3, r5 = 0, trap0(#0x55).
    $poolOffset=2L*$stride+4096
    $stackOffset=2L*$stride+65536
    $addr={param([int]$r,[string]$target) $pc=@{Op='add-pc';d=$r;i=0};$lo=@{Op='lo';x=15;i=0};$hi=@{Op='hi';x=15;i=0};$s.Add($pc);$s.Add($lo);$s.Add($hi);$s.Add(@{Op='add';d=$r;s=$r;t=15});$calls.Add(@{pc=$pc;low=$lo;high=$hi;label=$target})}
    $jump={param([string]$target) $s.Add(@{Op='eq';d=0;s=0;t=0}); $s.Add(@{Op='jump-p';u=0;Label=$target}) }
    $futexWait={param([int]$addrReg,[int]$valueReg) $s.Add(@{Op='addi';d=1;s=$valueReg;i=0}); $s.Add(@{Op='addi';d=0;s=$addrReg;i=0}); $s.Add(@{Op='imm';d=3;i=0}); $s.Add(@{Op='imm';d=4;i=-1}); $s.Add(@{Op='imm';d=5;i=-1}); $s.Add(@{Op='trap0';i=0x20}) }
    $fused={param([long]$src,[long]$dst,[long]$coef,[long]$prm,[int]$count)
        if($HvxThreads -eq 1){ & $ptr 0 18 $src; & $ptr 1 18 $dst; & $ptr 2 18 $coef; & $ptr 3 18 $prm; & $imm 4 $count; & $call 'body_fused'; return }
        $chunk=[int][math]::Ceiling($count/$HvxThreads)
        for($k=1;$k -lt $HvxThreads;$k++){
            $o=$k*$chunk; $c=[math]::Max(0,[math]::Min($chunk,$count-$o))
            & $ptr 6 25 ($poolOffset+64*$k)
            if($c -gt 0){
                & $ptr 0 18 ($src+$o*8192); $s.Add(@{Op='store';s=6;t=0;Offset=0}); & $ptr 0 18 ($dst+$o*8192); $s.Add(@{Op='store';s=6;t=0;Offset=4})
                & $ptr 0 18 $coef; $s.Add(@{Op='store';s=6;t=0;Offset=8}); & $ptr 0 18 $prm; $s.Add(@{Op='store';s=6;t=0;Offset=12})
            }
            & $imm 0 $c; $s.Add(@{Op='store';s=6;t=0;Offset=16})
        }
        # Earlier HVX/HMX stores and the arguments complete before the workers start.
        $s.Add(@{Op='syncht'})
        & $ptr 6 25 $poolOffset; $s.Add(@{Op='load';d=0;s=6;Offset=0}); $s.Add(@{Op='addi';d=0;s=0;i=1}); $s.Add(@{Op='store';s=6;t=0;Offset=0})
        $s.Add(@{Op='addi';d=0;s=6;i=0}); & $imm 1 ($HvxThreads-1); $s.Add(@{Op='trap0';i=0x11})
        & $ptr 0 18 $src; & $ptr 1 18 $dst; & $ptr 2 18 $coef; & $ptr 3 18 $prm; & $imm 4 ([math]::Min($chunk,$count)); & $call 'body_fused'
        for($k=1;$k -lt $HvxThreads;$k++){
            $wait=& $label; $done=& $label
            $s.Add(@{Op='label';Name=$wait})
            & $ptr 6 25 ($poolOffset+64*$k); & $ptr 7 25 $poolOffset; $s.Add(@{Op='load';d=8;s=6;Offset=20}); $s.Add(@{Op='load';d=9;s=7;Offset=0})
            $s.Add(@{Op='eq';d=0;s=8;t=9}); $s.Add(@{Op='jump-p';u=0;Label=$done})
            $s.Add(@{Op='addi';d=6;s=6;i=20}); & $futexWait 6 8; & $jump $wait
            $s.Add(@{Op='label';Name=$done})
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
    # HVX stores and HMX output stores complete before DMA or another unit reads them.
    $sync={ $s.Add(@{Op='syncht'}); & $mark 'Sync' }
    $fill={param([long]$off,[int]$count) # VTCM tiles <- zero point 128 in every odd byte
        & $ptr 4 18 $off; & $imm 6 0x80008000L; $s.Add(@{Op='vsplat';d=0;s=6}); & $imm 5 ($count*64); $s.Add(@{Op='imm';d=7;i=0})
        $n=& $label; $s.Add(@{Op='label';Name=$n});$s.Add(@{Op='vstore';s=4;t=0;Offset=0});$s.Add(@{Op='addi';d=4;s=4;i=128});$s.Add(@{Op='addi';d=5;s=5;i=-1});$s.Add(@{Op='gtu';d=0;s=5;t=7});$s.Add(@{Op='jump-p';u=0;Label=$n})
        & $mark 'TileFix'
    }
    $copyTile={param([long]$destOff,[long]$srcOff)
        & $ptr 4 18 $srcOff; & $ptr 5 18 $destOff; $s.Add(@{Op='imm';d=6;i=64}); $s.Add(@{Op='imm';d=7;i=0})
        $n=& $label; $s.Add(@{Op='label';Name=$n});$s.Add(@{Op='vload';d=0;s=4;Offset=0});$s.Add(@{Op='vstore';s=5;t=0;Offset=0})
        $s.Add(@{Op='addi';d=4;s=4;i=128});$s.Add(@{Op='addi';d=5;s=5;i=128});$s.Add(@{Op='addi';d=6;s=6;i=-1});$s.Add(@{Op='gtu';d=0;s=6;t=7});$s.Add(@{Op='jump-p';u=0;Label=$n})
        & $mark 'TileFix'
    }
    $zeroMoments={param([long]$off) & $ptr 4 18 $off; $s.Add(@{Op='vxor';d=0;s=0;t=0}); for($k=0;$k -lt 8;$k++){$s.Add(@{Op='vstore';s=4;t=0;Offset=(128*$k)})}; & $mark 'TileFix' }
    $copyMoments={param([long]$destOff,[long]$srcOff) & $ptr 4 18 $srcOff; & $ptr 5 18 $destOff; for($k=0;$k -lt 8;$k++){$s.Add(@{Op='vload';d=$k;s=4;Offset=(128*$k)})}; for($k=0;$k -lt 8;$k++){$s.Add(@{Op='vstore';s=5;t=$k;Offset=(128*$k)})}; & $mark 'TileFix' }
    # Frozen padded-row mask (Kokoro.ResBlockRun.ps1): rows >= Frames of the tile at
    # VTCM offset tileOff become u8 zero; the other row sharing each word is preserved.
    $mask={param([long]$tileOff)
        for($t=$Frames;$t -lt $tiles*32;$t++){
            for($block=0;$block -lt 4;$block++){
                $lane=$tileOff+$block*2048+[int][math]::Floor(($t%32)/2)*128
                & $ptr 4 18 $lane
                & $imm 6 $(if($t%2){0x0000ffffL}else{0xffff0000L})
                $s.Add(@{Op='imm';d=5;i=32});$s.Add(@{Op='imm';d=7;i=0})
                $n=& $label
                $s.Add(@{Op='label';Name=$n});$s.Add(@{Op='load';d=0;s=4;Offset=0});$s.Add(@{Op='and';d=0;s=0;t=6});$s.Add(@{Op='store';s=4;t=0;Offset=0})
                $s.Add(@{Op='addi';d=4;s=4;i=4});$s.Add(@{Op='addi';d=5;s=5;i=-1});$s.Add(@{Op='gtu';d=0;s=5;t=7});$s.Add(@{Op='jump-p';u=0;Label=$n})
            }
        }
        & $mark 'TileFix'
    }
    # Frozen conv-input edge (Kokoro.ResBlockRun.ps1): rows >= Frames of the window tile at
    # tileOff become zero point 128.
    $edge={param([long]$tileOff)
        for($t=$Frames%32;$t -lt 32;$t++){
            for($block=0;$block -lt 4;$block++){
                $lane=$tileOff+$block*2048+[int][math]::Floor($t/2)*128
                & $ptr 4 18 $lane; & $imm 6 $(if($t%2){0x0000ffffL}else{0xffff0000L}); & $imm 8 $(if($t%2){0x80000000L}else{0x00008000L})
                $s.Add(@{Op='imm';d=5;i=32});$s.Add(@{Op='imm';d=7;i=0});$n=& $label
                $s.Add(@{Op='label';Name=$n});$s.Add(@{Op='load';d=0;s=4;Offset=0});$s.Add(@{Op='and';d=0;s=0;t=6});$s.Add(@{Op='or';d=0;s=0;t=8});$s.Add(@{Op='store';s=4;t=0;Offset=0});$s.Add(@{Op='addi';d=4;s=4;i=4});$s.Add(@{Op='addi';d=5;s=5;i=-1});$s.Add(@{Op='gtu';d=0;s=5;t=7});$s.Add(@{Op='jump-p';u=0;Label=$n})
            }
        }
        & $mark 'TileFix'
    }
    $statsAcc={param([long]$srcOff,[int]$count) & $ptr 0 18 $srcOff; & $ptr 1 18 $offMoments; & $imm 2 $count; & $call 'body_statsacc'; & $mark 'Moments' }

    # Checked resource wrapper of the frozen K=11 resblock runner, with admission sizes and
    # the VTCM request changed. Its connected_job call target keeps its PC (same length).
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
            $value=[long]$step.i -bor ([long]$base[$i+1].i -shl 16)
            $new=$null
            if($step.x -eq 1 -and $value -eq $oldVtcm){$new=$layout.VtcmBytes;$patched.request++}
            elseif($step.x -eq 15 -and $value -eq $oldVtcm-1){$new=$layout.VtcmBytes-1;$patched.check++}
            if($null -ne $new){$step.i=$new -band 65535;$base[$i+1]=$base[$i+1].Clone();$base[$i+1].i=$new -shr 16}
        }
        $s.Add($step)
    }
    if($patched.request -ne 1 -or $patched.check -ne 1){throw "VTCM size anchors changed ($($patched.request),$($patched.check))"}

    # Job. r18 VTCM, r20 input, r21 weights, r22 parameter records, r23 output/telemetry.
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
        # The QuRT calls are libqurt.a trap stubs (SDK 6.4.0.2 rtos/qurt/computev73/lib/pic/libqurt.a,
        # SHA-256 8e0ba5fd2e9fc8c075722241cb314cac5a06319460c2e876ae786617a3931670), emitted inline like
        # qurt_hvx_lock; the DSP image does not export them to this library.
        # qurt_hvx_get_units: r5 = #2; trap0(#0x55); r0 = units.
        $s.Add(@{Op='imm';d=5;i=2}); $s.Add(@{Op='trap0';i=0x55}); & $ptr 2 25 $pmuOffset; $s.Add(@{Op='store';s=2;t=0;Offset=4})
        # qurt_pmu_set(reg, value): r0 = reg, r1 = value, r2 = #1; trap0(#0x4a) (qurt_pmu_ctrl).
        # QURT_PMUCFG 4, QURT_PMUEVTCFG 5, QURT_PMUEVTCFG1 10 (qurt_consts.h).
        foreach($w in @(@(4,$pmucfg),@(5,$evtcfg),@(10,$evtcfg1))){ $s.Add(@{Op='imm';d=0;i=$w[0]}); & $imm 1 $w[1]; $s.Add(@{Op='imm';d=2;i=1}); $s.Add(@{Op='trap0';i=0x4a}) }
        # qurt_pmu_enable(1): r0 = #0, r1 = enable, r2 = #0; trap0(#0x4a).
        $s.Add(@{Op='imm';d=0;i=0}); $s.Add(@{Op='imm';d=1;i=1}); $s.Add(@{Op='imm';d=2;i=0}); $s.Add(@{Op='trap0';i=0x4a})
        & $ptr 2 25 $pmuOffset; & $imm 4 $pmucfg; $s.Add(@{Op='store';s=2;t=4;Offset=16}); & $imm 4 $evtcfg; $s.Add(@{Op='store';s=2;t=4;Offset=20}); & $imm 4 $evtcfg1; $s.Add(@{Op='store';s=2;t=4;Offset=24})
        & $mark 'Setup'
    }
    & $poolStart
    for($b=0;$b -lt 3;$b++){
        $kernel=$kernels[$b]
        & $dma 18 $offResidual 20 0 $tensorBytes
        for($p=0;$p -lt 3;$p++){
            $dilation=@(1,3,5)[$p]
            foreach($half in 0,1){
                $st=2*$p+$half
                & $dma 18 $offParameters 22 ($b*49152+$st*8192) 8192
                & $dma 18 $offWeights 21 ($weightOffsets[$b]+$st*16384*$kernel) (16384*$kernel)
                if($half -eq 0 -and $p -eq 0){
                    # Stage input: unmasked last tile kept for the residual skip, then masked.
                    & $copyTile $offSaved ($offResidual+($tiles-1)*8192)
                    & $mask ($offResidual+($tiles-1)*8192)
                    if($b -eq 0){ & $zeroMoments $offMoments; & $statsAcc $offResidual $tiles; & $copyMoments $offInputMoments $offMoments }
                    else { & $copyMoments $offMoments $offInputMoments }
                }
                & $ptr 0 18 $offMoments; & $ptr 1 18 $offParameters; & $ptr 2 18 ($offCoefficients+($b*6+$st)*1024); & $imm 3 $Frames; & $call 'body_coeff'; & $mark 'Coefficients'
                if(-not ($half -eq 1 -and $p -eq 2)){ & $zeroMoments $offMoments }
                $source=if($half -eq 0){$offResidual}else{$offConvOutput}
                $convLabel="body_conv_b${b}_d$(if($half -eq 0){$dilation}else{1})"
                for($start=0;$start -lt $tiles;$start+=$batch){
                    $count=[math]::Min($batch,$tiles-$start)
                    $first=[math]::Max(0,$start-1);$last=[math]::Min($tiles,$start+$count+1)
                    if($start -eq 0){ & $fill $offWindow 1 }
                    if($start+$count -eq $tiles){ & $fill ($offWindow+($count+1)*8192) 1 }
                    if($CostProbeTurnsBody){
                        & $ptr 0 18 ($source+$first*8192); & $ptr 1 18 ($offWindow+($first-$start+1)*8192); & $ptr 2 18 ($layout.Regions.WindowLow.Offset+($first-$start+1)*8192); & $ptr 3 18 ($offCoefficients+($b*6+$st)*1024); & $imm 4 ($last-$first)
                        & $call 'body_turns'; & $mark 'AdaInSnake'
                    } else {
                        & $fused ($source+$first*8192) ($offWindow+($first-$start+1)*8192) ($offCoefficients+($b*6+$st)*1024) ($offParameters+2048) ($last-$first)
                        & $mark 'AdaInSnake'
                    }
                    if($last -eq $tiles -and $Frames%32){ & $edge ($offWindow+($tiles-$start)*8192) }
                    $output=if($half -eq 0){$offConvOutput+$start*8192}else{$offStaging}
                    & $ptr 0 18 ($offWindow+8192); & $ptr 1 18 $offWeights; & $ptr 2 18 $output; & $ptr 3 18 ($offParameters+4096); & $imm 4 $count
                    & $call $convLabel; & $mark 'HmxConv'
                    if($CostProbePasses -gt 0){
                        $L=$layout.Regions
                        if(-not $CostProbeTurnsBody){
                            & $ptr 0 18 ($source+$first*8192); & $ptr 1 18 ($L.WindowLow.Offset+($first-$start+1)*8192); & $ptr 2 18 ($offCoefficients+($b*6+$st)*1024); & $ptr 3 18 ($offParameters+2048); & $imm 4 ($last-$first)
                            & $call 'body_fused'
                        }
                        for($pass=0;$pass -lt $CostProbePasses;$pass++){
                            & $ptr 0 18 ($L.WindowLow.Offset+8192); & $ptr 1 18 $offWeights; & $ptr 2 18 $L.ProbeHigh.Offset; & $ptr 3 18 ($offParameters+4096); & $imm 4 $count; & $ptr 5 18 $L.ProbeLow.Offset
                            & $call "body_convp_b${b}_d$(if($half -eq 0){$dilation}else{1})"
                        }
                        & $sync
                        # HVX merge stand-in: high | low >> 8 into a scratch halfword tile.
                        & $ptr 4 18 $L.ProbeHigh.Offset; & $ptr 5 18 $L.ProbeLow.Offset; & $ptr 6 18 $L.ProbeMerged.Offset; & $imm 7 ($count*64); $s.Add(@{Op='imm';d=8;i=0}); & $imm 9 0xff00ff00L; $s.Add(@{Op='vsplat';d=3;s=9}); $s.Add(@{Op='imm';d=9;i=8})
                        $n=& $label; $s.Add(@{Op='label';Name=$n}); $s.Add(@{Op='vload';d=0;s=4;Offset=0}); $s.Add(@{Op='vload';d=1;s=5;Offset=0}); $s.Add(@{Op='vand';d=0;s=0;t=3}); $s.Add(@{Op='vlsr-uw';d=1;s=1;t=9}); $s.Add(@{Op='vor';d=0;s=0;t=1}); $s.Add(@{Op='vstore';s=6;t=0;Offset=0})
                        $s.Add(@{Op='addi';d=4;s=4;i=128});$s.Add(@{Op='addi';d=5;s=5;i=128});$s.Add(@{Op='addi';d=6;s=6;i=128});$s.Add(@{Op='addi';d=7;s=7;i=-1});$s.Add(@{Op='gtu';d=0;s=7;t=8});$s.Add(@{Op='jump-p';u=0;Label=$n})
                        & $mark 'CostProbe'
                    }
                    & $sync
                    $hasLast=($start+$count -eq $tiles)
                    if($half -eq 0){
                        if($hasLast){ & $mask ($offConvOutput+($tiles-1)*8192) }
                        & $statsAcc ($offConvOutput+$start*8192) $count
                    } else {
                        $normal=if($hasLast){$count-1}else{$count}
                        if($normal -gt 0){
                            & $ptr 0 18 ($offResidual+$start*8192); & $ptr 1 18 $offStaging; & $ptr 2 18 ($offResidual+$start*8192); & $ptr 3 18 ($offParameters+5120); & $imm 4 $normal
                            & $call 'body_residual'; & $mark 'Residual'
                        }
                        if($hasLast){
                            & $ptr 0 18 $offSaved; & $ptr 1 18 ($offStaging+($count-1)*8192); & $ptr 2 18 ($offResidual+($tiles-1)*8192); & $ptr 3 18 ($offParameters+5120); & $imm 4 1
                            & $call 'body_residual'; & $mark 'Residual'
                        }
                        if($p -lt 2){
                            if($hasLast){ & $copyTile $offSaved ($offResidual+($tiles-1)*8192); & $mask ($offResidual+($tiles-1)*8192) }
                            & $statsAcc ($offResidual+$start*8192) $count
                        }
                    }
                }
            }
        }
        if($b -lt 2){ & $sync; & $dma 25 ($b*$stride) 18 $offResidual $tensorBytes }
    }
    # Three-branch mean in chunks: branch 0 and 1 come back from DDR into the free C region.
    & $sync
    & $dma 18 $offMeanParameters 22 147456 16
    $chunk=[int][math]::Ceiling($tiles/2)
    for($j=0;$j*$chunk -lt $tiles;$j++){
        $chunkTiles=[math]::Min($chunk,$tiles-$j*$chunk)
        & $dma 18 $offConvOutput 25 ($j*$chunk*8192) ($chunkTiles*8192)
        & $dma 18 ($offConvOutput+$chunk*8192) 25 ($stride+$j*$chunk*8192) ($chunkTiles*8192)
        & $ptr 0 18 $offConvOutput; & $ptr 1 18 ($offConvOutput+$chunk*8192); & $ptr 2 18 ($offResidual+$j*$chunk*8192); & $ptr 3 18 $offConvOutput; & $ptr 4 18 $offMeanParameters; & $imm 5 $chunkTiles
        & $call 'body_average'; & $mark 'Average'; & $sync
        & $dma 25 ($finalOffset+$j*$chunk*8192) 18 $offConvOutput ($chunkTiles*8192)
    }
    & $dma 25 ($finalOffset+$tensorBytes) 18 $offCoefficients 18432
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
    $bodies.Add(@('body_fused',@(New-KokoroAdaInSnakeIntegerSteps)))
    if($CostProbeTurnsBody){ $bodies.Add(@('body_turns',@(New-KokoroAdaInSnakeTurnsSteps))) }
    $bodies.Add(@('body_statsacc',@(New-KokoroAdaInStatisticsAccumulateSteps)))
    $bodies.Add(@('body_coeff',@(New-KokoroAdaInIntegerCoefficientsSteps)))
    $bodies.Add(@('body_residual',@(New-KokoroResidualIntegerSteps)))
    $bodies.Add(@('body_average',@(New-KokoroBranchAverageIntegerSteps)))
    for($b=0;$b -lt 3;$b++){foreach($d in 1,3,5){$bodies.Add(@("body_conv_b${b}_d$d",@(New-KokoroHmxConvSteps -Kernel $kernels[$b] -Dilation $d -LabelPrefix "resident_b${b}_d$d")))}}
    if($CostProbePasses -gt 0){ for($b=0;$b -lt 3;$b++){foreach($d in 1,3,5){$bodies.Add(@("body_convp_b${b}_d$d",@(New-KokoroHmxConvSteps -Kernel $kernels[$b] -Dilation $d -OutputPlanes -LabelPrefix "probe_b${b}_d$d")))}} }
    foreach($pair in $bodies){$s.Add(@{Op='label';Name=$pair[0]});foreach($step in $pair[1]){$s.Add($step)}}
    if($HvxThreads -gt 1){
        # hvx_worker(r0 = its pool slot): r16 slot, r17 pool block, r18 last sequence seen, r19 zero.
        $loop=& $label; $idle=& $label; $done=& $label; $quit=& $label
        $s.Add(@{Op='label';Name='hvx_worker'})
        $s.Add(@{Op='addi';d=16;s=0;i=0}); $s.Add(@{Op='load';d=17;s=16;Offset=32}); $s.Add(@{Op='imm';d=18;i=0}); $s.Add(@{Op='imm';d=19;i=0})
        $s.Add(@{Op='imm';d=0;i=1}); $s.Add(@{Op='imm';d=5;i=0}); $s.Add(@{Op='trap0';i=0x55})
        $s.Add(@{Op='label';Name=$loop})
        $s.Add(@{Op='load';d=0;s=17;Offset=0}); $s.Add(@{Op='eq';d=0;s=0;t=18}); $s.Add(@{Op='jump-p';u=0;Label=$idle})
        $s.Add(@{Op='addi';d=18;s=0;i=0})
        $s.Add(@{Op='load';d=1;s=17;Offset=4}); $s.Add(@{Op='gtu';d=0;s=1;t=19}); $s.Add(@{Op='jump-p';u=0;Label=$quit})
        foreach($k in 0..4){ $s.Add(@{Op='load';d=$k;s=16;Offset=(4*$k)}) }
        $s.Add(@{Op='eq';d=0;s=4;t=19}); $s.Add(@{Op='jump-p';u=0;Label=$done})
        & $call 'body_fused'
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
        # body_pmu_mark: r0 = category accumulator. Snapshot the counters, then add current minus
        # previous into the category. Clobbers caller-saved r0..r15 like any call; the job keeps
        # its state in r16..r27.
        $s.Add(@{Op='label';Name='body_pmu_mark'}); $s.Add(@{Op='allocframe';Bytes=16}); $s.Add(@{Op='store';s=29;t=0;Offset=0})
        # qurt_pmu_get_pmucnt: r5 = #0; trap0(#0x63); r0 = rc, r1..r8 = PMUCNT0..7.
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
    [pscustomobject]@{Steps=$s.ToArray();Layout=[ordered]@{Frames=$Frames;Tiles=$tiles;InputBytes=$tensorBytes;WeightBytes=$weightBytes;ParameterBytes=$parameterBytes;OutputBytes=$outputBytes;WorkspaceBytes=$tensorBytes;VtcmBytes=$layout.VtcmBytes;BranchStride=$stride;FinalWorkspaceOffset=$finalOffset;CoefficientBytes=18432;CoefficientOffset=$tensorBytes;CompletedStages=19;BatchTiles=$batch;Regions=$layout.Regions}}
}
