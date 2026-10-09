#requires -Version 7.4
# Fused stock AdaIN1d affine then Snake, one pass over native u8 croutons.
# Kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec istftnet.py:20-31 (AdaIN1d) and Snake.
# Same integer arithmetic as New-KokoroAdaInIntegerAffineSteps followed by
# New-KokoroSnakeIntegerSteps: the affine result, clamped to int16, is exactly the
# signed Q8 halfword the Snake pass re-reads, so it stays in registers instead of
# making a round trip through a Q8 tensor.
# r0 native u8 input; r1 native u8 output; r2 AdaIN {gainQ16[128], offsetQ16[128]};
# r3 2048-byte Snake constants (phaseQ16[128], inverseAlphaQ8[128], requantQ16[128],
# four shuffled 64-entry Q15 table vectors); r4 tiles >= 1.
# Input and output may not overlap. r16..r27 are untouched.
function New-KokoroAdaInSnakeIntegerSteps {
    param([string]$LabelPrefix='adainsnake',[switch]$NoReturn)
    $Channels=128
    $steps=[Collections.Generic.List[hashtable]]::new()
    foreach ($kv in @(@(8,8),@(9,16),@(10,15),@(11,24),@(12,0),@(13,255))) {
        $steps.Add(@{Op='imm';d=$kv[0];i=$kv[1]})
    }
    $steps.Add(@{Op='addi';d=7;s=4;i=0})                      # tile count
    $steps.Add(@{Op='vsplat';d=3;s=13})                       # 255
    $steps.Add(@{Op='lo';x=13;i=65535});$steps.Add(@{Op='hi';x=13;i=0})
    $steps.Add(@{Op='vsplat';d=4;s=13})                       # 0xFFFF
    $steps.Add(@{Op='imm';d=13;i=1});$steps.Add(@{Op='vsplat';d=5;s=13})
    $steps.Add(@{Op='vxor';d=6;s=6;t=6})
    $steps.Add(@{Op='lo';x=13;i=32768});$steps.Add(@{Op='hi';x=13;i=0})
    $steps.Add(@{Op='vsplat';d=30;s=13})
    $steps.Add(@{Op='imm';d=13;i=128});$steps.Add(@{Op='vsplat';d=31;s=13})
    $steps.Add(@{Op='imm';d=13;i=-32768});$steps.Add(@{Op='vsplat';d=26;s=13})
    $steps.Add(@{Op='imm';d=13;i=32767});$steps.Add(@{Op='vsplat';d=27;s=13})
    $steps.Add(@{Op='addi';d=6;s=3;i=($Channels*12)})
    for ($chunk=0;$chunk -lt 4;$chunk++) { $steps.Add(@{Op='vload';d=(20+$chunk);s=6;Offset=($chunk*128)}) }
    for ($block=0;$block -lt ($Channels/32);$block++) {
        # Snake per-channel constants.
        $steps.Add(@{Op='addi';d=6;s=3;i=($block*128)})
        $steps.Add(@{Op='vload';d=8;s=6;Offset=0})
        $steps.Add(@{Op='vlsr-uw';d=9;s=8;t=9})
        $steps.Add(@{Op='vand';d=8;s=8;t=4})
        $steps.Add(@{Op='addi';d=6;s=6;i=($Channels*4)})
        $steps.Add(@{Op='vload';d=10;s=6;Offset=0})
        $steps.Add(@{Op='vload';d=11;s=6;Offset=512})
        # AdaIN gain and offset.
        $steps.Add(@{Op='addi';d=6;s=2;i=($block*128)})
        $steps.Add(@{Op='vload';d=7;s=6;Offset=0})
        $steps.Add(@{Op='vload';d=17;s=6;Offset=512})
        $steps.Add(@{Op='addi';d=4;s=0;i=($block*2048)})
        $steps.Add(@{Op='addi';d=5;s=1;i=($block*2048)})
        $steps.Add(@{Op='addi';d=15;s=7;i=0})
        $tile="${LabelPrefix}_b${block}_tile"
        $pair="${LabelPrefix}_b${block}_pair"
        $steps.Add(@{Op='label';Name=$tile})
        $steps.Add(@{Op='imm';d=14;i=16})
        $steps.Add(@{Op='label';Name=$pair})
        $steps.Add(@{Op='vload';d=0;s=4;Offset=0})
        # AdaIN affine: the two u8 lanes of each word, Q16 gain/offset, Q8 int16 result.
        $steps.Add(@{Op='vlsr-uw';d=1;s=0;t=8})
        $steps.Add(@{Op='vand';d=1;s=1;t=3})
        $steps.Add(@{Op='vlsr-uw';d=2;s=0;t=11})
        foreach ($v in 1,2) {
            $steps.Add(@{Op='vmpyie-w-uh';d=$v;s=7;t=$v})
            $steps.Add(@{Op='vadd-w';d=$v;s=$v;t=17})
            $steps.Add(@{Op='vasr-w';d=$v;s=$v;t=8})
            $steps.Add(@{Op='vmax-w';d=$v;s=$v;t=26})
            $steps.Add(@{Op='vmin-w';d=$v;s=$v;t=27})
        }
        # Snake on each signed Q8 lane; row 1 result lands in v1, row 2 in v28.
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
            $steps.Add(@{Op='vmin-w';d=28;s=28;t=3})
            $steps.Add(@{Op='vasl-w';d=$(if ($row -eq 1) {1} else {28});s=28;t=$(if ($row -eq 1) {8} else {11})})
        }
        $steps.Add(@{Op='vor';d=0;s=1;t=28})
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
    if (-not $NoReturn) { $steps.Add(@{Op='return'}) }
    $steps.ToArray()
}
