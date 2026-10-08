#requires -Version 7.4
# har in the 10x front's phase-major layout (tools/New-KokoroGeneratorFront10x16Fixture.ps1: X'[22 rho + c][m'] =
# har[c][6 m' + rho], 132 of 256 channels, so noise_convs[0] (kernel 12, stride 6) is a stride-1 conv with taps at frame
# shifts -1..1), from har's two byte planes in 64-channel croutons (Kokoro.HarmonicStft16Run.ps1).
# Scalar copies of the odd (value) byte of each halfword, both planes; the output must be pre-filled (zero: 0x80 high,
# 0 low) for the channels and rows not written. Crouton address of row r, channel ch in a C-channel tile T:
# T C 64 + (ch >> 5) 2048 + (r >> 1) 128 + (ch & 31) 4 + (r & 1) 2.
# r0 rows m' to write (each takes har rows 6 m' .. 6 m' + rows-per-m' - 1), r1 har high plane, r2 har low plane,
# r3 output high plane, r4 output low plane, r5 first m' (0). Rows per m' (6, or fewer for a last partial row) are set by
# -Phases. Caller-saved registers only.
function New-KokoroHarPhaseMajor16Steps {
    param([ValidateRange(1,6)][int]$Phases=6,[string]$LabelPrefix='harphasemajor16',[switch]$NoReturn)
    $s = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL); $s.Add(@{Op='lo';x=$r;i=($u -band 65535)}); $s.Add(@{Op='hi';x=$r;i=($u -shr 16)}) }
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
