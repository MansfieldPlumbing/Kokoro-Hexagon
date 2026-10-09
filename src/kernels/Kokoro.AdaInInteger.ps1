#requires -Version 7.4
# Stock AdaIN1d: Kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec,
# kokoro/istftnet.py:20-31. Style affine is packed offline, group moments live.
# D=N*sum(u*u)-sum(u)^2+round(eps*N*N/sx^2); gain=A*N/sqrt(D).
# Integer square root/division use trial bits with exact unsigned 64-bit products:
# keep a candidate iff candidate^2 <= D, or candidate*divisor <= numerator.
# This first correctness implementation deliberately avoids reciprocal approximations.
# r0 moments (4 blocks, sum[32], square[32]); r1 per-channel {Aq16,Bq16,epsD:u64};
# r2 output {gainQ16[128],offsetQ16[128]}; r3 valid frame count 1..32768.
# Caller checks epsD>0, abs(Aq16)*N/root < 2^31 and all affine products fit int32.
function New-KokoroAdaInIntegerCoefficientsSteps {
    # 128/256 channels: parameters Channels*16, returned coefficients Channels*8.
    param([ValidateSet(128,256)][int]$Channels=128,[string]$LabelPrefix='adaincoeff')
    $steps=[Collections.Generic.List[hashtable]]::new()
    $steps.Add(@{Op='allocframe';Bytes=48})
    foreach ($r in 16,18,20) { $steps.Add(@{Op='store-d';s=29;t=$r;Offset=(($r-16)*4)}) }
    $steps.Add(@{Op='imm';d=16;i=0})
    # Divide r7:6 by the named positive divisor into a nonnegative 31-bit quotient.
    function Add-TrialDivision([int]$Divisor,[int]$Result,[string]$Name) {
        $steps.Add(@{Op='imm';d=$Result;i=0})
        $steps.Add(@{Op='imm';d=13;i=1})
        $steps.Add(@{Op='asl-i';d=13;s=13;i=30})
        $steps.Add(@{Op='label';Name="${Name}_bit"})
        $steps.Add(@{Op='or';d=14;s=$Result;t=13})
        $steps.Add(@{Op='mpyu-d';d=8;s=14;t=$Divisor})
        $steps.Add(@{Op='gtu-d';d=0;s=8;t=6})
        $steps.Add(@{Op='jump-p';u=0;Label="${Name}_skip"})
        $steps.Add(@{Op='addi';d=$Result;s=14;i=0})
        $steps.Add(@{Op='label';Name="${Name}_skip"})
        $steps.Add(@{Op='lsr-i';d=13;s=13;i=1})
        $steps.Add(@{Op='gtu';d=0;s=13;t=16})
        $steps.Add(@{Op='jump-p';u=0;Label="${Name}_bit"})
    }
    for ($block=0;$block -lt ($Channels/32);$block++) {
        $steps.Add(@{Op='imm';d=18;i=32})
        $channel="${LabelPrefix}_b${block}"
        $steps.Add(@{Op='label';Name=$channel})
        $steps.Add(@{Op='load';d=20;s=0;Offset=0})
        $steps.Add(@{Op='load';d=5;s=0;Offset=128})
        $steps.Add(@{Op='mpyu-d';d=6;s=5;t=3})
        $steps.Add(@{Op='mpyu-d';d=8;s=20;t=20})
        $steps.Add(@{Op='sub-d';d=6;s=6;t=8})
        $steps.Add(@{Op='load-d';d=8;s=1;Offset=8})
        $steps.Add(@{Op='add-d';d=6;s=6;t=8})
        $steps.Add(@{Op='imm';d=12;i=0})
        $steps.Add(@{Op='imm';d=13;i=1})
        $steps.Add(@{Op='asl-i';d=13;s=13;i=31})
        $steps.Add(@{Op='label';Name="${channel}_sqrt"})
        $steps.Add(@{Op='or';d=14;s=12;t=13})
        $steps.Add(@{Op='mpyu-d';d=8;s=14;t=14})
        $steps.Add(@{Op='gtu-d';d=0;s=8;t=6})
        $steps.Add(@{Op='jump-p';u=0;Label="${channel}_sqrt_skip"})
        $steps.Add(@{Op='addi';d=12;s=14;i=0})
        $steps.Add(@{Op='label';Name="${channel}_sqrt_skip"})
        $steps.Add(@{Op='lsr-i';d=13;s=13;i=1})
        $steps.Add(@{Op='gtu';d=0;s=13;t=16})
        $steps.Add(@{Op='jump-p';u=0;Label="${channel}_sqrt"})
        $steps.Add(@{Op='load';d=19;s=1;Offset=0})
        $steps.Add(@{Op='load';d=11;s=1;Offset=4})
        $steps.Add(@{Op='addi';d=10;s=19;i=0})
        $steps.Add(@{Op='gt';d=0;s=19;t=16})
        $steps.Add(@{Op='jump-p';u=0;Label="${channel}_positive"})
        $steps.Add(@{Op='sub';d=10;s=16;t=19})
        $steps.Add(@{Op='label';Name="${channel}_positive"})
        $steps.Add(@{Op='mpyu-d';d=6;s=10;t=3})
        Add-TrialDivision 12 10 "${channel}_gain"
        $steps.Add(@{Op='gt';d=0;s=19;t=16})
        $steps.Add(@{Op='jump-p';u=0;Label="${channel}_signed"})
        $steps.Add(@{Op='sub';d=10;s=16;t=10})
        $steps.Add(@{Op='label';Name="${channel}_signed"})
        $steps.Add(@{Op='imm';d=5;i=1})
        $steps.Add(@{Op='asl-i';d=5;s=5;i=16})
        $steps.Add(@{Op='mpyu-d';d=6;s=20;t=5})
        Add-TrialDivision 3 21 "${channel}_mean"
        $steps.Add(@{Op='mpy-d';d=8;s=10;t=21})
        $steps.Add(@{Op='asr-d-i';d=8;s=8;i=16})
        $steps.Add(@{Op='sub';d=11;s=11;t=8})
        $steps.Add(@{Op='store';s=2;t=10;Offset=0})
        $steps.Add(@{Op='store';s=2;t=11;Offset=($Channels*4)})
        $steps.Add(@{Op='addi';d=0;s=0;i=4})
        $steps.Add(@{Op='addi';d=1;s=1;i=16})
        $steps.Add(@{Op='addi';d=2;s=2;i=4})
        $steps.Add(@{Op='addi';d=18;s=18;i=-1})
        $steps.Add(@{Op='gtu';d=0;s=18;t=16})
        $steps.Add(@{Op='jump-p';u=0;Label=$channel})
        $steps.Add(@{Op='addi';d=0;s=0;i=128})
    }
    foreach ($r in 16,18,20) { $steps.Add(@{Op='load-d';s=29;d=$r;Offset=(($r-16)*4)}) }
    $steps.Add(@{Op='dealloc-return'})
    $steps.ToArray()
}

# r0 native u8 input, r1 native signed-Q8 halfword output, r2 gain/offset, r3 tiles.
# The two values of each native word retain their channel and time locations.
# Q8 halfwords retain both bytes of each HMX lane; no channel/time permutation.
# r16..27 are untouched. Final padded rows are diagnostic only, excluded upstream.
function New-KokoroAdaInIntegerAffineSteps {
    # Each native tile is Channels*64 bytes for either lane precision.
    param([ValidateSet(128,256)][int]$Channels=128,[string]$LabelPrefix='adainaffine')
    $steps=[Collections.Generic.List[hashtable]]::new()
    foreach ($kv in @(@(7,8),@(8,24),@(9,255),@(10,16),@(11,0),@(12,-32768),@(13,32767))) {
        $steps.Add(@{Op='imm';d=$kv[0];i=$kv[1]})
    }
    $steps.Add(@{Op='vsplat';d=3;s=9})
    $steps.Add(@{Op='vsplat';d=10;s=12})
    $steps.Add(@{Op='vsplat';d=11;s=13})
    $steps.Add(@{Op='lo';x=9;i=65535})
    $steps.Add(@{Op='hi';x=9;i=0})
    $steps.Add(@{Op='vsplat';d=12;s=9})
    for ($block=0;$block -lt ($Channels/32);$block++) {
        $steps.Add(@{Op='addi';d=6;s=2;i=($block*128)})
        $steps.Add(@{Op='vload';d=8;s=6;Offset=0})
        if($Channels -eq 256){$steps.Add(@{Op='addi';d=6;s=6;i=($Channels*4)});$steps.Add(@{Op='vload';d=9;s=6;Offset=0})}
        else{$steps.Add(@{Op='vload';d=9;s=6;Offset=512})}
        $steps.Add(@{Op='addi';d=4;s=0;i=($block*2048)})
        $steps.Add(@{Op='addi';d=5;s=1;i=($block*2048)})
        $steps.Add(@{Op='addi';d=14;s=3;i=0})
        $label="${LabelPrefix}_b${block}"
        $steps.Add(@{Op='label';Name=$label})
        for ($pair=0;$pair -lt 16;$pair++) {
            $steps.Add(@{Op='vload';d=0;s=4;Offset=0})
            $steps.Add(@{Op='vlsr-uw';d=1;s=0;t=7})
            $steps.Add(@{Op='vand';d=1;s=1;t=3})
            $steps.Add(@{Op='vlsr-uw';d=2;s=0;t=8})
            foreach ($v in 1,2) {
                $steps.Add(@{Op='vmpyie-w-uh';d=$v;s=8;t=$v})
                $steps.Add(@{Op='vadd-w';d=$v;s=$v;t=9})
                $steps.Add(@{Op='vasr-w';d=$v;s=$v;t=7})
                $steps.Add(@{Op='vmax-w';d=$v;s=$v;t=10})
                $steps.Add(@{Op='vmin-w';d=$v;s=$v;t=11})
            }
            $steps.Add(@{Op='vand';d=1;s=1;t=12})
            $steps.Add(@{Op='vasl-w';d=2;s=2;t=10})
            $steps.Add(@{Op='vor';d=0;s=1;t=2})
            $steps.Add(@{Op='vstore';t=0;s=5;Offset=0})
            $steps.Add(@{Op='addi';d=4;s=4;i=128})
            $steps.Add(@{Op='addi';d=5;s=5;i=128})
        }
        $steps.Add(@{Op='addi';d=4;s=4;i=($Channels*64-2048)})
        $steps.Add(@{Op='addi';d=5;s=5;i=($Channels*64-2048)})
        $steps.Add(@{Op='addi';d=14;s=14;i=-1})
        $steps.Add(@{Op='gtu';d=0;s=14;t=11})
        $steps.Add(@{Op='jump-p';u=0;Label=$label})
    }
    $steps.Add(@{Op='return'})
    $steps.ToArray()
}
