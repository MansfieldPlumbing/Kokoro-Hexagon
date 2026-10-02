# Channel tiling at the generator's real tensor size

SM8550 / Hexagon V73, 8 MB VTCM requested through a graph config. AdaIN — per-channel
statistics over time then a per-channel affine — over `[1,128,19200]` fp32, built whole and
built as N chains of `[1,C/N,19200]`. Identical arithmetic and identical total work; only
the channel extent per op changes. Graphs built through the C API, so no compile.
Reproduce with `src/runspace/TileBench.ps1`.

## Result

```
Tile=128  chains=1  ctxBytes=851,968  meanMs=50.4  p50=49.0  min=47.1
Tile=64   chains=2  ctxBytes=958,464  meanMs=36.5  p50=37.1  min=33.4
Tile=32   chains=4  ctxBytes=835,584  meanMs=36.5  p50=36.3  min=34.0
Tile=16   chains=8  ctxBytes=471,040  meanMs=33.2  p50=33.3  min=32.1
```

1.52x faster and 45% smaller at a 16-channel tile. Most of the time is recovered by the
first split; 64, 32 and 16 are within 10% of each other.

This is the same conclusion reached independently by three earlier measurements: the
working set crosses 8 MiB VTCM between F=64 and F=96 while per-frame cost steps 5.35 ->
6.10 -> 9.04 ms; container overhead tracks an individual tensor's element count and
saturates; and the tiling is bit-exact for this chain (maxAbsDiff 0.000E+000).

## What it implies for RTF

Audio is 25 ms per frame, so for a fitted bucket RTF is ms-per-frame / 25.

```
              current       x1.52    RTF
c64    5.35 ms/frame  ->  3.52  ->  0.141
c96    6.10           ->  4.01  ->  0.160
c128   9.04           ->  5.95  ->  0.238
c160   8.63           ->  5.68  ->  0.227
```

Corpus mean 0.372 -> about 0.245 if the generator is dominated by tileable elementwise
chains, or 0.284 at a pessimistic 70%. The competitor reference is 0.29 mean on V75, a
faster part.

That projection is arithmetic on one chain, not a measurement of the generator. It becomes
a claim only when a tiled generator runs the corpus and speaks.

## Caveat

This measures AdaIN, which is the bulk of the elementwise volume but not the whole
generator. Convolutions mix channels and must stay whole, reading the full input and
writing output-channel tiles; earlier profiling found convolution is not the bottleneck.
