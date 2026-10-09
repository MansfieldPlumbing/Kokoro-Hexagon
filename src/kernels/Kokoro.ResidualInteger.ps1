#requires -Version 7.4
# Native u8 residual with offline Q16 scale reconciliation.
# r0 skip, r1 branch, r2 output, r3 {skipMultiplier,branchMultiplier,bias}, r4 tiles.
# Positive int32 multipliers; bias includes zero points and +32768 rounding.
# Caller validates int32 intermediate bounds. No channel/time rearrangement.
function New-KokoroResidualIntegerSteps {
 # Channels selects native tile size; the three reconciliation parameters are shared.
 param([ValidateSet(128,256)][int]$Channels=128,[string]$LabelPrefix='residualinteger')
 $steps=[Collections.Generic.List[hashtable]]::new()
 foreach ($kv in @(@(9,0),@(10,8),@(11,24),@(12,16),@(13,255))) { $steps.Add(@{Op='imm';d=$kv[0];i=$kv[1]}) }
 $steps.Add(@{Op='vsplat';d=3;s=13})
 $steps.Add(@{Op='vxor';d=11;s=11;t=11})
 $steps.Add(@{Op='vsplat';d=12;s=13})
 foreach ($kv in @(@(0,8),@(4,9),@(8,10))) {
  $steps.Add(@{Op='load';d=14;s=3;Offset=$kv[0]})
  $steps.Add(@{Op='vsplat';d=$kv[1];s=14})
 }
 for ($block=0;$block -lt ($Channels/32);$block++) {
  foreach ($kv in @(@(5,0),@(6,1),@(7,2))) { $steps.Add(@{Op='addi';d=$kv[0];s=$kv[1];i=($block*2048)}) }
  $steps.Add(@{Op='addi';d=8;s=4;i=0})
  $label="${LabelPrefix}_b${block}"
  $steps.Add(@{Op='label';Name=$label})
  for ($pair=0;$pair -lt 16;$pair++) {
   $steps.Add(@{Op='vload';d=0;s=5;Offset=0})
   $steps.Add(@{Op='vload';d=4;s=6;Offset=0})
   foreach ($row in 1,2) {
    $shift=if ($row -eq 1) {10} else {11}
    $steps.Add(@{Op='vlsr-uw';d=1;s=0;t=$shift})
    $steps.Add(@{Op='vand';d=1;s=1;t=3})
    $steps.Add(@{Op='vlsr-uw';d=2;s=4;t=$shift})
    $steps.Add(@{Op='vand';d=2;s=2;t=3})
    $steps.Add(@{Op='vmpyie-w-uh';d=1;s=8;t=1})
    $steps.Add(@{Op='vmpyie-w-uh';d=2;s=9;t=2})
    $steps.Add(@{Op='vadd-w';d=1;s=1;t=2})
    $steps.Add(@{Op='vadd-w';d=1;s=1;t=10})
    $steps.Add(@{Op='vasr-w';d=1;s=1;t=12})
    $steps.Add(@{Op='vmax-w';d=1;s=1;t=11})
    $steps.Add(@{Op='vmin-w';d=1;s=1;t=12})
    $steps.Add(@{Op='vasl-w';d=(12+$row);s=1;t=$shift})
   }
   $steps.Add(@{Op='vor';d=5;s=13;t=14})
   $steps.Add(@{Op='vstore';s=7;t=5;Offset=0})
   foreach ($r in 5,6,7) { $steps.Add(@{Op='addi';d=$r;s=$r;i=128}) }
  }
  foreach ($r in 5,6,7) { $steps.Add(@{Op='addi';d=$r;s=$r;i=($Channels*64-2048)}) }
  $steps.Add(@{Op='addi';d=8;s=8;i=-1})
  $steps.Add(@{Op='gtu';d=0;s=8;t=9})
  $steps.Add(@{Op='jump-p';u=0;Label=$label})
 }
 $steps.Add(@{Op='return'})
 $steps.ToArray()
}
