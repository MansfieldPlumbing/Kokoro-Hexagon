#requires -Version 7.4
# Stock generator leaky_relu, Kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec
# kokoro/istftnet.py:306,321. Native unsigned activation lanes, zero point 128.
# r0 input, r1 output, r2 {positiveMultiplierQ16,negativeMultiplierQ16,biasQ16},
# r3 tiles. Bias reconciles the scales and zero points, with +32768 rounding.
# Caller checks positive multipliers and signed int32 bounds; input/output may alias.
function New-KokoroLeakyReluIntegerSteps {
 param([ValidateSet(128,256)][int]$Channels=128,[string]$LabelPrefix='leakyinteger')
 $s=[Collections.Generic.List[hashtable]]::new()
 foreach($p in @(@(8,8),@(9,24),@(10,16),@(11,0),@(12,255),@(13,128))){$s.Add(@{Op='imm';d=$p[0];i=$p[1]})}
 $s.Add(@{Op='vsplat';d=3;s=12});$s.Add(@{Op='vsplat';d=24;s=12});$s.Add(@{Op='vxor';d=25;s=25;t=25});$s.Add(@{Op='vsplat';d=26;s=13})
 for($i=0;$i -lt 3;$i++){$s.Add(@{Op='load';d=7;s=2;Offset=(4*$i)});$s.Add(@{Op='vsplat';d=(20+$i);s=7})}
 for($block=0;$block -lt $Channels/32;$block++){
  $s.Add(@{Op='addi';d=4;s=0;i=($block*2048)});$s.Add(@{Op='addi';d=5;s=1;i=($block*2048)});$s.Add(@{Op='addi';d=6;s=3;i=0})
  $label="${LabelPrefix}_b$block";$s.Add(@{Op='label';Name=$label})
  for($pair=0;$pair -lt 16;$pair++){
   $s.Add(@{Op='vload';d=0;s=4;Offset=0})
   foreach($row in 1,2){
    $shift=if($row -eq 1){8}else{9}
    $s.Add(@{Op='vlsr-uw';d=1;s=0;t=$shift});$s.Add(@{Op='vand';d=1;s=1;t=3})
    $s.Add(@{Op='vmax-w';d=4;s=1;t=26});$s.Add(@{Op='vmin-w';d=5;s=1;t=26})
    $s.Add(@{Op='vmpyie-w-uh';d=4;s=20;t=4});$s.Add(@{Op='vmpyie-w-uh';d=5;s=21;t=5})
    $s.Add(@{Op='vadd-w';d=4;s=4;t=5});$s.Add(@{Op='vadd-w';d=4;s=4;t=22});$s.Add(@{Op='vasr-w';d=4;s=4;t=10})
    $s.Add(@{Op='vmax-w';d=4;s=4;t=25});$s.Add(@{Op='vmin-w';d=4;s=4;t=24});$s.Add(@{Op='vasl-w';d=(12+$row);s=4;t=$shift})
   }
   $s.Add(@{Op='vor';d=7;s=13;t=14});$s.Add(@{Op='vstore';s=5;t=7;Offset=0})
   $s.Add(@{Op='addi';d=4;s=4;i=128});$s.Add(@{Op='addi';d=5;s=5;i=128})
  }
  $s.Add(@{Op='addi';d=4;s=4;i=($Channels*64-2048)});$s.Add(@{Op='addi';d=5;s=5;i=($Channels*64-2048)})
  $s.Add(@{Op='addi';d=6;s=6;i=-1});$s.Add(@{Op='gtu';d=0;s=6;t=11});$s.Add(@{Op='jump-p';u=0;Label=$label})
 }
 $s.Add(@{Op='return'});$s.ToArray()
}
