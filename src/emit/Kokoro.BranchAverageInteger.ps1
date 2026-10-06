#requires -Version 7.4
# Stock generator mean of three parallel residual branches, istftnet.py:315-320,
# Kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec. Native u8 croutons throughout.
# r0/r1/r2 inputs, r3 output, r4 {m0,m1,m2,bias}: signed Q16 words, r5 tiles.
# mi=round(si/(3*so)*65536); bias=128*65536-128*sum(mi)+32768.
# Caller validates positive multipliers and every signed int32 sum/product bound.
function New-KokoroBranchAverageIntegerSteps {
 # Native tile bytes are Channels*64; four mean parameters are shared.
 param([ValidateSet(128,256)][int]$Channels=128,[string]$LabelPrefix='branchaverage')
 $s=[Collections.Generic.List[hashtable]]::new()
 foreach($pair in @(@(11,8),@(12,24),@(13,16),@(14,255),@(15,0))){$s.Add(@{Op='imm';d=$pair[0];i=$pair[1]})}
 $s.Add(@{Op='vsplat';d=3;s=14});$s.Add(@{Op='vsplat';d=24;s=14});$s.Add(@{Op='vxor';d=25;s=25;t=25})
 for($i=0;$i -lt 4;$i++){$s.Add(@{Op='load';d=14;s=4;Offset=(4*$i)});$s.Add(@{Op='vsplat';d=(20+$i);s=14})}
 for($block=0;$block -lt ($Channels/32);$block++){
  foreach($pair in @(@(6,0),@(7,1),@(8,2),@(9,3))){$s.Add(@{Op='addi';d=$pair[0];s=$pair[1];i=($block*2048)})}
  $s.Add(@{Op='addi';d=10;s=5;i=0});$label="${LabelPrefix}_b${block}"
  $s.Add(@{Op='label';Name=$label})
  for($pair=0;$pair -lt 16;$pair++){
   foreach($p in @(@(0,6),@(4,7),@(8,8))){$s.Add(@{Op='vload';d=$p[0];s=$p[1];Offset=0})}
   for($row=0;$row -lt 2;$row++){
    foreach($p in @(@(1,0,20),@(2,4,21),@(5,8,22))){
     $s.Add(@{Op='vlsr-uw';d=$p[0];s=$p[1];t=(11+$row)});$s.Add(@{Op='vand';d=$p[0];s=$p[0];t=3});$s.Add(@{Op='vmpyie-w-uh';d=$p[0];s=$p[2];t=$p[0]})
    }
    $s.Add(@{Op='vadd-w';d=1;s=1;t=2});$s.Add(@{Op='vadd-w';d=1;s=1;t=5});$s.Add(@{Op='vadd-w';d=1;s=1;t=23})
    $s.Add(@{Op='vasr-w';d=1;s=1;t=13});$s.Add(@{Op='vmax-w';d=1;s=1;t=25});$s.Add(@{Op='vmin-w';d=1;s=1;t=24});$s.Add(@{Op='vasl-w';d=(6+$row);s=1;t=(11+$row)})
   }
   $s.Add(@{Op='vor';d=0;s=6;t=7});$s.Add(@{Op='vstore';t=0;s=9;Offset=0})
   foreach($r in 6,7,8,9){$s.Add(@{Op='addi';d=$r;s=$r;i=128})}
  }
  foreach($r in 6,7,8,9){$s.Add(@{Op='addi';d=$r;s=$r;i=($Channels*64-2048)})}
  $s.Add(@{Op='addi';d=10;s=10;i=-1});$s.Add(@{Op='gtu';d=0;s=10;t=15});$s.Add(@{Op='jump-p';u=0;Label=$label})
 }
 $s.Add(@{Op='return'});$s.ToArray()
}
