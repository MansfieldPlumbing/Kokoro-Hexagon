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

Correction (2026-10-09, decoder job): the fault is at 1 MiB boundaries, not only 4 MiB. Two `:single` reads with dY 0x11800
(1120-channel tiles) faulted the same way (exception 0x26, badva at the activation and weight operands): Rs at VTCM offset
0x1EE800 and Rs at 0xEE800. Operand contract: Qualcomm Hexagon V81 HMX PRM, 80-N2040-62 Rev. AA, sec. 4.4.1 (V81, not V73):
`activation ... :single` builds one tile from two 2 KiB croutons, the first at Rs[31:11] and the second at Rs + dY, dY a
signed byte displacement in Rt[31:11] (spatial offset Rs[10:7], Rs[1]; channels Rs[6:2]..Rt[6:2]). In both faults the second
crouton starts exactly on a boundary (0x200000, 0x100000), so the two croutons of one read lay in different 1 MiB pages.
The V73 HVX PRM, 80-N2040-54 Rev. AB, sec. 3.3, requires VTCM to be translated like other memory and forbids
scatter/gather regions from crossing a page. Exception 0x26 is the coprocessor VMEM address error in the V73 PRM (Table 8-15), not a read TLB miss (0x70).
Hypothesis [open]: the two croutons of one `:single` read may not lie in different regions, either translation pages
or a fixed HMX access region; the region was at most 1 MiB in the simulator and is not yet measured on the phone. Planned
probes: a 2 KiB-step boundary sweep at fixed dY, a negative dY, and `:single` against a plain read of the same bytes. The decoder layout keeps each HMX-read region plus one
tile and a crouton inside one 1 MiB page, which satisfies the rule under either mapping (`Get-KokoroDecoder16Layout`). The
generator's 4 MiB check is weaker; its layouts have not been audited against 1 MiB.