#requires -Version 7.4
# Stock Snake: x+sin(alpha*x)^2/alpha, Kokoro dfb907a0 istftnet.py.
# Shared periodic sin^2 table, 256 intervals, Q15 ordinates, 8-bit interpolation.
# Published integer lookup/interpolation reference: CMSIS-DSP d5717e454fec0337bef114a21f1d2d01d74f2701
# Source/FastMathFunctions/arm_sin_q31.c (method reference; no copied product code).
# V73 HVX PRM 80-N2040-54 Rev AB pp.227-230: vlut16 matching/shuffled table.
# r0 native signed Q8 input; r1 native u8 output; r2 2048-byte packed constants;
# r3 tiles >=1. Constants: phaseQ16[128], inverseAlphaQ8[128], requantQ16[128],
# followed by four shuffled 64-entry Q15 table vectors. Signed nonzero alpha
# is preserved: modulo phase handles either sign, and inverseAlpha is signed.
# Layout stays time-major croutons. Only the precision of each lane changes.
function New-KokoroSnakeIntegerSteps {
    # Channels*12 bytes of channel constants, then the shared 512-byte table.
    param([ValidateSet(128,256)][int]$Channels=128,[string]$LabelPrefix='snakeinteger')
    $steps=[Collections.Generic.List[hashtable]]::new()
    foreach ($kv in @(@(8,8),@(9,16),@(10,15),@(11,24),@(12,0),@(13,255))) {
        $steps.Add(@{Op='imm';d=$kv[0];i=$kv[1]})
    }
    $steps.Add(@{Op='vsplat';d=3;s=13})
    $steps.Add(@{Op='vsplat';d=7;s=13})
    $steps.Add(@{Op='lo';x=13;i=65535})
    $steps.Add(@{Op='hi';x=13;i=0})
    $steps.Add(@{Op='vsplat';d=4;s=13})
    $steps.Add(@{Op='imm';d=13;i=1})
    $steps.Add(@{Op='vsplat';d=5;s=13})
    $steps.Add(@{Op='vxor';d=6;s=6;t=6})
    $steps.Add(@{Op='lo';x=13;i=32768})
    $steps.Add(@{Op='hi';x=13;i=0})
    $steps.Add(@{Op='vsplat';d=30;s=13})
    $steps.Add(@{Op='imm';d=13;i=128})
    $steps.Add(@{Op='vsplat';d=31;s=13})
    $steps.Add(@{Op='addi';d=6;s=2;i=($Channels*12)})
    for ($chunk=0;$chunk -lt 4;$chunk++) { $steps.Add(@{Op='vload';d=(20+$chunk);s=6;Offset=($chunk*128)}) }
    for ($block=0;$block -lt ($Channels/32);$block++) {
        $steps.Add(@{Op='addi';d=6;s=2;i=($block*128)})
        $steps.Add(@{Op='vload';d=8;s=6;Offset=0})
        $steps.Add(@{Op='vlsr-uw';d=9;s=8;t=9})
        $steps.Add(@{Op='vand';d=8;s=8;t=4})
        $steps.Add(@{Op='addi';d=6;s=6;i=($Channels*4)})
        $steps.Add(@{Op='vload';d=10;s=6;Offset=0})
        if($Channels -eq 256){$steps.Add(@{Op='addi';d=6;s=6;i=($Channels*4)});$steps.Add(@{Op='vload';d=11;s=6;Offset=0})}
        else{$steps.Add(@{Op='vload';d=11;s=6;Offset=512})}
        $steps.Add(@{Op='addi';d=4;s=0;i=($block*2048)})
        $steps.Add(@{Op='addi';d=5;s=1;i=($block*2048)})
        $steps.Add(@{Op='addi';d=15;s=3;i=0})
        $tile="${LabelPrefix}_b${block}_tile"
        $pair="${LabelPrefix}_b${block}_pair"
        $steps.Add(@{Op='label';Name=$tile})
        $steps.Add(@{Op='imm';d=14;i=16})
        $steps.Add(@{Op='label';Name=$pair})
        $steps.Add(@{Op='vload';d=0;s=4;Offset=0})
        $steps.Add(@{Op='vasl-w';d=1;s=0;t=9})
        $steps.Add(@{Op='vasr-w';d=1;s=1;t=9})
        $steps.Add(@{Op='vasr-w';d=2;s=0;t=9})
        foreach ($row in 1,2) {
            $steps.Add(@{Op='vmpyie-w-uh';d=12;s=$row;t=8})
            $steps.Add(@{Op='vmpyie-w-uh';d=13;s=$row;t=9})
            $steps.Add(@{Op='vasl-w';d=13;s=13;t=9})
            $steps.Add(@{Op='vadd-w';d=12;s=12;t=13})
            $steps.Add(@{Op='vlsr-uw';d=12;s=12;t=8})
            $steps.Add(@{Op='vand';d=12;s=12;t=4})
            $steps.Add(@{Op='vand';d=14;s=12;t=3})
            $steps.Add(@{Op='vlsr-uw';d=15;s=12;t=8})
            $steps.Add(@{Op='vadd-w';d=16;s=15;t=5})
            $steps.Add(@{Op='vand';d=16;s=16;t=3})
            for ($match=0;$match -lt 16;$match++) {
                $steps.Add(@{Op='imm';d=6;i=$match})
                $op=if ($match -eq 0) { 'vlut16' } else { 'vlut16-or' }
                $table=20+[int][math]::Floor($match/4)
                $steps.Add(@{Op=$op;d=18;s=15;v=$table;x=6})
                $steps.Add(@{Op=$op;d=24;s=16;v=$table;x=6})
            }
            $steps.Add(@{Op='vsub-w';d=28;s=24;t=18})
            $steps.Add(@{Op='vmpyie-w-uh';d=28;s=28;t=14})
            $steps.Add(@{Op='vasr-w';d=28;s=28;t=8})
            $steps.Add(@{Op='vadd-w';d=28;s=28;t=18})
            $steps.Add(@{Op='vmpyie-w-uh';d=28;s=10;t=28})
            $steps.Add(@{Op='vasr-w';d=28;s=28;t=10})
            $steps.Add(@{Op='vadd-w';d=28;s=28;t=$row})
            $steps.Add(@{Op='vmpyie-w-uh';d=28;s=28;t=11})
            $steps.Add(@{Op='vadd-w';d=28;s=28;t=30})
            $steps.Add(@{Op='vasr-w';d=28;s=28;t=9})
            $steps.Add(@{Op='vadd-w';d=28;s=28;t=31})
            $steps.Add(@{Op='vmax-w';d=28;s=28;t=6})
            $steps.Add(@{Op='vmin-w';d=28;s=28;t=7})
            $steps.Add(@{Op='vasl-w';d=(25+$row);s=28;t=$(if ($row -eq 1) {8} else {11})})
        }
        $steps.Add(@{Op='vor';d=0;s=26;t=27})
        $steps.Add(@{Op='vstore';s=5;t=0;Offset=0})
        $steps.Add(@{Op='addi';d=4;s=4;i=128})
        $steps.Add(@{Op='addi';d=5;s=5;i=128})
        $steps.Add(@{Op='addi';d=14;s=14;i=-1})
        $steps.Add(@{Op='gtu';d=0;s=14;t=12})
        $steps.Add(@{Op='jump-p';u=0;Label=$pair})
        $steps.Add(@{Op='addi';d=4;s=4;i=($Channels*64-2048)})
        $steps.Add(@{Op='addi';d=5;s=5;i=($Channels*64-2048)})
        $steps.Add(@{Op='addi';d=15;s=15;i=-1})
        $steps.Add(@{Op='gtu';d=0;s=15;t=12})
        $steps.Add(@{Op='jump-p';u=0;Label=$tile})
    }
    $steps.Add(@{Op='return'})
    $steps.ToArray()
}
