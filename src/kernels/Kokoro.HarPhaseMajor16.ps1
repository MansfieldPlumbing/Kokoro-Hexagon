#requires -Version 7.4
# har in the 10x front's phase-major layout (tools/New-KokoroGeneratorFront10x16Fixture.ps1: X'[22 rho + c][m'] =
# har[c][6 m' + rho], 132 of 256 channels, so noise_convs[0] (kernel 12, stride 6) is a stride-1 conv with taps at frame
# shifts -1..1), from har's two byte planes in 64-channel croutons (Kokoro.HarmonicStft16Run.ps1).
# Both planes contribute the odd (value) byte of each halfword. The caller pre-fills unused channels and rows
# with encoded zero (0x80 high, 0 low). Crouton address of row r, channel ch in a C-channel tile T:
# T C 64 + (ch >> 5) 2048 + (r >> 1) 128 + (ch & 31) 4 + (r & 1) 2.
# r0 rows m' to write (each takes har rows 6 m' .. 6 m' + rows-per-m' - 1), r1 har high plane, r2 har low plane,
# r3 output high plane, r4 output low plane, r5 first m' (0). Rows per m' (6, or fewer for a last partial row) are set by
# -Phases. Caller-saved registers only.
function New-KokoroHarPhaseMajor16Steps {
    param([ValidateRange(1,6)][int]$Phases=6,[string]$LabelPrefix='harphasemajor16',[switch]$NoReturn,[switch]$TileBatch)
    $s = [Collections.Generic.List[hashtable]]::new()
    if($TileBatch -and $Phases -eq 6){
        # Each word holds two successive rows of a channel. Gather two output rows at
        # a time. A phase contributes 22 words; concatenate their prefixes into
        # complete vectors of 32 channels. The scalar path handles the last rows.
        # r2 points to this worker's destination chunk and r4 is its virtual tile-zero base.
        $s.Add(@{Op='sub';d=6;s=2;t=4})
        $s.Add(@{Op='lsr-i';d=7;s=6;i=1})
        $s.Add(@{Op='add';d=6;s=6;t=7}) # 24576 source bytes per 16384 output bytes
        foreach($base in 0,1){$s.Add(@{Op='add';d=$base;s=$base;t=6})}
        foreach($constant in @(@(8,0x8000,0x8000),@(9,0,0),@(10,0xff00,0xff00))){
            $s.Add(@{Op='lo';x=14;i=$constant[1]}); $s.Add(@{Op='hi';x=14;i=$constant[2]})
            $s.Add(@{Op='vsplat';d=$constant[0];s=14})
        }
        $s.Add(@{Op='label';Name="${LabelPrefix}_tile"})
        $s.Add(@{Op='imm';d=6;i=0}) # first source row of the output row pair
        $s.Add(@{Op='addi';d=8;s=2;i=0}); $s.Add(@{Op='addi';d=9;s=3;i=0})
        $s.Add(@{Op='label';Name="${LabelPrefix}_pair"})
        for($phase=0;$phase -lt 6;$phase+=2){
            # The two output rows read source rows six apart. One vector load
            # also contains the next phase in its odd halfwords.
            foreach($row in 0,1){
                $s.Add(@{Op='addi';d=12;s=6;i=($phase+6*$row)})
                $s.Add(@{Op='lsr-i';d=13;s=12;i=5}); $s.Add(@{Op='asl-i';d=13;s=13;i=12})
                $s.Add(@{Op='imm';d=14;i=31}); $s.Add(@{Op='and';d=12;s=12;t=14})
                $s.Add(@{Op='asl-i';d=12;s=12;i=6}); $s.Add(@{Op='add';d=12;s=12;t=13})
                foreach($plane in 0,1){
                    $s.Add(@{Op='add';d=14;s=$plane;t=12})
                    $s.Add(@{Op='vload';d=(2*$plane+$row);s=14;Offset=0})
                }
            }
            foreach($odd in 0,1){
                $p=$phase+$odd
                $filled=(22*$p)%32
                foreach($plane in 0,1){
                    $a=2*$plane; $b=$a+1; $roll=4+$plane; $x=6+$plane; $dest=8+$plane
                    if($odd){
                        foreach($v in $a,$b){$s.Add(@{Op='valign-imm';d=$v;s=$v;t=$v;i=2})}
                    }
                    $s.Add(@{Op='vshuffe-h';d=$x;s=$b;t=$a})
                    $s.Add(@{Op='vand';d=$x;s=$x;t=10})
                    # roll ends with the preceding phase. Take enough words from x
                    # to finish a channel block, then append all 22 for the next block.
                    if($filled+22 -ge 32){
                        $s.Add(@{Op='imm';d=7;i=(4*(32-$filled))})
                        $s.Add(@{Op='valign';d=11;s=$x;t=$roll;r=7})
                        $s.Add(@{Op='addi';d=14;s=$dest;i=(2048*[int][math]::Floor(22*$p/32))})
                        $s.Add(@{Op='vstore';s=14;t=11;Offset=0})
                    }
                    if($p -eq 0){$s.Add(@{Op='vxor';d=$roll;s=$roll;t=$roll})}
                    $s.Add(@{Op='imm';d=7;i=88})
                    $s.Add(@{Op='valign';d=$roll;s=$x;t=$roll;r=7})
                    if($p -eq 5){
                        # The fifth block holds channels 128..131 and 28 padding words.
                        $s.Add(@{Op='imm';d=7;i=112})
                        $s.Add(@{Op='valign';d=11;s=(8+$plane);t=$roll;r=7})
                        $s.Add(@{Op='addi';d=14;s=$dest;i=8192}); $s.Add(@{Op='vstore';s=14;t=11;Offset=0})
                    }
                }
            }
        }
        $s.Add(@{Op='addi';d=8;s=8;i=128}); $s.Add(@{Op='addi';d=9;s=9;i=128})
        $s.Add(@{Op='addi';d=6;s=6;i=12}); $s.Add(@{Op='imm';d=12;i=192})
        $s.Add(@{Op='gtu';d=0;s=12;t=6}); $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_pair"})
        foreach($base in 0,1){$s.Add(@{Op='addi';d=$base;s=$base;i=24576})}
        foreach($base in 2,3){$s.Add(@{Op='addi';d=$base;s=$base;i=16384})}
        $s.Add(@{Op='addi';d=5;s=5;i=-1}); $s.Add(@{Op='imm';d=12;i=0})
        $s.Add(@{Op='gtu';d=0;s=5;t=12}); $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_tile"})
        if(-not $NoReturn){$s.Add(@{Op='return'})}
        return $s.ToArray()
    }
    if($TileBatch){
        # Pool ABI: r0/r1 source planes, r2/r3 destination chunk, r4 full high-plane base, r5 tile count.
        # A destination tile is 16384 bytes / 32 rows. Recover the absolute first row and full bases;
        # the unchanged row body below then writes only this chunk's complete tiles.
        $s.Add(@{Op='addi';d=7;s=0;i=0}); $s.Add(@{Op='addi';d=8;s=1;i=0})
        $s.Add(@{Op='sub';d=6;s=2;t=4})
        $s.Add(@{Op='sub';d=4;s=3;t=6}); $s.Add(@{Op='sub';d=3;s=2;t=6})
        $s.Add(@{Op='asl-i';d=0;s=5;i=5}); $s.Add(@{Op='lsr-i';d=5;s=6;i=9})
        $s.Add(@{Op='addi';d=1;s=7;i=0}); $s.Add(@{Op='addi';d=2;s=8;i=0})
    }
    $imm = { param([int]$r,[long]$v) $u=[long]([uint32]($v -band 0xffffffffL)); $s.Add(@{Op='lo';x=$r;i=($u -band 65535)}); $s.Add(@{Op='hi';x=$r;i=($u -shr 16)}) }
    # Crouton row offset of row index in rs (tile bytes tb) into rd: (r >> 5) tb + ((r & 31) >> 1) 128 + (r & 1) 2.
    $rowOff = { param([int]$rd,[int]$rs,[int]$tileShift)
        $s.Add(@{Op='lsr-i';d=$rd;s=$rs;i=5}); $s.Add(@{Op='asl-i';d=$rd;s=$rd;i=$tileShift})
        $s.Add(@{Op='imm';d=14;i=31}); $s.Add(@{Op='and';d=14;s=$rs;t=14}); $s.Add(@{Op='lsr-i';d=15;s=14;i=1}); $s.Add(@{Op='asl-i';d=15;s=15;i=7}); $s.Add(@{Op='add';d=$rd;s=$rd;t=15})
        $s.Add(@{Op='imm';d=15;i=1}); $s.Add(@{Op='and';d=14;s=14;t=15}); $s.Add(@{Op='asl-i';d=14;s=14;i=1}); $s.Add(@{Op='add';d=$rd;s=$rd;t=14}) }
    $s.Add(@{Op='label';Name="${LabelPrefix}_row"})
    & $rowOff 6 5 14                                                           # r6 output row offset (16384 B tiles)
    $s.Add(@{Op='add';d=7;s=3;t=6}); $s.Add(@{Op='add';d=8;s=4;t=6})          # r7, r8 output rows (high, low)
    # r9 = 6 m'.
    $s.Add(@{Op='asl-i';d=9;s=5;i=1}); $s.Add(@{Op='add';d=9;s=9;t=5}); $s.Add(@{Op='asl-i';d=9;s=9;i=1})
    for ($rho = 0; $rho -lt $Phases; $rho++) {
        $s.Add(@{Op='addi';d=13;s=9;i=$rho})
        & $rowOff 10 13 12                                                     # r10 har row offset (4096 B tiles)
        $s.Add(@{Op='add';d=11;s=1;t=10}); $s.Add(@{Op='add';d=10;s=2;t=10})  # r11 high, r10 low source row
        $center = [int][math]::Floor(22 * $rho / 32) * 2048 + 1024
        $s.Add(@{Op='addi';d=12;s=7;i=$center}); $s.Add(@{Op='addi';d=13;s=8;i=$center})
        for ($c = 0; $c -lt 22; $c++) {
            $ch = 22 * $rho + $c; $off = [int][math]::Floor($ch / 32) * 2048 + ($ch % 32) * 4 - $center
            $s.Add(@{Op='load-ub';d=14;s=11;Offset=(4 * $c + 1)}); $s.Add(@{Op='asl-i';d=14;s=14;i=8}); $s.Add(@{Op='store-h';s=12;t=14;Offset=$off})
            $s.Add(@{Op='load-ub';d=15;s=10;Offset=(4 * $c + 1)}); $s.Add(@{Op='asl-i';d=15;s=15;i=8}); $s.Add(@{Op='store-h';s=13;t=15;Offset=$off})
        }
    }
    $s.Add(@{Op='addi';d=5;s=5;i=1}); $s.Add(@{Op='addi';d=0;s=0;i=-1}); $s.Add(@{Op='imm';d=14;i=0}); $s.Add(@{Op='gtu';d=0;s=0;t=14}); $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_row"})
    if (-not $NoReturn) { $s.Add(@{Op='return'}) }
    $s.ToArray()
}
