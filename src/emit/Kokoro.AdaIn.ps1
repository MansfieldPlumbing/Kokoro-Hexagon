# Direct V73 FP32 AdaIN: full-time mean, population variance, refined inverse
# standard deviation, then style affine, in a single DSP invocation.
# Source semantics: Kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec,
# istftnet.py AdaIN1d; pinned stock instance affine is identity.
# Diagnostic ABI: geometry {T,C}, channel-major x, {gain[C],shift[C]}, y.
# All numerical work executes on DSP. Bounded input/control magnitude <=1024.
# The variance+epsilon domain is normal positive FP32, avoiding the extreme
# value fixups needed for a general-purpose sfinvsqrta library routine.
function New-KokoroAdaInSteps {
    param([ValidateRange(2, 2048)][int]$Frames=64,
          [ValidateRange(1, 128)][int]$Channels=128)
    $steps=[Collections.Generic.List[hashtable]]::new()
    $imm={param([int]$r,[uint32]$value)
        $steps.Add(@{Op='lo';x=$r;i=($value -band 65535)})
        $steps.Add(@{Op='hi';x=$r;i=($value -shr 16)})
    }
    $fp={param([int]$r,[float]$value)
        & $imm $r ([BitConverter]::SingleToUInt32Bits($value))
    }
    foreach($d in @(@(0x00020001,'open'),@(0x01000010,'success'),@(0x02030100,'adain'))) {
        & $imm 4 $d[0]
        $steps.Add(@{Op='eq';d=0;s=2;t=4});$steps.Add(@{Op='jump-p';u=0;Label=$d[1]})
    }
    $steps.Add(@{Op='imm';d=0;i=20});$steps.Add(@{Op='return'})
    $steps.Add(@{Op='label';Name='bad'})
    $steps.Add(@{Op='imm';d=0;i=14});$steps.Add(@{Op='return'})
    $steps.Add(@{Op='label';Name='domain'})
    $steps.Add(@{Op='imm';d=0;i=33});$steps.Add(@{Op='return'})
    $steps.Add(@{Op='label';Name='open'})
    $steps.Add(@{Op='imm';d=4;i=0})
    $steps.Add(@{Op='eq';d=0;s=3;t=4});$steps.Add(@{Op='jump-p';u=0;Label='bad'})
    $steps.Add(@{Op='imm';d=4;i=1});$steps.Add(@{Op='store';s=3;t=4;Offset=16})
    $steps.Add(@{Op='imm';d=4;i=0});$steps.Add(@{Op='store';s=3;t=4;Offset=20})
    $steps.Add(@{Op='label';Name='success'})
    $steps.Add(@{Op='imm';d=0;i=0});$steps.Add(@{Op='return'})
    $steps.Add(@{Op='label';Name='adain'})
    $steps.Add(@{Op='imm';d=15;i=0})
    $steps.Add(@{Op='eq';d=0;s=3;t=15});$steps.Add(@{Op='jump-p';u=0;Label='bad'})
    foreach($a in @(@(4,8),@(12,(4*$Frames*$Channels)),@(20,(8*$Channels)),@(28,(4*$Frames*$Channels)))) {
        $steps.Add(@{Op='load';d=0;s=3;Offset=$a[0]});& $imm 1 ($a[1]-1)
        $steps.Add(@{Op='gtu';d=0;s=0;t=1});$steps.Add(@{Op='jump-p';u=0;Label="length_$($a[0])"})
        $steps.Add(@{Op='imm';d=0;i=14});$steps.Add(@{Op='return'})
        $steps.Add(@{Op='label';Name="length_$($a[0])"})
    }
    foreach($a in @(@(0,7),@(8,4),@(16,5),@(24,6))) {
        $steps.Add(@{Op='load';d=$a[1];s=3;Offset=$a[0]})
        $steps.Add(@{Op='eq';d=0;s=$a[1];t=15});$steps.Add(@{Op='jump-p';u=0;Label='bad'})
        $steps.Add(@{Op='imm';d=0;i=3});$steps.Add(@{Op='and';d=0;s=$a[1];t=0})
        $steps.Add(@{Op='gtu';d=0;s=0;t=15});$steps.Add(@{Op='jump-p';u=0;Label='bad'})
    }
    foreach($dim in @(@(0,$Frames),@(4,$Channels))) {
        $steps.Add(@{Op='load';d=0;s=7;Offset=$dim[0]});& $imm 1 $dim[1]
        $steps.Add(@{Op='eq';d=0;s=0;t=1});$steps.Add(@{Op='jump-p';u=0;Label="dim_$($dim[0])"})
        $steps.Add(@{Op='imm';d=0;i=14});$steps.Add(@{Op='return'})
        $steps.Add(@{Op='label';Name="dim_$($dim[0])"})
    }
    # Validate the entire admitted domain before arithmetic. IEEE magnitude
    # bits order positive finite values; NaN/infinity fail the same test.
    $steps.Add(@{Op='label';Name='compute'})
    & $imm 12 0x7fffffff; & $fp 13 1024
    foreach($scan in @(@('input',4,($Frames*$Channels)),@('control',5,(2*$Channels)))) {
        $steps.Add(@{Op='addi';d=9;s=$scan[1];i=0});& $imm 8 $scan[2]
        $steps.Add(@{Op='label';Name="scan_$($scan[0])"})
        $steps.Add(@{Op='load';d=0;s=9;Offset=0});$steps.Add(@{Op='and';d=0;s=0;t=12})
        $steps.Add(@{Op='gtu';d=0;s=0;t=13});$steps.Add(@{Op='jump-p';u=0;Label='domain'})
        $steps.Add(@{Op='addi';d=9;s=9;i=4});$steps.Add(@{Op='addi';d=8;s=8;i=-1})
        $steps.Add(@{Op='gtu';d=0;s=8;t=15});$steps.Add(@{Op='jump-p';u=0;Label="scan_$($scan[0])"})
    }
    $steps.Add(@{Op='imm';d=7;i=$Channels})
    $steps.Add(@{Op='label';Name='channel'})
    $steps.Add(@{Op='imm';d=10;i=0}) # sum -> mean
    $steps.Add(@{Op='addi';d=9;s=4;i=0});$steps.Add(@{Op='imm';d=8;i=$Frames})
    $steps.Add(@{Op='label';Name='mean'})
    $steps.Add(@{Op='load';d=0;s=9;Offset=0});$steps.Add(@{Op='sfadd';d=10;s=10;t=0})
    $steps.Add(@{Op='addi';d=9;s=9;i=4});$steps.Add(@{Op='addi';d=8;s=8;i=-1})
    $steps.Add(@{Op='gtu';d=0;s=8;t=15});$steps.Add(@{Op='jump-p';u=0;Label='mean'})
    & $fp 12 (1.0/$Frames);$steps.Add(@{Op='sfmpy';d=10;s=10;t=12})
    $steps.Add(@{Op='imm';d=11;i=0}) # centered squares -> variance+epsilon
    $steps.Add(@{Op='addi';d=9;s=4;i=0});$steps.Add(@{Op='imm';d=8;i=$Frames})
    $steps.Add(@{Op='label';Name='variance'})
    $steps.Add(@{Op='load';d=0;s=9;Offset=0});$steps.Add(@{Op='sfsub';d=0;s=0;t=10})
    $steps.Add(@{Op='sfmpy';d=0;s=0;t=0});$steps.Add(@{Op='sfadd';d=11;s=11;t=0})
    $steps.Add(@{Op='addi';d=9;s=9;i=4});$steps.Add(@{Op='addi';d=8;s=8;i=-1})
    $steps.Add(@{Op='gtu';d=0;s=8;t=15});$steps.Add(@{Op='jump-p';u=0;Label='variance'})
    $steps.Add(@{Op='sfmpy';d=11;s=11;t=12});& $fp 0 1e-5
    $steps.Add(@{Op='sfadd';d=11;s=11;t=0})
    # PRM p.470 gives >=6.6 seed bits. Three Newton steps:
    # z <- z * (1.5 - (0.5*a*z)*z). Separate FP32 operations.
    $steps.Add(@{Op='sfinvsqrta';d=12;e=1;s=11})
    & $fp 13 0.5; & $fp 14 1.5
    for($iteration=0;$iteration -lt 3;$iteration++) {
        $steps.Add(@{Op='sfmpy';d=0;s=11;t=13});$steps.Add(@{Op='sfmpy';d=0;s=0;t=12})
        $steps.Add(@{Op='sfmpy';d=0;s=0;t=12});$steps.Add(@{Op='sfsub';d=0;s=14;t=0})
        $steps.Add(@{Op='sfmpy';d=12;s=12;t=0})
    }
    $steps.Add(@{Op='load';d=13;s=5;Offset=0})
    $steps.Add(@{Op='load';d=14;s=5;Offset=(4*$Channels)})
    $steps.Add(@{Op='imm';d=8;i=$Frames})
    $steps.Add(@{Op='label';Name='apply'})
    $steps.Add(@{Op='load';d=0;s=4;Offset=0});$steps.Add(@{Op='sfsub';d=0;s=0;t=10})
    $steps.Add(@{Op='sfmpy';d=0;s=0;t=12});$steps.Add(@{Op='sfmpy';d=0;s=0;t=13})
    $steps.Add(@{Op='sfadd';d=0;s=0;t=14});$steps.Add(@{Op='store';s=6;t=0;Offset=0})
    $steps.Add(@{Op='addi';d=4;s=4;i=4});$steps.Add(@{Op='addi';d=6;s=6;i=4})
    $steps.Add(@{Op='addi';d=8;s=8;i=-1});$steps.Add(@{Op='gtu';d=0;s=8;t=15})
    $steps.Add(@{Op='jump-p';u=0;Label='apply'})
    $steps.Add(@{Op='addi';d=5;s=5;i=4});$steps.Add(@{Op='addi';d=7;s=7;i=-1})
    $steps.Add(@{Op='gtu';d=0;s=7;t=15});$steps.Add(@{Op='jump-p';u=0;Label='channel'})
    $steps.Add(@{Op='imm';d=0;i=0});$steps.Add(@{Op='return'})
    $steps.ToArray()
}
