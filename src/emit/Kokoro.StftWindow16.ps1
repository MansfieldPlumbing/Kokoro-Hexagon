#requires -Version 7.4
# STFT frame windows for the HMX STFT conv (Kokoro.HarmonicStft16Run.ps1): stock TorchSTFT.transform (torch.stft n_fft 20,
# hop 5, centre with reflect padding of 10; Kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec istftnet.py) reads padded
# samples 5 t .. 5 t + 19 for frame t. Row t of the conv input (64-channel croutons) holds padded samples 5 t + c in
# channel c = 0..31 of block 0 (the conv weights are zero for c >= 20 and for block 1, which is not written).
#   row vector  = the 64 bytes at byte offset 10 t of the signal: valign(Vu = next aligned vector, Vv = this one,
#                 offset mod 128) (HVX PRM: Vd.ub[i] = i + shift >= 128 ? Vu.ub[i + shift - 128] : Vv.ub[i + shift])
#   row pair    = vshuff(Vu = odd row, Vv = even row, Rt = -2): halfwords even0, odd0, even1, odd1, ... in v0 of the pair,
#                 the crouton order (word lane j: even row low, odd row high)
#   planes      = high (v & 0xFF00) ^ 0x8000, low v << 8 (each byte in the odd position of its halfword)
# Two tiles (64 frames, 640 signal bytes, a whole number of vectors) per iteration, so every alignment is a constant.
# r0 padded signal (int16 in the merge unit, 128-byte aligned, readable 128 bytes past the last pair), r1 high-plane
# tiles, r2 low-plane tiles (4096 B per tile), r3 tile pairs >= 1. Caller-saved registers only.
function New-KokoroStftWindow16Steps {
    param([string]$LabelPrefix='stftwindow16',[switch]$NoReturn)
    $s = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL); $s.Add(@{Op='lo';x=$r;i=($u -band 65535)}); $s.Add(@{Op='hi';x=$r;i=($u -shr 16)}) }
    & $imm 6 0xFF00FF00L; $s.Add(@{Op='vsplat';d=30;s=6})
    & $imm 6 0x80008000L; $s.Add(@{Op='vsplat';d=31;s=6})
    $s.Add(@{Op='imm';d=7;i=-2}); $s.Add(@{Op='imm';d=8;i=8}); $s.Add(@{Op='imm';d=13;i=0})
    $s.Add(@{Op='label';Name="${LabelPrefix}_pair"})
    for ($q = 0; $q -lt 6; $q++) { $s.Add(@{Op='vload';d=$q;s=0;Offset=(128*$q)}) }
    # One frame row into vector d: the 64 bytes at offset o of this pair's signal.
    $row = { param([int]$d,[int]$o)
        $q = [int][math]::Floor($o / 128); $sh = $o % 128
        if ($sh -eq 0) { $s.Add(@{Op='vor';d=$d;s=$q;t=$q}) }
        else { $s.Add(@{Op='imm';d=6;i=$sh}); $s.Add(@{Op='valign';d=$d;s=($q+1);t=$q;r=6}) }
    }
    for ($rp = 0; $rp -lt 32; $rp++) {
        & $row 6 (20 * $rp); & $row 7 (20 * $rp + 10)
        $s.Add(@{Op='vshuff';d=8;s=7;t=6;r=7})
        $s.Add(@{Op='vand';d=10;s=8;t=30}); $s.Add(@{Op='vxor';d=10;s=10;t=31})
        $s.Add(@{Op='vasl-h';d=11;s=8;t=8})
        $at = 4096 * [int][math]::Floor($rp / 16) + 128 * ($rp % 16)
        & $imm 14 $at; $s.Add(@{Op='add';d=14;s=1;t=14}); $s.Add(@{Op='vstore';s=14;t=10;Offset=0})
        & $imm 15 $at; $s.Add(@{Op='add';d=15;s=2;t=15}); $s.Add(@{Op='vstore';s=15;t=11;Offset=0})
    }
    & $imm 14 640; $s.Add(@{Op='add';d=0;s=0;t=14})
    & $imm 14 8192; $s.Add(@{Op='add';d=1;s=1;t=14}); $s.Add(@{Op='add';d=2;s=2;t=14})
    $s.Add(@{Op='addi';d=3;s=3;i=-1}); $s.Add(@{Op='gtu';d=0;s=3;t=13}); $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_pair"})
    if (-not $NoReturn) { $s.Add(@{Op='return'}) }
    $s.ToArray()
}
