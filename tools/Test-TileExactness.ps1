#requires -Version 7.4
# Exactness of channel tiling and stride-5 phase folding on a real late-generator tensor.
# No device, no compile: the question is whether the transforms change the arithmetic.
param(
    [string] $Tensor = 'C:\Dev\Build\Kokoro-QNN\candidates\c64\gen\oracle_u.f32',
    [int] $Channels = 128,
    [int] $Tile = 32,
    [int] $Phases = 5
)
$ErrorActionPreference = 'Stop'

[byte[]]$raw = [IO.File]::ReadAllBytes($Tensor)
[int]$total = $raw.Length / 4
[int]$T = $total / $Channels
[int]$Tfold = [int]([Math]::Floor($T / $Phases)) * $Phases      # fold needs a multiple of the stride
'tensor {0}  [1,{1},{2}]  foldable time {3} ({4} dropped as tail)' -f (Split-Path $Tensor -Leaf), $Channels, $T, $Tfold, ($T - $Tfold)

[float[]]$x = [float[]]::new($Channels * $Tfold)
for ([int]$c = 0; $c -lt $Channels; $c++) {
    for ([int]$t = 0; $t -lt $Tfold; $t++) { $x[$c * $Tfold + $t] = [BitConverter]::ToSingle($raw, ($c * $T + $t) * 4) }
}

# Per-channel affine and Snake alpha, deterministic so the comparison is reproducible.
[double[]]$gamma = [double[]]::new($Channels); [double[]]$beta = [double[]]::new($Channels); [double[]]$alpha = [double[]]::new($Channels)
for ([int]$c = 0; $c -lt $Channels; $c++) { $gamma[$c] = 0.75 + $c / 512.0; $beta[$c] = -0.25 + $c / 1024.0; $alpha[$c] = 0.5 + $c / 256.0 }
[double]$eps = 1e-5

# AdaIN over the whole time axis, then Snake. Both are per-channel; nothing crosses channels.
$chain = {
    param([int]$c0, [int]$c1, [float[]]$src, [float[]]$dst)
    for ([int]$c = $c0; $c -lt $c1; $c++) {
        [int]$base = $c * $Tfold
        [double]$s = 0
        for ([int]$t = 0; $t -lt $Tfold; $t++) { $s += $src[$base + $t] }
        [double]$mean = $s / $Tfold
        [double]$sq = 0
        for ([int]$t = 0; $t -lt $Tfold; $t++) { [double]$d = $src[$base + $t] - $mean; $sq += $d * $d }
        [double]$inv = 1.0 / [Math]::Sqrt($sq / $Tfold + $eps)
        [double]$g = $gamma[$c]; [double]$b = $beta[$c]; [double]$a = $alpha[$c]
        for ([int]$t = 0; $t -lt $Tfold; $t++) {
            [double]$y = ($src[$base + $t] - $mean) * $inv * $g + $b
            [double]$sn = [Math]::Sin($a * $y)
            $dst[$base + $t] = [float]($y + $sn * $sn / $a)
        }
    }
}

$sw = [Diagnostics.Stopwatch]::StartNew()
[float[]]$whole = [float[]]::new($x.Length)
& $chain 0 $Channels $x $whole
'whole-tensor pass {0:N0} ms' -f $sw.ElapsedMilliseconds

# (1) channel tiles: identical arithmetic, just fewer channels resident at a time
$sw.Restart()
[float[]]$tiled = [float[]]::new($x.Length)
for ([int]$c0 = 0; $c0 -lt $Channels; $c0 += $Tile) {
    [int]$c1 = [Math]::Min($c0 + $Tile, $Channels)
    & $chain $c0 $c1 $x $tiled
}
[double]$dTile = 0
for ([int]$i = 0; $i -lt $x.Length; $i++) { [double]$d = [Math]::Abs([double]$whole[$i] - [double]$tiled[$i]); if ($d -gt $dTile) { $dTile = $d } }
'channel tile ({0} ch)      maxAbsDiff = {1:E3}   {2:N0} ms' -f $Tile, $dTile, $sw.ElapsedMilliseconds

# (2) naive phase fold: treat each stride-5 phase as its own channel, so AdaIN's statistics
#     are taken over T/5 interleaved samples instead of the whole time axis.
$sw.Restart()
[int]$Tp = $Tfold / $Phases
[float[]]$naive = [float[]]::new($x.Length)
for ([int]$c = 0; $c -lt $Channels; $c++) {
    [int]$base = $c * $Tfold
    [double]$g = $gamma[$c]; [double]$b = $beta[$c]; [double]$a = $alpha[$c]
    for ([int]$p = 0; $p -lt $Phases; $p++) {
        [double]$s = 0
        for ([int]$k = 0; $k -lt $Tp; $k++) { $s += $x[$base + $k * $Phases + $p] }
        [double]$mean = $s / $Tp
        [double]$sq = 0
        for ([int]$k = 0; $k -lt $Tp; $k++) { [double]$d = $x[$base + $k * $Phases + $p] - $mean; $sq += $d * $d }
        [double]$inv = 1.0 / [Math]::Sqrt($sq / $Tp + $eps)
        for ([int]$k = 0; $k -lt $Tp; $k++) {
            [double]$y = ($x[$base + $k * $Phases + $p] - $mean) * $inv * $g + $b
            [double]$sn = [Math]::Sin($a * $y)
            $naive[$base + $k * $Phases + $p] = [float]($y + $sn * $sn / $a)
        }
    }
}
[double]$dNaive = 0
for ([int]$i = 0; $i -lt $x.Length; $i++) { [double]$d = [Math]::Abs([double]$whole[$i] - [double]$naive[$i]); if ($d -gt $dNaive) { $dNaive = $d } }
'phase fold, naive stats    maxAbsDiff = {0:E3}   {1:N0} ms' -f $dNaive, $sw.ElapsedMilliseconds

# (3) phase fold with a cross-phase reduction: partial sums per phase, combined before
#     the statistics are used, so the reduction still spans the real time axis.
$sw.Restart()
[float[]]$fixed = [float[]]::new($x.Length)
for ([int]$c = 0; $c -lt $Channels; $c++) {
    [int]$base = $c * $Tfold
    [double]$g = $gamma[$c]; [double]$b = $beta[$c]; [double]$a = $alpha[$c]
    [double]$s = 0
    for ([int]$p = 0; $p -lt $Phases; $p++) {
        [double]$sp = 0
        for ([int]$k = 0; $k -lt $Tp; $k++) { $sp += $x[$base + $k * $Phases + $p] }
        $s += $sp
    }
    [double]$mean = $s / $Tfold
    [double]$sq = 0
    for ([int]$p = 0; $p -lt $Phases; $p++) {
        [double]$sqp = 0
        for ([int]$k = 0; $k -lt $Tp; $k++) { [double]$d = $x[$base + $k * $Phases + $p] - $mean; $sqp += $d * $d }
        $sq += $sqp
    }
    [double]$inv = 1.0 / [Math]::Sqrt($sq / $Tfold + $eps)
    for ([int]$p = 0; $p -lt $Phases; $p++) {
        for ([int]$k = 0; $k -lt $Tp; $k++) {
            [double]$y = ($x[$base + $k * $Phases + $p] - $mean) * $inv * $g + $b
            [double]$sn = [Math]::Sin($a * $y)
            $fixed[$base + $k * $Phases + $p] = [float]($y + $sn * $sn / $a)
        }
    }
}
[double]$dFixed = 0
for ([int]$i = 0; $i -lt $x.Length; $i++) { [double]$d = [Math]::Abs([double]$whole[$i] - [double]$fixed[$i]); if ($d -gt $dFixed) { $dFixed = $d } }
'phase fold, cross-phase    maxAbsDiff = {0:E3}   {1:N0} ms' -f $dFixed, $sw.ElapsedMilliseconds

''
'VTCM residency at fp16, three live tensors:'
foreach ($F in 64, 96, 128, 160) {
    [int]$Tf = 120 * $F + 1
    [double]$oneFull = $Channels * $Tf * 2 / 1MB
    [double]$oneTile = $Tile * $Tf * 2 / 1MB
    '  F={0,-4} T={1,-6} full {2,6:F2} MiB -> 3 live {3,6:F2}   tile({4}) {5,5:F2} MiB -> 3 live {6,5:F2}' -f $F, $Tf, $oneFull, (3 * $oneFull), $Tile, $oneTile, (3 * $oneTile)
}
