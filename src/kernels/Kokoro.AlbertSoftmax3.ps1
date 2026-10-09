#requires -Version 7.4
# Direct V73 FP32 three-key ALBERT softmax approximation. Input scores must be
# max-shifted into [-64,0] and contain at least one zero. The polynomial and
# six squarings match Invoke-KokoroAlbertShiftedSoftmax3.ps1. The reciprocal
# is obtained from the pinned V73 sfinvsqrta instruction and three Newton steps.
# Diagnostic ABI: one 12-byte input buffer and one 12-byte output buffer.
function New-KokoroAlbertSoftmax3Steps {
    $steps = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int] $Register, [uint32] $Value)
        $steps.Add(@{Op='lo';x=$Register;i=($Value -band 65535)})
        $steps.Add(@{Op='hi';x=$Register;i=($Value -shr 16)})
    }
    $fp = { param([int] $Register, [float] $Value)
        & $imm $Register ([BitConverter]::SingleToUInt32Bits($Value))
    }

    foreach ($dispatch in @(@(0x00020001,'open'), @(0x01000010,'success'),
            @(0x02010100,'softmax'))) {
        & $imm 4 $dispatch[0]
        $steps.Add(@{Op='eq';d=0;s=2;t=4})
        $steps.Add(@{Op='jump-p';u=0;Label=$dispatch[1]})
    }
    $steps.Add(@{Op='imm';d=0;i=20}); $steps.Add(@{Op='return'})
    $steps.Add(@{Op='label';Name='bad'})
    $steps.Add(@{Op='imm';d=0;i=14}); $steps.Add(@{Op='return'})
    $steps.Add(@{Op='label';Name='domain'})
    $steps.Add(@{Op='imm';d=0;i=33}); $steps.Add(@{Op='return'})
    $steps.Add(@{Op='label';Name='open'})
    $steps.Add(@{Op='imm';d=4;i=0})
    $steps.Add(@{Op='eq';d=0;s=3;t=4}); $steps.Add(@{Op='jump-p';u=0;Label='bad'})
    $steps.Add(@{Op='imm';d=4;i=1}); $steps.Add(@{Op='store';s=3;t=4;Offset=16})
    $steps.Add(@{Op='imm';d=4;i=0}); $steps.Add(@{Op='store';s=3;t=4;Offset=20})
    $steps.Add(@{Op='label';Name='success'})
    $steps.Add(@{Op='imm';d=0;i=0}); $steps.Add(@{Op='return'})

    $steps.Add(@{Op='label';Name='softmax'})
    $steps.Add(@{Op='imm';d=15;i=0})
    $steps.Add(@{Op='eq';d=0;s=3;t=15}); $steps.Add(@{Op='jump-p';u=0;Label='bad'})
    foreach ($argument in @(@(4,12), @(12,12))) {
        $steps.Add(@{Op='load';d=0;s=3;Offset=$argument[0]})
        & $imm 1 ([uint32]($argument[1]-1))
        $steps.Add(@{Op='gtu';d=0;s=0;t=1})
        $steps.Add(@{Op='jump-p';u=0;Label="length_$($argument[0])"})
        $steps.Add(@{Op='imm';d=0;i=14}); $steps.Add(@{Op='return'})
        $steps.Add(@{Op='label';Name="length_$($argument[0])"})
    }
    foreach ($argument in @(@(0,4), @(8,5))) {
        $steps.Add(@{Op='load';d=$argument[1];s=3;Offset=$argument[0]})
        $steps.Add(@{Op='eq';d=0;s=$argument[1];t=15}); $steps.Add(@{Op='jump-p';u=0;Label='bad'})
        $steps.Add(@{Op='imm';d=0;i=3}); $steps.Add(@{Op='and';d=0;s=$argument[1];t=0})
        $steps.Add(@{Op='gtu';d=0;s=0;t=15}); $steps.Add(@{Op='jump-p';u=0;Label='bad'})
    }

    # Admit only finite negative values with magnitude <=64, plus signed zero,
    # and require at least one exact zero (the precomputed row maximum).
    & $imm 12 0x7fffffff
    & $imm 13 ([uint32]2147483648L)
    & $fp 14 64.0
    $steps.Add(@{Op='imm';d=9;i=0})
    foreach ($offset in 0,4,8) {
        $suffix = [string]$offset
        $steps.Add(@{Op='load';d=0;s=4;Offset=$offset})
        $steps.Add(@{Op='and';d=1;s=0;t=12})
        $steps.Add(@{Op='gtu';d=0;s=1;t=14}); $steps.Add(@{Op='jump-p';u=0;Label='domain'})
        $steps.Add(@{Op='eq';d=0;s=1;t=15}); $steps.Add(@{Op='jump-p';u=0;Label="zero_$suffix"})
        $steps.Add(@{Op='and';d=2;s=0;t=13})
        $steps.Add(@{Op='gtu';d=0;s=2;t=15}); $steps.Add(@{Op='jump-p';u=0;Label="checked_$suffix"})
        $steps.Add(@{Op='imm';d=0;i=33}); $steps.Add(@{Op='return'})
        $steps.Add(@{Op='label';Name="zero_$suffix"})
        $steps.Add(@{Op='imm';d=9;i=1})
        $steps.Add(@{Op='label';Name="checked_$suffix"})
    }
    $steps.Add(@{Op='gtu';d=0;s=9;t=15}); $steps.Add(@{Op='jump-p';u=0;Label='compute'})
    $steps.Add(@{Op='imm';d=0;i=33}); $steps.Add(@{Op='return'})

    $steps.Add(@{Op='label';Name='compute'})
    foreach ($pair in @(@(6,0), @(7,4), @(8,8))) {
        $steps.Add(@{Op='load';d=$pair[0];s=4;Offset=$pair[1]})
    }
    & $fp 12 ([float](1.0/64.0))
    foreach ($register in 6,7,8) { $steps.Add(@{Op='sfmpy';d=$register;s=$register;t=12}) }
    & $fp 12 ([float](1.0/5040.0))
    foreach ($register in 9,10,11) { $steps.Add(@{Op='addi';d=$register;s=12;i=0}) }
    foreach ($coefficient in @(
            [float](1.0/720.0), [float](1.0/120.0), [float](1.0/24.0),
            [float](1.0/6.0), [float]0.5, [float]1.0, [float]1.0)) {
        & $fp 12 $coefficient
        for ($lane = 0; $lane -lt 3; $lane++) {
            $value = 9 + $lane; $reduced = 6 + $lane
            $steps.Add(@{Op='sfmpy';d=$value;s=$value;t=$reduced})
            $steps.Add(@{Op='sfadd';d=$value;s=$value;t=12})
        }
    }
    for ($square = 0; $square -lt 6; $square++) {
        foreach ($register in 9,10,11) { $steps.Add(@{Op='sfmpy';d=$register;s=$register;t=$register}) }
    }
    $steps.Add(@{Op='sfadd';d=13;s=9;t=10})
    $steps.Add(@{Op='sfadd';d=13;s=13;t=11})
    $steps.Add(@{Op='sfinvsqrta';d=12;e=1;s=13})
    & $fp 0 0.5; & $fp 1 1.5
    for ($iteration = 0; $iteration -lt 3; $iteration++) {
        $steps.Add(@{Op='sfmpy';d=2;s=13;t=0})
        $steps.Add(@{Op='sfmpy';d=2;s=2;t=12})
        $steps.Add(@{Op='sfmpy';d=2;s=2;t=12})
        $steps.Add(@{Op='sfsub';d=2;s=1;t=2})
        $steps.Add(@{Op='sfmpy';d=12;s=12;t=2})
    }
    $steps.Add(@{Op='sfmpy';d=12;s=12;t=12})
    for ($lane = 0; $lane -lt 3; $lane++) {
        $register = 9 + $lane
        $steps.Add(@{Op='sfmpy';d=$register;s=$register;t=12})
        $steps.Add(@{Op='store';s=5;t=$register;Offset=(4*$lane)})
    }
    $steps.Add(@{Op='imm';d=0;i=0}); $steps.Add(@{Op='return'})
    $steps.ToArray()
}
