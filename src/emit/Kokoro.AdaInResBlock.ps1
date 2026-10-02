# One complete stock generator.resblocks.3 region, three residual passes.
# PowerShell emission only; one DSP call owns all six normalization, Snake,
# convolution stages and three residual adds. No host intermediate tensors.
# Stock topology: Kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec istftnet.py.
# Snake sine uses range reduction and a degree-17 odd Taylor polynomial;
# this declared numerical approximation must pass the stock consumer gate.
function New-KokoroAdaInResBlockSteps {
    param([ValidateRange(2,256)][int]$Frames=64,[switch]$VectorConvolution)
    $channels=128;$tensorBytes=4*128*$Frames
    $haloBytes=4*128*($Frames+10)
    $scratchBytes=2*$tensorBytes+$haloBytes
    $stageBytes=(4*128+3*128*128+128)*4
    $weightBytes=6*$stageBytes
    $steps=[Collections.Generic.List[hashtable]]::new()
    $imm={param([int]$r,[uint32]$value)
        $steps.Add(@{Op='lo';x=$r;i=($value -band 65535)})
        $steps.Add(@{Op='hi';x=$r;i=($value -shr 16)})
    }
    $fp={param([int]$r,[float]$value)& $imm $r ([BitConverter]::SingleToUInt32Bits($value))}
    $ptr={param([int]$r,[int]$argOffset,[int]$byteOffset=0)
        $steps.Add(@{Op='load';d=$r;s=3;Offset=$argOffset})
        if($byteOffset){& $imm 0 $byteOffset;$steps.Add(@{Op='add';d=$r;s=$r;t=0})}
    }
    foreach($d in @(@(0x00020001,'open'),@(0x01000010,'success'),@(0x02030200,'block'))){
        & $imm 4 $d[0];$steps.Add(@{Op='eq';d=0;s=2;t=4});$steps.Add(@{Op='jump-p';u=0;Label=$d[1]})
    }
    $steps.Add(@{Op='imm';d=0;i=20});$steps.Add(@{Op='return'})
    foreach($failure in @(@('bad',14),@('domain',33))){
        $steps.Add(@{Op='label';Name=$failure[0]});$steps.Add(@{Op='imm';d=0;i=$failure[1]});$steps.Add(@{Op='return'})
    }
    $steps.Add(@{Op='label';Name='open'});$steps.Add(@{Op='imm';d=4;i=0})
    $steps.Add(@{Op='eq';d=0;s=3;t=4});$steps.Add(@{Op='jump-p';u=0;Label='bad'})
    $steps.Add(@{Op='imm';d=4;i=1});$steps.Add(@{Op='store';s=3;t=4;Offset=16})
    $steps.Add(@{Op='imm';d=4;i=0});$steps.Add(@{Op='store';s=3;t=4;Offset=20})
    $steps.Add(@{Op='label';Name='success'});$steps.Add(@{Op='imm';d=0;i=0});$steps.Add(@{Op='return'})
    $steps.Add(@{Op='label';Name='block'});$steps.Add(@{Op='imm';d=15;i=0})
    $steps.Add(@{Op='eq';d=0;s=3;t=15});$steps.Add(@{Op='jump-p';u=0;Label='bad'})
    foreach($a in @(@(4,8),@(12,$tensorBytes),@(20,$weightBytes),@(28,$scratchBytes),@(36,$tensorBytes))){
        $steps.Add(@{Op='load';d=0;s=3;Offset=$a[0]});& $imm 1 ($a[1]-1)
        $steps.Add(@{Op='gtu';d=0;s=0;t=1});$steps.Add(@{Op='jump-p';u=0;Label="length_$($a[0])"})
        $steps.Add(@{Op='imm';d=0;i=14});$steps.Add(@{Op='return'})
        $steps.Add(@{Op='label';Name="length_$($a[0])"})
    }
    foreach($a in @(0,8,16,24,32)){
        $steps.Add(@{Op='load';d=0;s=3;Offset=$a})
        $steps.Add(@{Op='eq';d=0;s=0;t=15});$steps.Add(@{Op='jump-p';u=0;Label='bad'})
        $steps.Add(@{Op='imm';d=1;i=3});$steps.Add(@{Op='and';d=0;s=0;t=1})
        $steps.Add(@{Op='gtu';d=0;s=0;t=15});$steps.Add(@{Op='jump-p';u=0;Label='bad'})
    }
    if($VectorConvolution){
        # KIO weights and both temporary tensors have 128-byte-aligned offsets.
        # Reject unaligned bases instead of relying on vmem address rounding.
        foreach($a in @(16,24)){
            $steps.Add(@{Op='load';d=0;s=3;Offset=$a});$steps.Add(@{Op='imm';d=1;i=127})
            $steps.Add(@{Op='and';d=0;s=0;t=1});$steps.Add(@{Op='gtu';d=0;s=0;t=15})
            $steps.Add(@{Op='jump-p';u=0;Label='bad'})
        }
    }
    & $ptr 7 0
    foreach($dim in @(@(0,$Frames),@(4,128))){
        $steps.Add(@{Op='load';d=0;s=7;Offset=$dim[0]});& $imm 1 $dim[1]
        $steps.Add(@{Op='eq';d=0;s=0;t=1});$steps.Add(@{Op='jump-p';u=0;Label="dim_$($dim[0])"})
        $steps.Add(@{Op='imm';d=0;i=14});$steps.Add(@{Op='return'})
        $steps.Add(@{Op='label';Name="dim_$($dim[0])"})
    }
    if($VectorConvolution){
        # Diagnostic canary: establish vector load/store visibility before math.
        & $ptr 4 16 198656;& $ptr 6 24
        $steps.Add(@{Op='load';d=0;s=4;Offset=0})
        $steps.Add(@{Op='vload';d=8;s=4;Offset=0});$steps.Add(@{Op='vstore';t=8;s=6;Offset=0})
        $steps.Add(@{Op='load';d=1;s=6;Offset=0});$steps.Add(@{Op='eq';d=0;s=0;t=1})
        $steps.Add(@{Op='jump-p';u=0;Label='vector_visible'})
        $steps.Add(@{Op='imm';d=0;i=34});$steps.Add(@{Op='return'})
        $steps.Add(@{Op='label';Name='vector_visible'})
        $steps.Add(@{Op='sfadd';d=0;s=0;t=0});$steps.Add(@{Op='vadd-sf-qf32';d=8;s=8;t=8})
        $steps.Add(@{Op='vconv-qf32-sf';d=8;s=8})
        $steps.Add(@{Op='vstore';t=8;s=6;Offset=0});$steps.Add(@{Op='load';d=1;s=6;Offset=0})
        $steps.Add(@{Op='load';d=2;s=3;Offset=32})
        $steps.Add(@{Op='store';s=2;t=0;Offset=0});$steps.Add(@{Op='store';s=2;t=1;Offset=4})
        $steps.Add(@{Op='eq';d=0;s=0;t=1});$steps.Add(@{Op='jump-p';u=0;Label='vector_arithmetic'})
        # QFloat has distinct rounding (HVX PRM section 5.6). This positive
        # pinned-bias canary permits one FP32 ULP, not bitwise IEEE equivalence.
        $steps.Add(@{Op='addi';d=0;s=0;i=1})
        $steps.Add(@{Op='eq';d=0;s=0;t=1});$steps.Add(@{Op='jump-p';u=0;Label='vector_arithmetic'})
        $steps.Add(@{Op='addi';d=0;s=0;i=-2})
        $steps.Add(@{Op='eq';d=0;s=0;t=1});$steps.Add(@{Op='jump-p';u=0;Label='vector_arithmetic'})
        $steps.Add(@{Op='imm';d=0;i=35});$steps.Add(@{Op='return'})
        $steps.Add(@{Op='label';Name='vector_arithmetic'})
    }
    $norm=@(New-KokoroAdaInSteps -Frames $Frames -Channels 128)
    $compute=0;while($compute -lt $norm.Count -and $norm[$compute].Name -cne 'compute'){$compute++}
    if($compute -eq $norm.Count){throw 'AdaIN compute region is absent'}
    for($stage=0;$stage -lt 6;$stage++){
        $pass=[int][Math]::Floor($stage/2);$side=$stage%2
        $dilation=if($side -eq 0){@(1,3,5)[$pass]}else{1}
        $stageOffset=$stage*$stageBytes
        # Reload pointers from the admitted graph descriptor. r3 remains the
        # descriptor base throughout all regions; caller-saved r0-r15 only.
        if($side -eq 1){& $ptr 4 24 ($tensorBytes+$haloBytes)}
        elseif($pass -eq 0){& $ptr 4 8}else{& $ptr 4 32}
        & $ptr 5 16 $stageOffset;& $ptr 6 24
        for($i=$compute;$i -lt $norm.Count-2;$i++){
            $s=$norm[$i].Clone()
            if($s.ContainsKey('Name')){$s.Name="n${stage}_$($s.Name)"}
            if($s.ContainsKey('Label') -and $s.Label -notin 'domain','bad'){$s.Label="n${stage}_$($s.Label)"}
            $steps.Add($s)
        }
        # Snake: x + sin(alpha*x)^2 / alpha, channel-major in-place.
        & $ptr 4 24;& $ptr 5 16 ($stageOffset+1024)
        $steps.Add(@{Op='imm';d=8;i=128});& $fp 12 ([Math]::PI);& $fp 13 (1/[Math]::PI)
        $steps.Add(@{Op='label';Name="s${stage}_channel"})
        $steps.Add(@{Op='load';d=10;s=5;Offset=0});$steps.Add(@{Op='load';d=11;s=5;Offset=512})
        $steps.Add(@{Op='imm';d=9;i=$Frames})
        $steps.Add(@{Op='label';Name="s${stage}_frame"})
        $steps.Add(@{Op='load';d=14;s=4;Offset=0});$steps.Add(@{Op='sfmpy';d=0;s=14;t=10})
        $steps.Add(@{Op='sfmpy';d=1;s=0;t=13});$steps.Add(@{Op='conv-sf2w-chop';d=1;s=1})
        $steps.Add(@{Op='conv-w2sf';d=1;s=1});$steps.Add(@{Op='sfmpy';d=1;s=1;t=12})
        $steps.Add(@{Op='sfsub';d=1;s=0;t=1});$steps.Add(@{Op='sfmpy';d=2;s=1;t=1})
        & $fp 7 (1/355687428096000.0)
        foreach($coefficient in @((-1/1307674368000.0),(1/6227020800.0),(-1/39916800.0),(1/362880.0),(-1/5040.0),(1/120.0),(-1/6.0),1.0)){
            $steps.Add(@{Op='sfmpy';d=7;s=7;t=2});& $fp 0 $coefficient
            $steps.Add(@{Op='sfadd';d=7;s=7;t=0})
        }
        $steps.Add(@{Op='sfmpy';d=7;s=7;t=1});$steps.Add(@{Op='sfmpy';d=7;s=7;t=7})
        $steps.Add(@{Op='sfmpy';d=7;s=7;t=11});$steps.Add(@{Op='sfadd';d=7;s=14;t=7})
        $steps.Add(@{Op='store';s=4;t=7;Offset=0});$steps.Add(@{Op='addi';d=4;s=4;i=4})
        $steps.Add(@{Op='addi';d=9;s=9;i=-1});$steps.Add(@{Op='gtu';d=0;s=9;t=15});$steps.Add(@{Op='jump-p';u=0;Label="s${stage}_frame"})
        $steps.Add(@{Op='addi';d=5;s=5;i=4});$steps.Add(@{Op='addi';d=8;s=8;i=-1})
        $steps.Add(@{Op='gtu';d=0;s=8;t=15});$steps.Add(@{Op='jump-p';u=0;Label="s${stage}_channel"})
        # Internal zero halo, including dilation. It never crosses the host.
        & $ptr 4 24;& $ptr 6 24 $tensorBytes;$steps.Add(@{Op='imm';d=8;i=128})
        $steps.Add(@{Op='label';Name="h${stage}_channel"})
        for($i=0;$i -lt $dilation;$i++){
            $steps.Add(@{Op='store';s=6;t=15;Offset=0});$steps.Add(@{Op='addi';d=6;s=6;i=4})
        }
        $steps.Add(@{Op='imm';d=9;i=$Frames});$steps.Add(@{Op='label';Name="h${stage}_copy"})
        $steps.Add(@{Op='load';d=0;s=4;Offset=0});$steps.Add(@{Op='store';s=6;t=0;Offset=0})
        $steps.Add(@{Op='addi';d=4;s=4;i=4});$steps.Add(@{Op='addi';d=6;s=6;i=4})
        $steps.Add(@{Op='addi';d=9;s=9;i=-1});$steps.Add(@{Op='gtu';d=0;s=9;t=15});$steps.Add(@{Op='jump-p';u=0;Label="h${stage}_copy"})
        for($i=0;$i -lt $dilation;$i++){
            $steps.Add(@{Op='store';s=6;t=15;Offset=0});$steps.Add(@{Op='addi';d=6;s=6;i=4})
        }
        $steps.Add(@{Op='addi';d=8;s=8;i=-1});$steps.Add(@{Op='gtu';d=0;s=8;t=15});$steps.Add(@{Op='jump-p';u=0;Label="h${stage}_channel"})
        if($VectorConvolution){
            # Four vectors cover 128 output channels. Each lane retains the
            # scalar baseline's tap-then-input reduction. QFloat results are
            # explicitly converted to IEEE FP32 after each operation; any
            # rounding difference must pass the complete block gate.
            # Only this region is time-major; transpose on DSP for full-time AdaIN.
            & $ptr 4 24 $tensorBytes;& $ptr 5 16 ($stageOffset+2048)
            & $ptr 7 16 ($stageOffset+2048+196608)
            $temporary=if($side -eq 0){0}else{$tensorBytes+$haloBytes}
            $destination=if($side -eq 0){$tensorBytes+$haloBytes}else{0}
            & $ptr 6 24 $temporary
            $steps.Add(@{Op='imm';d=9;i=$Frames});$steps.Add(@{Op='label';Name="v${stage}_frame"})
            foreach($v in 0..3){$steps.Add(@{Op='vsplat';d=$v;s=15})}
            $steps.Add(@{Op='addi';d=10;s=5;i=0});$steps.Add(@{Op='addi';d=14;s=4;i=0})
            $steps.Add(@{Op='imm';d=13;i=3});$steps.Add(@{Op='label';Name="v${stage}_tap"})
            $steps.Add(@{Op='addi';d=11;s=14;i=0});$steps.Add(@{Op='imm';d=12;i=128})
            $steps.Add(@{Op='label';Name="v${stage}_reduce"})
            $steps.Add(@{Op='load';d=0;s=11;Offset=0});$steps.Add(@{Op='vsplat';d=4;s=0})
            foreach($v in 0..3){$steps.Add(@{Op='vload';d=(8+$v);s=10;Offset=(128*$v)})}
            foreach($v in 0..3){$steps.Add(@{Op='vmpy-sf-qf32';d=(8+$v);s=(8+$v);t=4})}
            foreach($v in 0..3){$steps.Add(@{Op='vconv-qf32-sf';d=(8+$v);s=(8+$v)})}
            foreach($v in 0..3){$steps.Add(@{Op='vadd-sf-qf32';d=$v;s=$v;t=(8+$v)})}
            foreach($v in 0..3){$steps.Add(@{Op='vconv-qf32-sf';d=$v;s=$v})}
            $steps.Add(@{Op='addi';d=11;s=11;i=(4*($Frames+2*$dilation))});$steps.Add(@{Op='addi';d=10;s=10;i=512})
            $steps.Add(@{Op='addi';d=12;s=12;i=-1});$steps.Add(@{Op='gtu';d=0;s=12;t=15})
            $steps.Add(@{Op='jump-p';u=0;Label="v${stage}_reduce"})
            $steps.Add(@{Op='addi';d=14;s=14;i=(4*$dilation)});$steps.Add(@{Op='addi';d=13;s=13;i=-1})
            $steps.Add(@{Op='gtu';d=0;s=13;t=15});$steps.Add(@{Op='jump-p';u=0;Label="v${stage}_tap"})
            foreach($v in 0..3){$steps.Add(@{Op='vload';d=(8+$v);s=7;Offset=(128*$v)})}
            foreach($v in 0..3){$steps.Add(@{Op='vadd-sf-qf32';d=$v;s=$v;t=(8+$v)})}
            foreach($v in 0..3){$steps.Add(@{Op='vconv-qf32-sf';d=$v;s=$v})}
            foreach($v in 0..3){$steps.Add(@{Op='vstore';t=$v;s=6;Offset=(128*$v)})}
            $steps.Add(@{Op='addi';d=4;s=4;i=4});$steps.Add(@{Op='addi';d=6;s=6;i=512})
            $steps.Add(@{Op='addi';d=9;s=9;i=-1});$steps.Add(@{Op='gtu';d=0;s=9;t=15})
            $steps.Add(@{Op='jump-p';u=0;Label="v${stage}_frame"})
            & $ptr 4 24 $temporary;& $ptr 6 24 $destination
            $steps.Add(@{Op='imm';d=8;i=128});$steps.Add(@{Op='label';Name="t${stage}_channel"})
            $steps.Add(@{Op='addi';d=5;s=4;i=0});$steps.Add(@{Op='imm';d=9;i=$Frames})
            $steps.Add(@{Op='label';Name="t${stage}_frame"})
            $steps.Add(@{Op='load';d=0;s=5;Offset=0});$steps.Add(@{Op='store';s=6;t=0;Offset=0})
            $steps.Add(@{Op='addi';d=5;s=5;i=512});$steps.Add(@{Op='addi';d=6;s=6;i=4})
            $steps.Add(@{Op='addi';d=9;s=9;i=-1});$steps.Add(@{Op='gtu';d=0;s=9;t=15})
            $steps.Add(@{Op='jump-p';u=0;Label="t${stage}_frame"})
            $steps.Add(@{Op='addi';d=4;s=4;i=4});$steps.Add(@{Op='addi';d=8;s=8;i=-1})
            $steps.Add(@{Op='gtu';d=0;s=8;t=15});$steps.Add(@{Op='jump-p';u=0;Label="t${stage}_channel"})
        } else {
        # Conv with KIO prepacked, already-folded weights. Same numerical
        # region as Kokoro.ConvTile, generalized for the three dilations.
        & $ptr 4 24 $tensorBytes;& $ptr 5 16 ($stageOffset+2048)
        & $ptr 7 16 ($stageOffset+2048+196608)
        & $ptr 6 24 $(if($side -eq 0){$tensorBytes+$haloBytes}else{0})
        $steps.Add(@{Op='imm';d=8;i=128});$steps.Add(@{Op='label';Name="c${stage}_channel"})
        $steps.Add(@{Op='imm';d=9;i=$Frames});$steps.Add(@{Op='label';Name="c${stage}_frame"})
        $steps.Add(@{Op='imm';d=2;i=0});$steps.Add(@{Op='addi';d=10;s=5;i=0});$steps.Add(@{Op='addi';d=14;s=4;i=0})
        $steps.Add(@{Op='imm';d=13;i=3});$steps.Add(@{Op='label';Name="c${stage}_tap"})
        $steps.Add(@{Op='addi';d=11;s=14;i=0});$steps.Add(@{Op='imm';d=12;i=128})
        $steps.Add(@{Op='label';Name="c${stage}_reduce"})
        $steps.Add(@{Op='load';d=0;s=11;Offset=0});$steps.Add(@{Op='load';d=1;s=10;Offset=0})
        $steps.Add(@{Op='sfmpy';d=0;s=0;t=1});$steps.Add(@{Op='sfadd';d=2;s=2;t=0})
        $steps.Add(@{Op='addi';d=11;s=11;i=(4*($Frames+2*$dilation))});$steps.Add(@{Op='addi';d=10;s=10;i=512})
        $steps.Add(@{Op='addi';d=12;s=12;i=-1});$steps.Add(@{Op='gtu';d=0;s=12;t=15});$steps.Add(@{Op='jump-p';u=0;Label="c${stage}_reduce"})
        $steps.Add(@{Op='addi';d=14;s=14;i=(4*$dilation)});$steps.Add(@{Op='addi';d=13;s=13;i=-1})
        $steps.Add(@{Op='gtu';d=0;s=13;t=15});$steps.Add(@{Op='jump-p';u=0;Label="c${stage}_tap"})
        $steps.Add(@{Op='load';d=1;s=7;Offset=0});$steps.Add(@{Op='sfadd';d=2;s=2;t=1});$steps.Add(@{Op='store';s=6;t=2;Offset=0})
        $steps.Add(@{Op='addi';d=4;s=4;i=4});$steps.Add(@{Op='addi';d=6;s=6;i=4})
        $steps.Add(@{Op='addi';d=9;s=9;i=-1});$steps.Add(@{Op='gtu';d=0;s=9;t=15});$steps.Add(@{Op='jump-p';u=0;Label="c${stage}_frame"})
        $steps.Add(@{Op='addi';d=4;s=4;i=(-4*$Frames)});$steps.Add(@{Op='addi';d=5;s=5;i=4})
        $steps.Add(@{Op='addi';d=7;s=7;i=4});$steps.Add(@{Op='addi';d=8;s=8;i=-1})
        $steps.Add(@{Op='gtu';d=0;s=8;t=15});$steps.Add(@{Op='jump-p';u=0;Label="c${stage}_channel"})
        }
        if($side -eq 1){
            & $ptr 4 $(if($pass -eq 0){8}else{32});& $ptr 5 24;& $ptr 6 32
            & $imm 8 (128*$Frames);$steps.Add(@{Op='label';Name="r${stage}_add"})
            $steps.Add(@{Op='load';d=0;s=4;Offset=0});$steps.Add(@{Op='load';d=1;s=5;Offset=0})
            $steps.Add(@{Op='sfadd';d=0;s=0;t=1});$steps.Add(@{Op='store';s=6;t=0;Offset=0})
            foreach($r in 4,5,6){$steps.Add(@{Op='addi';d=$r;s=$r;i=4})}
            $steps.Add(@{Op='addi';d=8;s=8;i=-1});$steps.Add(@{Op='gtu';d=0;s=8;t=15});$steps.Add(@{Op='jump-p';u=0;Label="r${stage}_add"})
        }
    }
    $steps.Add(@{Op='imm';d=0;i=0});$steps.Add(@{Op='return'})
    $steps.ToArray()
}
