#requires -Version 7.4
# Connected resblocks.3 correctness runner, stock dfb907a02bba8152ca444717ca5d78747ccb4bec.
# Reuses the checked resource acquisition wrapper and all eight integer bodies.
# Blocking copies stage eight tiles in VTCM; complete-group HVX state stays in DDR.
# This is one synchronous proof job, before persistent dspqueue/DMA integration.
# Method 2: config {tiles}, input native croutons, six W8 tensors, six 8192-byte
# parameter records; output telemetry + aligned five-buffer workspace + six coefficients.
function New-KokoroResBlockRunSteps {
 param([ValidateRange(2,32768)][int]$Frames=7801,[ValidateSet(3,7,11)][int]$Kernel=3,[switch]$ProfileBreakdown,[switch]$BypassAdaInCoefficients,[switch]$BypassStatisticsAndCoefficients,[switch]$BypassHmxCompute)
 foreach($file in 'Kokoro.HmxConv.ps1','Kokoro.HmxConvRun.ps1','Kokoro.AdaInStatistics.ps1','Kokoro.AdaInInteger.ps1','Kokoro.SnakeInteger.ps1','Kokoro.ResidualInteger.ps1') { . (Join-Path $PSScriptRoot $file) }
 $tiles=[int][math]::Ceiling($Frames/32); $bytes=$tiles*8192
 $outputBytes=192+5*$bytes+6144
 $base=New-KokoroHmxConvRunSteps -Channels 128 -Kernel $Kernel -Dilation 1 -Tiles 8
 $weightBytes=16384*$Kernel; $paramOff=131072+[int]([math]::Ceiling($weightBytes/65536)*65536); $outOff=$paramOff+65536
 $s=[Collections.Generic.List[hashtable]]::new()
 $imm={param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL);$s.Add(@{Op='lo';x=$r;i=($u -band 65535)});$s.Add(@{Op='hi';x=$r;i=($u -shr 16)})}
 $ptr={param([int]$r,[int]$baseReg,[long]$offset) & $imm $r $offset;$s.Add(@{Op='add';d=$r;s=$baseReg;t=$r})}
 $copy={param([int]$dest,[long]$destOff,[int]$source,[long]$sourceOff,[int]$length)
  & $ptr 0 $dest $destOff; & $ptr 1 $source $sourceOff; & $imm 2 $length
  $s.Add(@{Op='got-call';Import='memcpy';d=14})
 }
 $localCalls=[Collections.Generic.List[object]]::new()
 $call={param([string]$label)
  $pc=@{Op='add-pc';d=14;i=0};$low=@{Op='lo';x=15;i=0};$high=@{Op='hi';x=15;i=0}
  $s.Add($pc);$s.Add($low);$s.Add($high);$s.Add(@{Op='add';d=14;s=14;t=15});$s.Add(@{Op='callr';s=14})
  $localCalls.Add(@{pc=$pc;low=$low;high=$high;label=$label})
 }
 # r25 is aligned workspace; r18 VTCM; r20 input; r21 weights; r22 params; r23 telemetry.
 $job={
  $s.Add(@{Op='addi';d=25;s=23;i=191}); & $imm 0 -128
  $s.Add(@{Op='and';d=25;s=25;t=0});$s.Add(@{Op='sub';d=0;s=25;t=23});$s.Add(@{Op='store';s=23;t=0;Offset=40})
  if($ProfileBreakdown) {
   $s.Add(@{Op='imm';d=0;i=0});$s.Add(@{Op='imm';d=1;i=0})
   for($off=48;$off -le 120;$off+=8){$s.Add(@{Op='store-d';s=23;t=0;Offset=$off})}
  }
  & $copy 25 0 20 0 $bytes
  $s.Add(@{Op='hwticks';d=26})
  for($stage=0;$stage -lt 6;$stage++) {
   if($stage%2 -eq 0) {
    if($ProfileBreakdown){$s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='store-d';s=29;t=6;Offset=24})}
    & $copy 25 (4*$bytes) 25 0 $bytes
    if($ProfileBreakdown){$s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='load-d';d=8;s=29;Offset=24});$s.Add(@{Op='sub-d';d=6;s=6;t=8});$s.Add(@{Op='load-d';d=0;s=23;Offset=120});$s.Add(@{Op='add-d';d=0;s=0;t=6});$s.Add(@{Op='store-d';s=23;t=0;Offset=120})}
   }
   if($ProfileBreakdown){$s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='store-d';s=29;t=6;Offset=24})}
   & $copy 18 $paramOff 22 ($stage*8192) 8192
   if($ProfileBreakdown){$s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='load-d';d=8;s=29;Offset=24});$s.Add(@{Op='sub-d';d=6;s=6;t=8});$s.Add(@{Op='load-d';d=0;s=23;Offset=80});$s.Add(@{Op='add-d';d=0;s=0;t=6});$s.Add(@{Op='store-d';s=23;t=0;Offset=80})}
   # Padding odd bytes must be zero for moments, including after residuals.
   # Clear complete 32-bit lanes in padded rows; the valid rows are unchanged.
   for($t=$Frames;$t -lt $tiles*32;$t++) {
    for($block=0;$block -lt 4;$block++) {
     $lane=($tiles-1)*8192+$block*2048+[int][math]::Floor(($t%32)/2)*128+($t%2)*2
     # Other time row shares each word, so use a mask preserving that row.
     & $ptr 4 25 $lane
     & $imm 6 $(if($t%2) {0x0000ffffL} else {0xffff0000L})
     # Base address must be word aligned.
     if($t%2) {$s.Add(@{Op='addi';d=4;s=4;i=-2})}
     $s.Add(@{Op='imm';d=5;i=32});$s.Add(@{Op='imm';d=7;i=0})
     $label="mask_${stage}_${t}_${block}"
     $s.Add(@{Op='label';Name=$label});$s.Add(@{Op='load';d=0;s=4;Offset=0});$s.Add(@{Op='and';d=0;s=0;t=6});$s.Add(@{Op='store';s=4;t=0;Offset=0})
     $s.Add(@{Op='addi';d=4;s=4;i=4});$s.Add(@{Op='addi';d=5;s=5;i=-1});$s.Add(@{Op='gtu';d=0;s=5;t=7});$s.Add(@{Op='jump-p';u=0;Label=$label})
    }
   }
   if(-not $BypassStatisticsAndCoefficients) {
    if($ProfileBreakdown){$s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='store-d';s=29;t=6;Offset=24})}
    & $ptr 0 25 0; & $ptr 1 18 $outOff; & $imm 2 $tiles; & $call 'body_stats'
    if($ProfileBreakdown){$s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='load-d';d=8;s=29;Offset=24});$s.Add(@{Op='sub-d';d=6;s=6;t=8});$s.Add(@{Op='load-d';d=0;s=23;Offset=48});$s.Add(@{Op='add-d';d=0;s=0;t=6});$s.Add(@{Op='store-d';s=23;t=0;Offset=48})}
   }
   if(-not $BypassStatisticsAndCoefficients -and -not $BypassAdaInCoefficients) {
    if($ProfileBreakdown){$s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='store-d';s=29;t=6;Offset=24})}
    & $ptr 0 18 $outOff; & $ptr 1 18 $paramOff; & $ptr 2 25 (5*$bytes+$stage*1024); & $imm 3 $Frames; & $call 'body_coeff'
    if($ProfileBreakdown){$s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='load-d';d=8;s=29;Offset=24});$s.Add(@{Op='sub-d';d=6;s=6;t=8});$s.Add(@{Op='load-d';d=0;s=23;Offset=56});$s.Add(@{Op='add-d';d=0;s=0;t=6});$s.Add(@{Op='store-d';s=23;t=0;Offset=56})}
   }
   $s.Add(@{Op='syncht'})
   if($ProfileBreakdown){$s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='store-d';s=29;t=6;Offset=24})}
   & $ptr 0 25 0; & $ptr 1 25 $bytes; & $ptr 2 25 (5*$bytes+$stage*1024); & $imm 3 $tiles; & $call 'body_affine'
   if($ProfileBreakdown){$s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='load-d';d=8;s=29;Offset=24});$s.Add(@{Op='sub-d';d=6;s=6;t=8});$s.Add(@{Op='load-d';d=0;s=23;Offset=64});$s.Add(@{Op='add-d';d=0;s=0;t=6});$s.Add(@{Op='store-d';s=23;t=0;Offset=64})}
   if($ProfileBreakdown){$s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='store-d';s=29;t=6;Offset=24})}
   & $ptr 0 25 $bytes; & $ptr 1 25 (2*$bytes); & $ptr 2 18 ($paramOff+2048); & $imm 3 $tiles; & $call 'body_snake'
   if($ProfileBreakdown){$s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='load-d';d=8;s=29;Offset=24});$s.Add(@{Op='sub-d';d=6;s=6;t=8});$s.Add(@{Op='load-d';d=0;s=23;Offset=72});$s.Add(@{Op='add-d';d=0;s=0;t=6});$s.Add(@{Op='store-d';s=23;t=0;Offset=72})}
   $s.Add(@{Op='syncht'})
   if($ProfileBreakdown){$s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='store-d';s=29;t=6;Offset=24})}
   & $copy 18 131072 21 ($stage*$weightBytes) $weightBytes
   if($ProfileBreakdown){$s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='load-d';d=8;s=29;Offset=24});$s.Add(@{Op='sub-d';d=6;s=6;t=8});$s.Add(@{Op='load-d';d=0;s=23;Offset=88});$s.Add(@{Op='add-d';d=0;s=0;t=6});$s.Add(@{Op='store-d';s=23;t=0;Offset=88})}
   # Unroll time batches in the orchestration only. Each body retains its own tile loop.
   for($start=0;$start -lt $tiles;$start+=8) {
    $count=[math]::Min(8,$tiles-$start)
    if(-not $BypassHmxCompute) {
     if($ProfileBreakdown){$s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='store-d';s=29;t=6;Offset=24})}
     # Initialize halo and final padding with zero point 128 in every odd byte.
     & $ptr 4 18 0; & $imm 5 (($count+2)*8192/4); & $imm 6 0x80008000L; $s.Add(@{Op='imm';d=7;i=0})
     $label="halo_${stage}_${start}"
     $s.Add(@{Op='label';Name=$label});$s.Add(@{Op='store';s=4;t=6;Offset=0});$s.Add(@{Op='addi';d=4;s=4;i=4});$s.Add(@{Op='addi';d=5;s=5;i=-1});$s.Add(@{Op='gtu';d=0;s=5;t=7});$s.Add(@{Op='jump-p';u=0;Label=$label})
     $first=[math]::Max(0,$start-1);$last=[math]::Min($tiles,$start+$count+1)
     & $copy 18 (($first-$start+1)*8192) 25 (2*$bytes+$first*8192) (($last-$first)*8192)
     # Last partial tile was computed by Snake; overwrite invalid input rows with zp128.
     if($last -eq $tiles -and $Frames%32) {
      for($t=$Frames%32;$t -lt 32;$t++) {
       for($block=0;$block -lt 4;$block++) {
        $lane=($tiles-$start)*8192+$block*2048+[int][math]::Floor($t/2)*128
        & $ptr 4 18 $lane; & $imm 6 $(if($t%2){0x0000ffffL}else{0xffff0000L}); & $imm 8 $(if($t%2){0x80000000L}else{0x00008000L})
        $s.Add(@{Op='imm';d=5;i=32});$s.Add(@{Op='imm';d=7;i=0});$label="edge_${stage}_${start}_${t}_${block}"
        $s.Add(@{Op='label';Name=$label});$s.Add(@{Op='load';d=0;s=4;Offset=0});$s.Add(@{Op='and';d=0;s=0;t=6});$s.Add(@{Op='or';d=0;s=0;t=8});$s.Add(@{Op='store';s=4;t=0;Offset=0});$s.Add(@{Op='addi';d=4;s=4;i=4});$s.Add(@{Op='addi';d=5;s=5;i=-1});$s.Add(@{Op='gtu';d=0;s=5;t=7});$s.Add(@{Op='jump-p';u=0;Label=$label})
       }
      }
     }
     if($ProfileBreakdown){$s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='load-d';d=8;s=29;Offset=24});$s.Add(@{Op='sub-d';d=6;s=6;t=8});$s.Add(@{Op='load-d';d=0;s=23;Offset=96});$s.Add(@{Op='add-d';d=0;s=0;t=6});$s.Add(@{Op='store-d';s=23;t=0;Offset=96})}
     if($ProfileBreakdown){$s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='store-d';s=29;t=6;Offset=24})}
     & $ptr 0 18 8192; & $ptr 1 18 131072; & $ptr 2 18 $outOff; & $ptr 3 18 ($paramOff+4096); & $imm 4 $count
     & $call $(if($stage -eq 2){'body_conv3'}elseif($stage -eq 4){'body_conv5'}else{'body_conv1'})
     if($ProfileBreakdown){$s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='load-d';d=8;s=29;Offset=24});$s.Add(@{Op='sub-d';d=6;s=6;t=8});$s.Add(@{Op='load-d';d=0;s=23;Offset=104});$s.Add(@{Op='add-d';d=0;s=0;t=6});$s.Add(@{Op='store-d';s=23;t=0;Offset=104})}
     $s.Add(@{Op='syncht'})
     if($ProfileBreakdown){$s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='store-d';s=29;t=6;Offset=24})}
     & $copy 25 (3*$bytes+$start*8192) 18 $outOff ($count*8192)
     if($ProfileBreakdown){$s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='load-d';d=8;s=29;Offset=24});$s.Add(@{Op='sub-d';d=6;s=6;t=8});$s.Add(@{Op='load-d';d=0;s=23;Offset=112});$s.Add(@{Op='add-d';d=0;s=0;t=6});$s.Add(@{Op='store-d';s=23;t=0;Offset=112})}
    }
   }
   if($stage%2) {
    if($ProfileBreakdown){$s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='store-d';s=29;t=6;Offset=24})}
    & $ptr 0 25 (4*$bytes); & $ptr 1 25 (3*$bytes); & $ptr 2 25 0; & $ptr 3 18 ($paramOff+5120); & $imm 4 $tiles; & $call 'body_residual'
    if($ProfileBreakdown){$s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='load-d';d=8;s=29;Offset=24});$s.Add(@{Op='sub-d';d=6;s=6;t=8});$s.Add(@{Op='load-d';d=0;s=23;Offset=120});$s.Add(@{Op='add-d';d=0;s=0;t=6});$s.Add(@{Op='store-d';s=23;t=0;Offset=120})}
   } else {
    if($ProfileBreakdown){$s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='store-d';s=29;t=6;Offset=24})}
    & $copy 25 0 25 (3*$bytes) $bytes
    if($ProfileBreakdown){$s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='load-d';d=8;s=29;Offset=24});$s.Add(@{Op='sub-d';d=6;s=6;t=8});$s.Add(@{Op='load-d';d=0;s=23;Offset=120});$s.Add(@{Op='add-d';d=0;s=0;t=6});$s.Add(@{Op='store-d';s=23;t=0;Offset=120})}
   }
   $s.Add(@{Op='syncht'});$s.Add(@{Op='imm';d=0;i=($stage+1)});$s.Add(@{Op='store';s=23;t=0;Offset=44})
  }
  $s.Add(@{Op='hwticks';d=0});$s.Add(@{Op='store-d';s=23;t=26;Offset=0});$s.Add(@{Op='store-d';s=23;t=0;Offset=8})
 }
 # Reuse the exact power/resource/lock lifecycle, replacing only its single-conv job.
 $baseSteps=@($base.Steps);$begin=-1;$end=-1
 for($i=0;$i -lt $baseSteps.Count;$i++) {
  if($baseSteps[$i].Op -eq 'hwticks' -and $baseSteps[$i].d -eq 26) {$begin=$i}
  if($begin -ge 0 -and $baseSteps[$i].Op -eq 'imm' -and $baseSteps[$i].d -eq 13 -and $baseSteps[$i].i -eq 6) {$end=$i;break}
 }
 if($begin -lt 0 -or $end -lt $begin) {throw 'Resource wrapper job anchors changed'}
 # Do not copy its single-conv operands or output. New job stages them explicitly.
 $stage4=-1;$stage3=-1;$stage7=-1
 for($i=0;$i -lt $baseSteps.Count;$i++) {if($baseSteps[$i].Op -eq 'imm' -and $baseSteps[$i].d -eq 13) {switch($baseSteps[$i].i){3{$stage3=$i}4{$stage4=$i}7{$stage7=$i}}}}
 $minimum=@(4,$bytes,(6*$weightBytes),(6*8192),$outputBytes)
 for($i=0;$i -lt $baseSteps.Count;$i++) {
  if($i -eq $begin) { & $call 'connected_job'; $i=$end-1;continue }
  if($i -ge $stage3+2 -and $i -lt $stage4) {continue}
  # Skip the output memcpy following qurt_hvx_unlock.
  if($baseSteps[$i].Op -eq 'got-call' -and $baseSteps[$i].Import -eq 'qurt_hvx_unlock') {
   $s.Add($baseSteps[$i]);$i=$stage7-1;continue
  }
  $step=$baseSteps[$i].Clone()
  if($step.Op -eq 'lo' -and $step.x -eq 1 -and $i -ge 2 -and $baseSteps[$i-1].Op -eq 'load' -and $baseSteps[$i-1].s -eq 3) {
   $a=[int](($baseSteps[$i-1].Offset-4)/8);$v=$minimum[$a]-1;$step.i=$v -band 65535;$baseSteps[$i+1]=$baseSteps[$i+1].Clone();$baseSteps[$i+1].i=$v -shr 16
  }
  if($step.Op -eq 'imm' -and $step.d -eq 1 -and $step.i -eq 8) {$step.i=$tiles}
  $s.Add($step)
 }
 $s.Add(@{Op='label';Name='connected_job'});$s.Add(@{Op='allocframe';Bytes=$(if($ProfileBreakdown){32}else{8})}); & $job; $s.Add(@{Op='dealloc-return'})
 foreach($pair in @(
  @('body_stats',@(New-KokoroAdaInStatisticsSteps)),@('body_coeff',@(New-KokoroAdaInIntegerCoefficientsSteps)),
  @('body_affine',@(New-KokoroAdaInIntegerAffineSteps)),@('body_snake',@(New-KokoroSnakeIntegerSteps)),@('body_residual',@(New-KokoroResidualIntegerSteps)),
  @('body_conv1',@(New-KokoroHmxConvSteps -Kernel $Kernel -Dilation 1 -LabelPrefix 'connected_c1')),
  @('body_conv3',@(New-KokoroHmxConvSteps -Kernel $Kernel -Dilation 3 -LabelPrefix 'connected_c3')),
  @('body_conv5',@(New-KokoroHmxConvSteps -Kernel $Kernel -Dilation 5 -LabelPrefix 'connected_c5')))) {
  $s.Add(@{Op='label';Name=$pair[0]});foreach($step in $pair[1]) {$s.Add($step)}
 }
 # Resolve internal PC-relative calls using already-validated add(pc), lo/hi, add, callr.
 $labels=@{};$pcs=[Collections.Generic.Dictionary[object,long]]::new();$pc=0L;$isa=Get-InstructionSet
 foreach($step in $s) {if($step.Op -eq 'label'){$labels[$step.Name]=$pc};$pcs[$step]=$pc;$pc+=& $isa.Length $step}
 foreach($c in $localCalls) {$delta=[uint32]($labels[$c.label]-$pcs[$c.pc]);$c.low.i=$delta -band 65535;$c.high.i=$delta -shr 16}
 [pscustomobject]@{Steps=$s.ToArray();Layout=[ordered]@{Frames=$Frames;Tiles=$tiles;InputBytes=$bytes;Kernel=$Kernel;WeightBytes=(6*$weightBytes);ParameterBytes=49152;OutputBytes=$outputBytes;WorkspaceBytes=$bytes;VtcmBytes=$base.Layout.VtcmBytes}}
}
