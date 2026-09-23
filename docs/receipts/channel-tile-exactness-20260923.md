# Channel tiling is exact; the naive phase fold is not

Host-only, on a real late-generator tensor. No device, no compile. Reproduce with
`tools/Test-TileExactness.ps1`.

Tiles belong on physical axes — channels, phases, working-set geometry. The temporal axis
is semantic (breath groups) and is not a tile size.

## Shapes

Late generator, 64-frame bundle, T = 120F + 1:

```
x0 [1,128,512]   x1 [1,128,2560]   xp/z/u/r0/r1/r2/n [1,128,7681]
post [1,22,7681] -> post8 [1,22,7688] -> audio [1,1,33600]
```

## Result

AdaIN (per-channel statistics over time, per-channel affine) followed by Snake
`x + sin^2(ax)/a`, applied to `oracle_u.f32`:

```
channel tile (32 ch)      maxAbsDiff = 0.000E+000
phase fold, naive stats   maxAbsDiff = 2.259E+000
phase fold, cross-phase   maxAbsDiff = 0.000E+000
```

Channel tiling is bit-exact because nothing in that chain crosses channels. Full Conv1d
does mix channels and must stay whole, reading the full input and writing output-channel
tiles; that is not a limitation in practice, because convolution is not the bottleneck —
the elementwise volume is, and the elementwise volume is the separable part.

The stride-5 phase fold `[1,128,T] -> [1,640,T/5]` partitions the time axis into five
interleaved subsets. Treating those as independent channels makes AdaIN take statistics
over T/5 samples, which is wrong by 2.26 on order-1 data. It compiles, finalizes, executes
and returns no error — the same failure shape as Resize. The fold is usable only with a
cross-phase reduction that combines the five partial sums before the statistics are used,
which restores bit-exactness.

T is not divisible by 5 (7681 = 5*1536 + 1), so a fold also needs a defined tail policy.

## Residency

fp16, three live tensors, which is the floor for a resblock:

```
F=64   T=7681    full 1.88 MiB -> 5.63    tile(32) 0.47 -> 1.41
F=96   T=11521   full 2.81 MiB -> 8.44    tile(32) 0.70 -> 2.11
F=128  T=15361   full 3.75 MiB -> 11.25   tile(32) 0.94 -> 2.81
F=160  T=19201   full 4.69 MiB -> 14.06   tile(32) 1.17 -> 3.52
```

VTCM is 8 MiB. Full tensors cross it between F=64 and F=96, and the measured per-frame
cost steps at the same place: 5.35, 6.10, 9.04 ms/frame at F=64, 96, 128. Earlier framing
of this as a capacity effect was wrong; it is a residency cliff. Tiled at 32 channels the
live set is 3.52 MiB at the longest window, so residency stops depending on phrase length.

Channel tiling relocates bytes from DDR to VTCM; it does not reduce them. Reducing the
number of full-tensor passes is a separate win and belongs to fusion. Measure bytes moved
per output frame, not op count.

## Emission entropy baseline

`gen_c64_banal_ctx_qnn.bin`, 41,672,704 bytes, 240 windows of 64 KiB:

```
min 2.82  p10 5.12  p50 7.35  p90 7.44  max 7.61  mean 6.91 bits/byte
```

Dense fp16 sits near 7.3-7.5 because the high byte carries correlated sign and exponent.
The p10 is where structure and padding live. Anything we emit ourselves should hold the
median and shrink the low tail, with every low-entropy region attributable to a named
section rather than to duplicated op structure.
