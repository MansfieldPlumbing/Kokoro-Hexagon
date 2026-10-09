#requires -Version 7.4
# Small passes of the decoder (docs/decoder-design.md) over 16-bit native croutons: tile stride 64 * Channels bytes, each
# 128-byte vector a row pair x 32 channels (even halfword of word lane j row 2r, odd halfword row 2r+1 of channel j).
# Source: hexgrad/kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec, istftnet.py AdainResBlk1d (pool, upsample) and
# Decoder.forward (F0_conv, N_conv).

# Rows Frames .. 32 * Tiles - 1 of the last tile <- one halfword value (0x8000: x = 0 or the high-window zero; 0: the
# low-window zero). r0 = tile 0. Uses r1..r4, v0, v1, v29. Nothing when Frames is a multiple of 32.
function New-KokoroPadRows16Steps {
    param([Parameter(Mandatory)][ValidateRange(1,1048576)][int]$Frames,[ValidateRange(32,2048)][int]$Channels=1120,
        [ValidateSet(0,0x8000)][int]$Halfword=0x8000,[string]$LabelPrefix='padrows16',[switch]$NoReturn)
    if ($Channels % 32) { throw 'Channels must be whole 32-channel blocks' }
    $s = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL); $s.Add(@{Op='lo';x=$r;i=($u -band 65535)}); $s.Add(@{Op='hi';x=$r;i=($u -shr 16)}) }
    $f = $Frames % 32
    if ($f -ne 0) {
        $tiles = [int][math]::Ceiling($Frames / 32)
        & $imm 2 ([long]$Halfword -bor ([long]$Halfword -shl 16)); $s.Add(@{Op='vsplat';d=0;s=2})
        & $imm 2 0x0000FFFFL; $s.Add(@{Op='vsplat';d=29;s=2})
        & $imm 2 ([long]$Halfword -shl 16); $s.Add(@{Op='vsplat';d=1;s=2})
        & $imm 2 ([long]($tiles - 1) * 64 * $Channels + [math]::Floor($f / 2) * 128); $s.Add(@{Op='add';d=1;s=0;t=2})
        $s.Add(@{Op='imm';d=3;i=($Channels/32)}); $s.Add(@{Op='imm';d=4;i=0})
        $s.Add(@{Op='label';Name="${LabelPrefix}_block"})
        $s.Add(@{Op='addi';d=2;s=1;i=0})
        $first = [math]::Floor($f / 2)
        if ($f % 2) {                                            # row f - 1 stays, row f is padded
            $s.Add(@{Op='vload';d=2;s=2;Offset=0}); $s.Add(@{Op='vand';d=2;s=2;t=29}); $s.Add(@{Op='vor';d=2;s=2;t=1})
            $s.Add(@{Op='vstore';s=2;t=2;Offset=0}); $s.Add(@{Op='addi';d=2;s=2;i=128}); $first++
        }
        for ($k = $first; $k -lt 16; $k++) { $s.Add(@{Op='vstore';s=2;t=0;Offset=0}); $s.Add(@{Op='addi';d=2;s=2;i=128}) }
        $s.Add(@{Op='addi';d=1;s=1;i=2048})
        $s.Add(@{Op='addi';d=3;s=3;i=-1})
        $s.Add(@{Op='gtu';d=0;s=3;t=4})
        $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_block"})
    }
    if (-not $NoReturn) { $s.Add(@{Op='return'}) }
    $s.ToArray()
}

# Low conv-input window of a stored tensor (its high window is the tensor itself: the odd byte of x + 32768 is
# (x >> 8) + 128): out = in << 8 per halfword. r0 = input, r1 = output, r2 = vectors >= 1. Uses r3..r5, v0.
function New-KokoroLowWindow16Steps {
    param([string]$LabelPrefix='lowwindow16',[switch]$NoReturn)
    $s = [Collections.Generic.List[hashtable]]::new()
    $s.Add(@{Op='imm';d=3;i=8}); $s.Add(@{Op='imm';d=4;i=0})
    $s.Add(@{Op='label';Name="${LabelPrefix}_vec"})
    $s.Add(@{Op='vload';d=0;s=0;Offset=0}); $s.Add(@{Op='vasl-h';d=0;s=0;t=3}); $s.Add(@{Op='vstore';s=1;t=0;Offset=0})
    $s.Add(@{Op='addi';d=0;s=0;i=128}); $s.Add(@{Op='addi';d=1;s=1;i=128})
    $s.Add(@{Op='addi';d=2;s=2;i=-1})
    $s.Add(@{Op='gtu';d=0;s=2;t=4})
    $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_vec"})
    if (-not $NoReturn) { $s.Add(@{Op='return'}) }
    $s.ToArray()
}

# Nearest x2 upsampling along frames (stock UpSample1d, F.interpolate scale 2 'nearest'): out frame 2t and 2t+1 <- in
# frame t. Input tile t, vectors 0..7 fill output tile 2t and vectors 8..15 output tile 2t+1, two output vectors each.
# r0 = input tiles, r1 = output tiles (2 * input tiles), r2 = input tiles >= 1. Uses r3..r11, v0..v4, v29, v30.
function New-KokoroFrameDouble16Steps {
    param([ValidateRange(32,2048)][int]$Channels=512,[string]$LabelPrefix='framedouble16',[switch]$NoReturn)
    if ($Channels % 32) { throw 'Channels must be whole 32-channel blocks' }
    $tileBytes = 64 * $Channels
    $s = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL); $s.Add(@{Op='lo';x=$r;i=($u -band 65535)}); $s.Add(@{Op='hi';x=$r;i=($u -shr 16)}) }
    & $imm 3 0x0000FFFFL; $s.Add(@{Op='vsplat';d=29;s=3})
    & $imm 3 0xFFFF0000L; $s.Add(@{Op='vsplat';d=30;s=3})
    $s.Add(@{Op='imm';d=4;i=16}); $s.Add(@{Op='imm';d=7;i=0})
    & $imm 8 $tileBytes
    $s.Add(@{Op='label';Name="${LabelPrefix}_tile"})
    $s.Add(@{Op='addi';d=9;s=0;i=0}); $s.Add(@{Op='addi';d=10;s=1;i=0})            # block b of input tile, output tile 2t
    $s.Add(@{Op='imm';d=5;i=($Channels/32)})
    $s.Add(@{Op='label';Name="${LabelPrefix}_block"})
    $s.Add(@{Op='addi';d=6;s=9;i=0}); $s.Add(@{Op='addi';d=11;s=10;i=0})
    for ($v = 0; $v -lt 16; $v++) {
        if ($v -eq 8) { $s.Add(@{Op='add';d=11;s=10;t=8}) }                     # output tile 2t + 1, same block
        $s.Add(@{Op='vload';d=0;s=6;Offset=0})
        $s.Add(@{Op='vand';d=1;s=0;t=29}); $s.Add(@{Op='vasl-w';d=2;s=0;t=4}); $s.Add(@{Op='vor';d=1;s=1;t=2})   # (row 2v, row 2v)
        $s.Add(@{Op='vand';d=3;s=0;t=30}); $s.Add(@{Op='vlsr-uw';d=4;s=0;t=4}); $s.Add(@{Op='vor';d=3;s=3;t=4}) # (row 2v+1, row 2v+1)
        $s.Add(@{Op='vstore';s=11;t=1;Offset=0}); $s.Add(@{Op='vstore';s=11;t=3;Offset=128})
        $s.Add(@{Op='addi';d=6;s=6;i=128}); $s.Add(@{Op='addi';d=11;s=11;i=256})
    }
    $s.Add(@{Op='addi';d=9;s=9;i=2048}); $s.Add(@{Op='addi';d=10;s=10;i=2048})
    $s.Add(@{Op='addi';d=5;s=5;i=-1})
    $s.Add(@{Op='gtu';d=0;s=5;t=7})
    $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_block"})
    $s.Add(@{Op='add';d=0;s=0;t=8}); $s.Add(@{Op='add';d=1;s=1;t=8}); $s.Add(@{Op='add';d=1;s=1;t=8})
    $s.Add(@{Op='addi';d=2;s=2;i=-1})
    $s.Add(@{Op='gtu';d=0;s=2;t=7})
    $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_tile"})
    if (-not $NoReturn) { $s.Add(@{Op='return'}) }
    $s.ToArray()
}

# decode.3 pool: depthwise ConvTranspose1d(k 3, stride 2, pad 1, output_padding 1) over the LeakyReLU output a (F frames),
# straight into the conv1 input windows at 2F frames:
#     p[2t] = w1 a[t] + b,   p[2t+1] = w2 a[t] + w0 a[t+1] + b       (a[F] = 0)
# Each term is q31(a * 2^16, W) with W the per-channel Q31 multiplier from a's LSB to the window LSB; b in window LSB;
# the sum is clamped to int16 and split into the high ((p >> 8) + 128) and low (p & 255) planes (odd bytes).
# Rows of a past F must hold 0 and one zero tile must follow the input (a[F] for F a multiple of 32).
# r0 = a tiles, r1 = high window tile 0, r2 = low window tile 0, r3 = constants, 512 B per block: W0[32], W1[32], W2[32],
# B[32] (int32), r4 = input tiles >= 1. Uses r0..r15, r28, v0..v21, v30, v31.
function New-KokoroPool2Steps {
    param([ValidateRange(32,2048)][int]$Channels=1120,[string]$LabelPrefix='pool2',[switch]$NoReturn)
    if ($Channels % 32) { throw 'Channels must be whole 32-channel blocks' }
    $tileBytes = 64 * $Channels
    $s = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL); $s.Add(@{Op='lo';x=$r;i=($u -band 65535)}); $s.Add(@{Op='hi';x=$r;i=($u -shr 16)}) }
    $splat = { param([int]$v,[long]$value) & $imm 13 $value; $s.Add(@{Op='vsplat';d=$v;s=13}) }
    & $splat 31 0x80008000L; & $splat 30 0xFFFF0000L
    & $splat 21 128; & $splat 20 255; & $splat 18 32767; & $splat 19 -32768
    foreach ($kv in @(@(8,16),@(9,8),@(12,24),@(7,0))) { $s.Add(@{Op='imm';d=$kv[0];i=$kv[1]}) }
    & $imm 28 $tileBytes
    $mul = { param([int]$d,[int]$x,[int]$w,[switch]$Acc)        # d (+)= q31(x, w)
        if ($Acc) { $s.Add(@{Op='vmpye-w-uh';d=10;s=$x;t=$w}); $s.Add(@{Op='vmpyo-acc-w-h-rnd-sat-shift';d=10;s=$x;t=$w}); $s.Add(@{Op='vadd-w';d=$d;s=$d;t=10}) }
        else { $s.Add(@{Op='vmpye-w-uh';d=$d;s=$x;t=$w}); $s.Add(@{Op='vmpyo-acc-w-h-rnd-sat-shift';d=$d;s=$x;t=$w}) } }
    $clamp = { param([int]$d) $s.Add(@{Op='vadd-w';d=$d;s=$d;t=17}); $s.Add(@{Op='vmax-w';d=$d;s=$d;t=19}); $s.Add(@{Op='vmin-w';d=$d;s=$d;t=18}) }
    # Windows of one output vector from even-row words p and odd-row words q, stored at hi r6 / lo r13 (+ offset).
    $windows = { param([int]$p,[int]$q,[int]$offset)
        $s.Add(@{Op='vasr-w';d=11;s=$p;t=9}); $s.Add(@{Op='vadd-w';d=11;s=11;t=21}); $s.Add(@{Op='vasl-w';d=11;s=11;t=9})
        $s.Add(@{Op='vasr-w';d=12;s=$q;t=9}); $s.Add(@{Op='vadd-w';d=12;s=12;t=21}); $s.Add(@{Op='vasl-w';d=12;s=12;t=12})
        $s.Add(@{Op='vor';d=11;s=11;t=12}); $s.Add(@{Op='vstore';s=6;t=11;Offset=$offset})
        $s.Add(@{Op='vand';d=11;s=$p;t=20}); $s.Add(@{Op='vasl-w';d=11;s=11;t=9})
        $s.Add(@{Op='vand';d=12;s=$q;t=20}); $s.Add(@{Op='vasl-w';d=12;s=12;t=12})
        $s.Add(@{Op='vor';d=11;s=11;t=12}); $s.Add(@{Op='vstore';s=13;t=11;Offset=$offset}) }
    $s.Add(@{Op='addi';d=14;s=0;i=0}); $s.Add(@{Op='addi';d=15;s=1;i=0}); $s.Add(@{Op='addi';d=10;s=2;i=0})   # block 0 bases
    $s.Add(@{Op='imm';d=11;i=($Channels/32)})
    $s.Add(@{Op='label';Name="${LabelPrefix}_block"})
    $s.Add(@{Op='vload';d=14;s=3;Offset=0}); $s.Add(@{Op='vload';d=15;s=3;Offset=128}); $s.Add(@{Op='vload';d=16;s=3;Offset=256}); $s.Add(@{Op='vload';d=17;s=3;Offset=384})
    $s.Add(@{Op='addi';d=5;s=14;i=0}); $s.Add(@{Op='addi';d=6;s=15;i=0}); $s.Add(@{Op='addi';d=13;s=10;i=0})
    $s.Add(@{Op='addi';d=2;s=4;i=0})
    $s.Add(@{Op='label';Name="${LabelPrefix}_tile"})
    $s.Add(@{Op='vload';d=0;s=5;Offset=0}); $s.Add(@{Op='vxor';d=0;s=0;t=31})
    for ($v = 0; $v -lt 16; $v++) {
        if ($v -eq 8) { $s.Add(@{Op='add';d=6;s=6;t=28}); $s.Add(@{Op='addi';d=6;s=6;i=-2048}); $s.Add(@{Op='add';d=13;s=13;t=28}); $s.Add(@{Op='addi';d=13;s=13;i=-2048}) }
        # Next row pair: the next vector, or row pair 0 of the next tile's same block.
        if ($v -lt 15) { $s.Add(@{Op='vload';d=1;s=5;Offset=128}) } else { $s.Add(@{Op='add';d=0;s=5;t=28}); $s.Add(@{Op='addi';d=0;s=0;i=-1920}); $s.Add(@{Op='vload';d=1;s=0;Offset=0}) }
        $s.Add(@{Op='vxor';d=1;s=1;t=31})
        $s.Add(@{Op='vasl-w';d=2;s=0;t=8})                       # a[2v] * 2^16
        $s.Add(@{Op='vand';d=3;s=0;t=30})                        # a[2v+1] * 2^16
        $s.Add(@{Op='vasl-w';d=4;s=1;t=8})                       # a[2v+2] * 2^16
        & $mul 5 2 15; & $clamp 5                                 # p[4v]   = w1 a[2v] + b
        & $mul 6 2 16; & $mul 6 3 14 -Acc; & $clamp 6             # p[4v+1] = w2 a[2v] + w0 a[2v+1] + b
        & $mul 7 3 15; & $clamp 7                                 # p[4v+2] = w1 a[2v+1] + b
        & $mul 8 3 16; & $mul 8 4 14 -Acc; & $clamp 8             # p[4v+3] = w2 a[2v+1] + w0 a[2v+2] + b
        & $windows 5 6 0; & $windows 7 8 128
        $s.Add(@{Op='addi';d=6;s=6;i=256}); $s.Add(@{Op='addi';d=13;s=13;i=256}); $s.Add(@{Op='addi';d=5;s=5;i=128})
        $s.Add(@{Op='vor';d=0;s=1;t=1})                          # the next row pair, bias removed, is the next current one
    }
    # Next input tile; output advances two tiles (the second already reached tile 2t+1 + 1024 B).
    $s.Add(@{Op='add';d=5;s=5;t=28}); $s.Add(@{Op='addi';d=5;s=5;i=-2048})
    $s.Add(@{Op='add';d=6;s=6;t=28}); $s.Add(@{Op='addi';d=6;s=6;i=-2048}); $s.Add(@{Op='add';d=13;s=13;t=28}); $s.Add(@{Op='addi';d=13;s=13;i=-2048})
    $s.Add(@{Op='addi';d=2;s=2;i=-1})
    $s.Add(@{Op='gtu';d=0;s=2;t=7})
    $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_tile"})
    $s.Add(@{Op='addi';d=3;s=3;i=512})
    $s.Add(@{Op='addi';d=14;s=14;i=2048}); $s.Add(@{Op='addi';d=15;s=15;i=2048}); $s.Add(@{Op='addi';d=10;s=10;i=2048})
    $s.Add(@{Op='addi';d=11;s=11;i=-1})
    $s.Add(@{Op='gtu';d=0;s=11;t=7})
    $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_block"})
    if (-not $NoReturn) { $s.Add(@{Op='return'}) }
    $s.ToArray()
}

# F0_conv / N_conv: Conv1d(1, 1, k 3, stride 2, pad 1) of a curve c (2F int32 samples, c[-1] = 0) into one channel of a
# tensor, frames 0 .. F-1:  v[t] = (W0 c[2t-1] + W1 c[2t] + W2 c[2t+1] + B + 2^14) >> 15, clamped to int16, stored biased.
# r0 = curve, r1 = tensor tile 0, r2 = constants W0, W1, W2 (int32), B (int64) at 0, 4, 8, 16. Rows past F are untouched.
# Uses r3..r15 (callee-saved registers are not touched).
function New-KokoroStrideConv16Steps {
    param([Parameter(Mandatory)][ValidateRange(1,1048576)][int]$Frames,[ValidateRange(32,2048)][int]$Channels=1120,
        [Parameter(Mandatory)][ValidateRange(0,2047)][int]$Channel,[string]$LabelPrefix='strideconv16',[switch]$NoReturn)
    $tileBytes = 64 * $Channels
    $s = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL); $s.Add(@{Op='lo';x=$r;i=($u -band 65535)}); $s.Add(@{Op='hi';x=$r;i=($u -shr 16)}) }
    & $imm 3 ([long][math]::Floor($Channel / 32) * 2048 + 4 * ($Channel % 32)); $s.Add(@{Op='add';d=1;s=1;t=3})   # row 0 of the channel
    $s.Add(@{Op='load';d=12;s=2;Offset=0}); $s.Add(@{Op='load';d=13;s=2;Offset=4}); $s.Add(@{Op='load';d=14;s=2;Offset=8})
    $s.Add(@{Op='imm';d=3;i=0})                                   # c[2t-1], zero for t = 0
    $s.Add(@{Op='imm';d=11;i=$Frames}); $s.Add(@{Op='imm';d=15;i=0})
    & $imm 7 ($tileBytes - 2048)
    $s.Add(@{Op='label';Name="${LabelPrefix}_tile"})
    $s.Add(@{Op='imm';d=10;i=32})
    $s.Add(@{Op='label';Name="${LabelPrefix}_row"})
    $s.Add(@{Op='load';d=4;s=0;Offset=0}); $s.Add(@{Op='load';d=5;s=0;Offset=4})
    $s.Add(@{Op='load-d';d=8;s=2;Offset=16})                      # B
    $s.Add(@{Op='mpy-d';d=6;s=3;t=12}); $s.Add(@{Op='add-d';d=8;s=8;t=6})
    $s.Add(@{Op='mpy-d';d=6;s=4;t=13}); $s.Add(@{Op='add-d';d=8;s=8;t=6})
    $s.Add(@{Op='mpy-d';d=6;s=5;t=14}); $s.Add(@{Op='add-d';d=8;s=8;t=6})
    $s.Add(@{Op='imm';d=6;i=16384}); $s.Add(@{Op='imm';d=7;i=0}); $s.Add(@{Op='add-d';d=8;s=8;t=6})
    & $imm 7 ($tileBytes - 2048)
    $s.Add(@{Op='asr-d-i';d=8;s=8;i=15})
    & $imm 6 32767; $s.Add(@{Op='min';d=8;s=8;t=6}); & $imm 6 -32768; $s.Add(@{Op='max';d=8;s=8;t=6})
    & $imm 6 0x8000; $s.Add(@{Op='xor';d=8;s=8;t=6})
    $s.Add(@{Op='store-h';s=1;t=8;Offset=0})
    $s.Add(@{Op='addi';d=3;s=5;i=0}); $s.Add(@{Op='addi';d=0;s=0;i=8})
    # Next row: odd rows sit 2 bytes after their even row; the next even row 126 bytes after an odd one.
    $s.Add(@{Op='addi';d=9;s=10;i=0}); & $imm 6 1; $s.Add(@{Op='and';d=9;s=9;t=6})
    $odd = "${LabelPrefix}_even"; $next = "${LabelPrefix}_next"
    $s.Add(@{Op='eq';d=0;s=9;t=15}); $s.Add(@{Op='jump-p';u=0;Label=$odd})
    $s.Add(@{Op='addi';d=1;s=1;i=126}); $s.Add(@{Op='eq';d=0;s=15;t=15}); $s.Add(@{Op='jump-p';u=0;Label=$next})
    $s.Add(@{Op='label';Name=$odd}); $s.Add(@{Op='addi';d=1;s=1;i=2})
    $s.Add(@{Op='label';Name=$next})
    $s.Add(@{Op='addi';d=11;s=11;i=-1})
    $done = "${LabelPrefix}_done"
    $s.Add(@{Op='eq';d=0;s=11;t=15}); $s.Add(@{Op='jump-p';u=0;Label=$done})
    $s.Add(@{Op='addi';d=10;s=10;i=-1})
    $s.Add(@{Op='gtu';d=0;s=10;t=15})
    $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_row"})
    $s.Add(@{Op='add';d=1;s=1;t=7})                               # row 32 position is row 0 of the next tile
    $s.Add(@{Op='eq';d=0;s=15;t=15}); $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_tile"})
    $s.Add(@{Op='label';Name=$done})
    if (-not $NoReturn) { $s.Add(@{Op='return'}) }
    $s.ToArray()
}
