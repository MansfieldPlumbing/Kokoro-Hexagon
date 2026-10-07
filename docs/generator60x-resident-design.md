# Generator 60x resident stage: layout and pass plan

Status: built and proved (`docs/results/generator60x-resident-sm8550-20261007.md`): bit-exact in
the V73 simulator and 3/3 on SM8550, median 86.3 ms against 638.9 ms. The frozen workers (`Kokoro.ResBlockRun.ps1`, `Kokoro.Generator60xRun.ps1`) are
unchanged; their output SHA-256 `1D23542E…` is the equivalence target. The quality
reference stays the stock FP32 capture: an output equal to `1D23542E…` has the frozen
receipt's error against stock (22.67 dB SNR) by construction.

## Today's buffers and passes (frozen worker, per resblock)

DDR workspace, five tensors of `tiles * 8192` bytes plus coefficients:
`W0` residual stream, `W1` AdaIN output (signed Q8 halfwords), `W2` Snake output,
`W3` conv output, `W4` residual skip copy. VTCM holds one 8-tile conv window, one stage of
weights and one parameter record. Per stage: moments pass, coefficients, AdaIN pass,
Snake pass, 31 batches of `zero window -> memcpy -> HMX conv -> memcpy out`, then a copy or
the residual. 82 full-tensor passes over DDR per group.

## Representation

The native layout is 2 bytes per value: the `activation.ub :single` read holds 32 rows per
2048-byte crouton and u8 values sit in odd bytes. One 128-channel tensor at 7,801 frames is
244 tiles × 8192 = 1,998,848 B (the 998,528 B in `docs/ROADMAP.md` is the dense u8 count).

Every consumer of `R` and `C` (AdaIN, moments, residual, mean) reads only the odd bytes
(shifts 8 and 24), and the frozen fixture's input and expected output have no non-zero
even byte. Storing `R` and `C` as dense u8 is therefore a storage-format change with no
requantization; it remains an experiment until it is built and proved.

## Pass plan (built)

The conv input is a window of `B + 2` tiles produced just ahead of each conv by the fused
AdaIN + Snake body (`Kokoro.AdaInSnakeInteger.ps1`, bit-exact against frozen affine ->
Snake in the V73 simulator, 18/18 stage parameter sets). Halo tiles are recomputed.

Per branch (K = 3, 7, 11), per dilation pair (1, 3, 5):

1. Stage input: DMA DDR -> `R`. Its moments are computed once (branch 0) and reused.
2. First half: coefficients from `R` moments; per batch fused `R -> window`, HMX conv
   `window -> C`; epilogue accumulates `C` moments (`Kokoro.AdaInStatisticsAccumulate.ps1`).
3. Second half: coefficients from `C` moments; per batch fused `C -> window`, HMX conv
   `window -> O`; epilogue residual `R += O`, then moments of the new `R`.
4. Branches 0 and 1 leave by DMA to DDR; the mean brings them back in two chunks into the
   free `C` region and writes the output by DMA.

Padded rows follow the frozen worker exactly: zero for moments, zero point 128 at the conv
input, and the residual skip keeps its unmasked padded rows (saved tile `S`). DDR is
touched only by DMA, so no HVX pass depends on cache coherence with DMA-written DDR.

## VTCM rule found while building

In the V73 simulator an HMX activation read (`activation.ub = mxmem(..):single`) that
straddles the 4 MiB VTCM boundary faults (exception 0x26, VMEM address error). The same
conv with activations, weights, output or column tables wholly above 4 MiB is exact, and
HMX output stores and weight reads across the boundary are exact. Activation reads span a
crouton plus the next tile, so the operand extent, not its base, decides. Planner rule: the
conv-input window lies inside one 4 MiB page; the layout puts the small regions first and
refuses any layout that breaks the rule. Not yet tested on a phone.

## Fit at 4 MiB (2048-byte alignment, 2-byte representation)

| Region | Bytes |
| --- | ---: |
| conv-input window, `B + 2` tiles | 8,192 × (B + 2) |
| conv2 output staging, `B` tiles | 8,192 × B |
| weights, one stage, K = 11 | 180,224 |
| parameter record, moments, input moments, mean parameters, saved skip tile, 18 coefficient sets | 36,880 (38,912 aligned) |
| DMA descriptors | 0 (DDR frame) |
| `R`, `C` | 2 × 8,192 × tiles |

`B = 16`: 225 tiles, 7,200 frames (1.50 s of audio at 24 kHz, hop 5). `B = 8`: 233 tiles,
7,456 frames. 7,801 frames never fits at 4 MiB in this representation (`R` + `C` leave
196,608 B; the fixed regions need at least 251,904 B). With dense u8 `R`/`C` at `B = 16`
the limit is about 451 tiles (14,432 frames, 3.0 s). Longer groups take the tiled path.
The current emission uses 64 KiB region alignment (4,653,056 B at 7,801 frames, 8 MiB tier).
