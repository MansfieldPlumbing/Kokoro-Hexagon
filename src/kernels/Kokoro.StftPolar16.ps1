#requires -Version 7.4
# har = [|X|, angle(X)] of the STFT bins (stock TorchSTFT.transform: torch.abs and torch.angle of torch.stft; Kokoro
# dfb907a02bba8152ca444717ca5d78747ccb4bec istftnet.py) from the combined STFT conv output, as the two byte planes of
# har in 64-channel croutons: magnitude bin k in channel k, phase bin k in channel 11 + k (channels 22..63 zero).
# CORDIC in vectoring mode (Volder 1959), shifts and adds only, per word lane:
#   x, y  = Re, Im (int16, the bin's conv unit) << G
#   x < 0: (x, y) -> (-x, -y), z = +pi (y >= 0) or -pi (y < 0); so Im = 0, Re < 0 gives +pi as torch.angle of +0 imag.
#   i = 0 .. I-1: s = y >> 31 (0 or -1); N(v) = (v ^ s) - s; x += N(y >> i); y -= N(x >> i); z += N(atan 2^-i)
#   |X| = x K^-1 (K = prod sqrt(1 + 2^-2i)); angle = z, in units of pi / 2^30.
#   har value = (x * Km_k) >> 31 and (z * Kp_k) >> 31 (rounded, saturated to int16): Km = unit_k 2^31 / (K 2^G sH_k),
#   Kp = pi 2^-30 2^31 / sH_(11+k) (Get-KokoroStftPolarConstants; the fixture writes Km, Kp).
# Conv output layout (Kokoro.PlaneCombine.ps1, 64 channels): Re_k in block 0 lane k, Im_k in block 1 lane k.
# r0 conv output tiles (biased u16, 4096 B per tile), r1 har high-plane tiles, r2 har low-plane tiles (4096 B per tile;
# block 1 not written), r3 constants (Get-KokoroStftPolarConstants), r4 tiles >= 1. Caller-saved registers only.
$script:StftPolarGuard = 13
$script:StftPolarIterations = 16

function Get-KokoroStftPolarConstants {
    # Vectors: 0 bias 0x80008000, 1 0xFFFF0000, 2 0x0000FFFF, 3 0xFF00FF00, 4 pi (2^30), 5 Km per lane, 6 Kp per lane,
    # 7 32767, 8 -32768, 9 lanes 0..10 mask, 10 lanes 11..21 mask, 11 + i atan(2^-i) in units of pi / 2^30.
    # Km and Kp are zero here (the fixture writes lanes 0..10). Also returns the CORDIC gain K and guard bits G.
    $v = [byte[]]::new(4096)
    $lane = { param([int]$index,[int]$l,[long]$value) [BitConverter]::GetBytes([uint32]($value -band 0xffffffffL)).CopyTo($v, 128 * $index + 4 * $l) }
    $word = { param([int]$index,[long]$value) for ($l = 0; $l -lt 32; $l++) { & $lane $index $l $value } }
    & $word 0 0x80008000L; & $word 1 0xFFFF0000L; & $word 2 0x0000FFFFL; & $word 3 0xFF00FF00L; & $word 4 1073741824L
    & $word 7 32767; & $word 8 -32768
    for ($l = 0; $l -lt 11; $l++) { & $lane 9 $l 0xFFFFFFFFL; & $lane 10 (11 + $l) 0xFFFFFFFFL }
    $gain = 1.0
    for ($i = 0; $i -lt $script:StftPolarIterations; $i++) {
        & $word (11 + $i) ([long][math]::Round([math]::Atan([math]::Pow(2, -$i)) / [math]::PI * 1073741824))
        $gain *= [math]::Sqrt(1 + [math]::Pow(2, -2 * $i))
    }
    [pscustomobject]@{ Bytes = $v; Gain = $gain; Guard = $script:StftPolarGuard; Iterations = $script:StftPolarIterations }
}

function New-KokoroStftPolar16Steps {
    param([string]$LabelPrefix='stftpolar16',[switch]$NoReturn)
    $guard = $script:StftPolarGuard; $iterations = $script:StftPolarIterations
    if (11 + $iterations - 1 -gt 34) { throw 'atan vectors exceed the constant record base offsets' }
    $s = [Collections.Generic.List[hashtable]]::new()
    $c = { param([int]$d,[int]$k) if ($k -le 10) { $s.Add(@{Op='vload';d=$d;s=12;Offset=(128*($k-8))}) } elseif ($k -le 26) { $s.Add(@{Op='vload';d=$d;s=13;Offset=(128*($k-19))}) } else { $s.Add(@{Op='vload';d=$d;s=14;Offset=(128*($k-31))}) } }
    $s.Add(@{Op='addi';d=12;s=3;i=1024}); $s.Add(@{Op='addi';d=13;s=3;i=2432}); $s.Add(@{Op='addi';d=14;s=3;i=3968})
    foreach ($kv in @(@(5,(16-$guard)),@(6,31),@(8,16),@(9,8),@(15,0))) { $s.Add(@{Op='imm';d=$kv[0];i=$kv[1]}) }
    # Resident: v31 bias, v30 odd mask, v29 even mask, v28 pi, v27 Km, v26 Kp, v25 32767, v24 -32768, v23 mask 0..10,
    # v22 mask 11..21, v21 0xFF00FF00.
    & $c 31 0; & $c 30 1; & $c 29 2; & $c 21 3; & $c 28 4; & $c 27 5; & $c 26 6; & $c 25 7; & $c 24 8; & $c 23 9; & $c 22 10
    # One row: x (v2), y (v3) from Re (v0), Im (v1); magnitude to v9, phase to v10, both int32 saturated to int16.
    $row = { param([bool]$Odd)
        if ($Odd) { $s.Add(@{Op='vand';d=2;s=0;t=30}); $s.Add(@{Op='vand';d=3;s=1;t=30}) }
        else { $s.Add(@{Op='vasl-w';d=2;s=0;t=8}); $s.Add(@{Op='vasl-w';d=3;s=1;t=8}) }
        $s.Add(@{Op='vasr-w';d=2;s=2;t=5}); $s.Add(@{Op='vasr-w';d=3;s=3;t=5})
        # Half-plane x < 0: rotate by pi.
        $s.Add(@{Op='vasr-w';d=5;s=2;t=6}); $s.Add(@{Op='vasr-w';d=6;s=3;t=6})
        $s.Add(@{Op='vxor';d=2;s=2;t=5}); $s.Add(@{Op='vsub-w';d=2;s=2;t=5})
        $s.Add(@{Op='vxor';d=3;s=3;t=5}); $s.Add(@{Op='vsub-w';d=3;s=3;t=5})
        $s.Add(@{Op='vxor';d=4;s=28;t=6}); $s.Add(@{Op='vsub-w';d=4;s=4;t=6}); $s.Add(@{Op='vand';d=4;s=4;t=5})
        for ($i = 0; $i -lt $iterations; $i++) {
            $s.Add(@{Op='vasr-w';d=5;s=3;t=6})
            $s.Add(@{Op='imm';d=7;i=$i})
            $s.Add(@{Op='vasr-w';d=6;s=2;t=7}); $s.Add(@{Op='vasr-w';d=7;s=3;t=7})
            & $c 8 (11 + $i)
            $s.Add(@{Op='vxor';d=7;s=7;t=5}); $s.Add(@{Op='vsub-w';d=7;s=7;t=5}); $s.Add(@{Op='vadd-w';d=2;s=2;t=7})
            $s.Add(@{Op='vxor';d=6;s=6;t=5}); $s.Add(@{Op='vsub-w';d=6;s=6;t=5}); $s.Add(@{Op='vsub-w';d=3;s=3;t=6})
            $s.Add(@{Op='vxor';d=8;s=8;t=5}); $s.Add(@{Op='vsub-w';d=8;s=8;t=5}); $s.Add(@{Op='vadd-w';d=4;s=4;t=8})
        }
        foreach ($p in @(@(9,2,27),@(10,4,26))) {
            $s.Add(@{Op='vmpye-w-uh';d=$p[0];s=$p[1];t=$p[2]}); $s.Add(@{Op='vmpyo-acc-w-h-rnd-sat-shift';d=$p[0];s=$p[1];t=$p[2]})
            $s.Add(@{Op='vmin-w';d=$p[0];s=$p[0];t=25}); $s.Add(@{Op='vmax-w';d=$p[0];s=$p[0];t=24})
        }
    }
    $s.Add(@{Op='label';Name="${LabelPrefix}_tile"})
    $s.Add(@{Op='imm';d=11;i=16})
    $s.Add(@{Op='label';Name="${LabelPrefix}_pair"})
    $s.Add(@{Op='vload';d=0;s=0;Offset=0}); $s.Add(@{Op='addi';d=7;s=0;i=2048}); $s.Add(@{Op='vload';d=1;s=7;Offset=0})
    $s.Add(@{Op='vxor';d=0;s=0;t=31}); $s.Add(@{Op='vxor';d=1;s=1;t=31})
    & $row $false
    $s.Add(@{Op='vand';d=11;s=9;t=29}); $s.Add(@{Op='vand';d=12;s=10;t=29})
    & $row $true
    $s.Add(@{Op='vasl-w';d=9;s=9;t=8}); $s.Add(@{Op='vor';d=11;s=11;t=9})
    $s.Add(@{Op='vasl-w';d=10;s=10;t=8}); $s.Add(@{Op='vor';d=12;s=12;t=10})
    # Phase lanes k -> 11 + k (valign by 84 bytes: Vd.ub[i] = Vu.ub[i - 44] for i >= 44), masks, bias, planes.
    $s.Add(@{Op='imm';d=7;i=84}); $s.Add(@{Op='valign';d=12;s=12;t=12;r=7})   # valign's Rt is r0..r7
    $s.Add(@{Op='vand';d=11;s=11;t=23}); $s.Add(@{Op='vand';d=12;s=12;t=22}); $s.Add(@{Op='vor';d=11;s=11;t=12})
    $s.Add(@{Op='vand';d=13;s=11;t=21}); $s.Add(@{Op='vxor';d=13;s=13;t=31})
    $s.Add(@{Op='vasl-h';d=14;s=11;t=9})
    $s.Add(@{Op='vstore';s=1;t=13;Offset=0}); $s.Add(@{Op='vstore';s=2;t=14;Offset=0})
    $s.Add(@{Op='addi';d=0;s=0;i=128}); $s.Add(@{Op='addi';d=1;s=1;i=128}); $s.Add(@{Op='addi';d=2;s=2;i=128})
    $s.Add(@{Op='addi';d=11;s=11;i=-1}); $s.Add(@{Op='gtu';d=0;s=11;t=15}); $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_pair"})
    $s.Add(@{Op='addi';d=0;s=0;i=2048}); $s.Add(@{Op='addi';d=1;s=1;i=2048}); $s.Add(@{Op='addi';d=2;s=2;i=2048})
    $s.Add(@{Op='addi';d=4;s=4;i=-1}); $s.Add(@{Op='gtu';d=0;s=4;t=15}); $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_tile"})
    if (-not $NoReturn) { $s.Add(@{Op='return'}) }
    $s.ToArray()
}
