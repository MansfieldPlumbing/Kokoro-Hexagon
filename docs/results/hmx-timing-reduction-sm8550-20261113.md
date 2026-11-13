# HMX timing and FP16 reduction order, SM8550

Kokoro-Hexagon `54331e1`, on the same SM8550 phone as `hmx-vtcm-pages-sm8550-20261113.md`. The question: is HMX
systolic? Every experiment's prediction was written before it ran.

Ran from a scratch harness that edits `New-KokoroHmxConvRunSteps`'s step list and emits it through
`Invoke-HexagonEmission -Kernel Definition`; it is not yet a `Run -Case`. The harness writes `runner-layout.json`, which
the JSON census in `Verify` does not admit in a tracked script, so it is kept with the receipt:
`build/hmx-timing-reduction-20261113/` (scripts, models, predictions, results and raw CSVs, with `manifest.csv` of
SHA-256s).

## Timing

**Per pair, per store (19.2 MHz ticks).** `HmxConvRun` at 128 and 256 channels, kernels 3, 7 and 11, 8 to 64 tiles:
8.2 to 8.8 ns per activation-and-weight pair. Time is not linear in tiles (residuals 8 to 12 percent); the first tile
of a conv costs about 24 ticks (1.25 us) more than each further one, a cold start.

**Exposed drain.** The same conv with a scalar load and `syncht` after every accumulator store, against without, 32
tiles, one 4 MiB page: 80 to 93 ns more per store, constant from 4 to 88 pairs per group and at both channel counts.
`syncht` alone costs about 53 ns (2 runs), so the drain itself is about 27 to 40 ns. Too coarse to decide.

**Cycle-counted latency.** The conv replaced by one warm-up group and one timed group: sentinel, clear, n pairs, one
store, then polling the stored word; `upcycle` at 1,401.6 MHz, 21 runs per point, medians:

| Probe | Cycles |
| --- | ---: |
| two counter reads | 3 |
| scalar store, then poll | 57 to 67 |
| HMX, 1 / 2 / 4 / 8 / 16 / 32 / 64 pairs | 129 / 134 / 163 / 186 / 249 / 417 / 713 |

Fit: **106 to 116 + 9.3 to 9.5 n cycles**, linear within 16 cycles. Pairs stream at about 9.4 cycles (6.7 ns) each;
HMX's own fixed latency beyond a scalar store and poll is about **40 to 59 cycles**, independent of n. Every poll was
satisfied by its first load: the core holds a load to the stored address until the store lands.

**Visibility by position.** 8 pairs, polling offsets 0, 4, 1020, 1024, 1028, 2040 and 2044 of the stored crouton:
186 to 195 cycles, equal within run noise. A load from the next crouton, which the store does not touch, returns after
**84** cycles. The core holds loads per crouton and releases the crouton whole, so any drain wave inside HMX is not
observable from scalar loads. The 84 cycles also show the core is held to HMX's rate while issuing pairs (8 pairs at
~9.4 cycles); last pair issued to result visible is about 100 cycles.

## FP16 reduction order

One pointwise FP16 conv through `New-KokoroHmxConvSteps -Fp16` (128 inputs in 4 blocks of 32, one 32-row tile), packed
and decoded with `tools/Kokoro.CaptureKernels.psm1`'s FP16 crouton, weight and table kernels. Output channel 0 weighs
every input 1, so each row's output is the sum of that row's inputs. Validation: 32 rows of small integers come back as
the exact sums; outputs 1 to 31 are 0.

Rows place B = 2^15, -B and s = 2^-10 (or -s, or 2^-6) at chosen channels; in fp32, B + s rounds back to B, so which
rows keep s shows the order of addition. 160 rows over five jobs:

1. **A chain, not a tree.** B and -B at channels 30 and 31 lose s at every earlier channel; an adder tree would cancel
   them first and keep s. Tree models fit 45 of 128 rows.
2. **Ascending channel order, 4 products at a time.** With B and -B at 0 and 1, s at 2 or 3 is lost and at 4 survives;
   the same boundary at 7|8 and 71|72|73. Groups of 2, 8, 16 or 32 do not fit.
3. **A 24-bit significand, rounded to odd.** A lost s leaves exactly one unit of the 2^-8 grid set by the largest
   operand, with the sign of what was lost: B - s - B gives -2^-8, and B + s + s - B gives 2^-8, not 2^-7 (the group
   is summed exactly, then rounded once). 2^-6 survives in any order, as fp32 requires.

Model: groups of 4 in ascending order; each step sums the running total and the group's 4 products exactly and rounds
to odd on the grid of the largest operand. **156 of 160 rows bit for bit.** The 4 others all have small terms in two
different groups, one of them cancelling a B; the rounding of the running total between groups is not fully captured
(a two-level variant fits 126 of 160).

**The misses are in the reduction, not the output conversion.** The 32 confirmation rows (the 4 misses among them)
were run again at conversion scales 1.0, 2.0 and 0.5 (FP16, bias 0), predicted to scale exactly if conversion plays no
part. Every row at scale k equals k times its scale-1 output, bit for bit (the one row whose value overflows FP16 at 2.0
is infinity, as expected), and the scale-1 job reproduces the earlier run bit for bit. The loss itself also happens
before cancellation: a final sum of exactly 2^-10 would convert to FP16 exactly, but the output is 2^-8.

Qualcomm's V81 HMX reference describes a 37-bit floating-point accumulator followed by a separate FP16 conversion. V81
is not V73, and bit-exact behaviour is not promised across versions. A float that wide would keep s next to B, so on
V73 either the accumulator is narrower or the 24-bit window observed here belongs to an earlier stage, such as aligning
each group's products for the fused add, ahead of a wider accumulator. The 4 misses are where those two would differ.

## What this says about systolic

A systolic array reduces along its reduction dimension as a chain: each stage adds its products to the partial sum it is
handed. HMX's FP16 reduction is that chain, in channel order, in 4-product fused steps; its timing is streamed operands
behind a fixed drain independent of how many were accumulated. Not separated: a chain laid out in space (systolic) from
one 4-wide unit reused in time, which give the same numbers and the same times.

## Not established

- The rounding of the running total between groups (the 4 rows above), and whether the 24-bit window belongs to the
  accumulator or to the products' alignment ahead of it.
- The int8 path's accumulator and order; only the FP16 path was fingerprinted.
- Space against time for the chain.
- Whether `syncht`'s own cost overlaps the drain.
