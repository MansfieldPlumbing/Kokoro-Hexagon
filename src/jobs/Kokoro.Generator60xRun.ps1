#requires -Version 7.4
# Stock generator resblocks.3/4/5 and their three-way mean.
# Source: hexgrad/kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec,
# istftnet.py Generator.forward. One correctness job; blocking staging.
function New-KokoroGenerator60xRunSteps {
 param([ValidateRange(2,32768)][int]$Frames=7801,[switch]$ProfileBreakdown,[switch]$BypassAdaInCoefficients,[switch]$BypassStatisticsAndCoefficients,[switch]$BypassHmxCompute)
 . (Join-Path $PSScriptRoot 'Kokoro.ResBlockRun.ps1')
 . (Join-Path $PSScriptRoot '../kernels/Kokoro.BranchAverageInteger.ps1')
 $blocks=@(3,7,11|ForEach-Object {New-KokoroResBlockRunSteps -Frames $Frames -Kernel $_ -ProfileBreakdown:$ProfileBreakdown -BypassAdaInCoefficients:$BypassAdaInCoefficients -BypassStatisticsAndCoefficients:$BypassStatisticsAndCoefficients -BypassHmxCompute:$BypassHmxCompute})
 $bytes=$blocks[0].Layout.InputBytes
 $stride=[int]([math]::Ceiling($blocks[0].Layout.OutputBytes/128)*128)
 $finalOffset=3*$stride
 $outputBytes=192+$finalOffset+$bytes+18432
 $weights=@(0,294912,983040);$weightBytes=2064384;$parameterBytes=147472
 $s=[Collections.Generic.List[hashtable]]::new()
 $calls=[Collections.Generic.List[object]]::new()
 $imm={param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL);$s.Add(@{Op='lo';x=$r;i=($u -band 65535)});$s.Add(@{Op='hi';x=$r;i=($u -shr 16)})}
 $ptr={param([int]$r,[int]$baseReg,[long]$offset)
  # Preserve the base when the destination is the same scalar register.
  $offsetReg=if($r -eq $baseReg){15}else{$r}
  & $imm $offsetReg $offset;$s.Add(@{Op='add';d=$r;s=$baseReg;t=$offsetReg})
 }
 $call={param([string]$label) $pc=@{Op='add-pc';d=14;i=0};$lo=@{Op='lo';x=15;i=0};$hi=@{Op='hi';x=15;i=0};$s.Add($pc);$s.Add($lo);$s.Add($hi);$s.Add(@{Op='add';d=14;s=14;t=15});$s.Add(@{Op='callr';s=14});$calls.Add(@{pc=$pc;low=$lo;high=$hi;label=$label})}
 $copy={param([int]$dest,[long]$destOff,[int]$source,[long]$sourceOff,[int]$length) & $ptr 0 $dest $destOff;& $ptr 1 $source $sourceOff;& $imm 2 $length;$s.Add(@{Op='got-call';Import='memcpy';d=14})}
 # Preserve the largest checked resource wrapper, including its existing call
 # target. Its connected_job starts at the same PC after admission sizes change.
 $base=@($blocks[2].Steps);$start=-1
 for($i=0;$i -lt $base.Count;$i++){if($base[$i].Op -eq 'label' -and $base[$i].Name -eq 'connected_job'){$start=$i;break}}
 if($start -lt 0){throw 'Connected wrapper anchor changed'}
 $minimum=@(4,$bytes,$weightBytes,$parameterBytes,$outputBytes)
 for($i=0;$i -lt $start;$i++){
  $step=$base[$i].Clone()
  if($step.Op -eq 'lo' -and $step.x -eq 1 -and $i -ge 2 -and $base[$i-1].Op -eq 'load' -and $base[$i-1].s -eq 3){$a=[int](($base[$i-1].Offset-4)/8);$v=$minimum[$a]-1;$step.i=$v -band 65535;$base[$i+1]=$base[$i+1].Clone();$base[$i+1].i=$v -shr 16}
  $s.Add($step)
 }
 $s.Add(@{Op='label';Name='connected_job'});$s.Add(@{Op='allocframe';Bytes=64})
 foreach($p in @(@(21,0),@(22,4),@(23,8))){$s.Add(@{Op='store';s=29;t=$p[0];Offset=$p[1]})}
 $s.Add(@{Op='hwticks';d=26});$s.Add(@{Op='store-d';s=29;t=26;Offset=16})
 for($b=0;$b -lt 3;$b++){
  foreach($p in @(@(21,0),@(22,4),@(23,8))){$s.Add(@{Op='load';d=$p[0];s=29;Offset=$p[1]})}
  & $ptr 21 21 $weights[$b];& $ptr 22 22 ($b*49152);& $ptr 23 23 ($b*$stride)
  & $call "branch${b}_connected_job"
 }
 $s.Add(@{Op='load';d=23;s=29;Offset=8});$s.Add(@{Op='load';d=22;s=29;Offset=4})
 $s.Add(@{Op='addi';d=25;s=23;i=191});& $imm 0 -128;$s.Add(@{Op='and';d=25;s=25;t=0})
 # Copy the mean parameters into aligned VTCM after all contractions finish.
 if($ProfileBreakdown) { $s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='store-d';s=29;t=6;Offset=24}) }
 & $copy 18 327680 22 147456 16
 if($ProfileBreakdown) {
  $s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='load-d';d=8;s=29;Offset=24});$s.Add(@{Op='sub-d';d=6;s=6;t=8})
  & $ptr 4 23 $finalOffset; $s.Add(@{Op='store-d';s=4;t=6;Offset=0})
 }
 if($ProfileBreakdown) { $s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='store-d';s=29;t=6;Offset=24}) }
 & $ptr 0 25 0;& $ptr 1 25 $stride;& $ptr 2 25 (2*$stride);& $ptr 3 25 $finalOffset;& $ptr 4 18 327680;& $imm 5 $blocks[0].Layout.Tiles
 & $call 'body_average';$s.Add(@{Op='syncht'})
 if($ProfileBreakdown) {
  $s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='load-d';d=8;s=29;Offset=24});$s.Add(@{Op='sub-d';d=6;s=6;t=8})
  & $ptr 4 23 $finalOffset; $s.Add(@{Op='store-d';s=4;t=6;Offset=8})
 }
 if($ProfileBreakdown) { $s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='store-d';s=29;t=6;Offset=24}) }
 for($b=0;$b -lt 3;$b++){& $copy 25 ($finalOffset+$bytes+$b*6144) 25 ($b*$stride+5*$bytes) 6144}
 if($ProfileBreakdown) {
  $s.Add(@{Op='hwticks';d=6});$s.Add(@{Op='load-d';d=8;s=29;Offset=24});$s.Add(@{Op='sub-d';d=6;s=6;t=8})
  & $ptr 4 23 $finalOffset; $s.Add(@{Op='store-d';s=4;t=6;Offset=24})
 }
 $s.Add(@{Op='hwticks';d=0});$s.Add(@{Op='load-d';d=26;s=29;Offset=16});$s.Add(@{Op='store-d';s=23;t=26;Offset=0});$s.Add(@{Op='store-d';s=23;t=0;Offset=8})
 $s.Add(@{Op='sub';d=0;s=25;t=23});& $imm 1 $finalOffset;$s.Add(@{Op='add';d=0;s=0;t=1});$s.Add(@{Op='store';s=23;t=0;Offset=40})
 $s.Add(@{Op='imm';d=0;i=19});$s.Add(@{Op='store';s=23;t=0;Offset=44});$s.Add(@{Op='dealloc-return'})
 # Translate each intact job/body segment. Local PC-relative call deltas stay
 # unchanged because all its instructions and targets move by one constant.
 for($b=0;$b -lt 3;$b++){
  $segment=@($blocks[$b].Steps);$begin=-1
  for($i=0;$i -lt $segment.Count;$i++){if($segment[$i].Op -eq 'label' -and $segment[$i].Name -eq 'connected_job'){$begin=$i;break}}
  if($begin -lt 0){throw 'Missing branch job'}
  for($i=$begin;$i -lt $segment.Count;$i++){$step=$segment[$i].Clone();if($step.Op -eq 'label'){$step.Name="branch${b}_$($step.Name)"};if($step.ContainsKey('Label')){$step.Label="branch${b}_$($step.Label)"};$s.Add($step)}
 }
 $s.Add(@{Op='label';Name='body_average'});foreach($step in @(New-KokoroBranchAverageIntegerSteps)){$s.Add($step)}
 $labels=@{};$pcs=[Collections.Generic.Dictionary[object,long]]::new();$pc=0L;$isa=Get-InstructionSet
 foreach($step in $s){if($step.Op -eq 'label'){$labels[$step.Name]=$pc};$pcs[$step]=$pc;$pc+=& $isa.Length $step}
 foreach($c in $calls){$delta=[uint32]($labels[$c.label]-$pcs[$c.pc]);$c.low.i=$delta -band 65535;$c.high.i=$delta -shr 16}
 [pscustomobject]@{Steps=$s.ToArray();Layout=[ordered]@{Frames=$Frames;Tiles=$blocks[0].Layout.Tiles;InputBytes=$bytes;WeightBytes=$weightBytes;ParameterBytes=$parameterBytes;OutputBytes=$outputBytes;WorkspaceBytes=$bytes;VtcmBytes=$blocks[2].Layout.VtcmBytes;BranchStride=$stride;FinalWorkspaceOffset=$finalOffset;CoefficientBytes=18432;CoefficientOffset=$bytes;CompletedStages=19}}
}
