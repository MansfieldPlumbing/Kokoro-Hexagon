# Frozen activation-range pilot — connected resblocks.3, 2026-10-06

Baseline commit `8cc06b96e9dd5546dfd76da40f59967be55d1789`, with local uncommitted
tools. Stock Kokoro source `dfb907a02bba8152ca444717ca5d78747ccb4bec`.

Two calibration groups: af_heart, 14 phonemes, seed 17, 7,801 frames;
am_michael, 7 phonemes, seed 17, 6,841 frames. Separate holdouts:
af_heart, 7 phonemes, seed 23, 6,601 frames; am_michael, 13 phonemes,
seed 29, 8,521 frames. Both voices occur in calibration and validation;
this is not evidence for unseen-voice generalization.

Pooled calibration captures define 16 shared per-tensor activation boundaries.
Full range, absolute percentiles 99.9 and 99.99, and an approximate histogram
MSE search (8,192 bins, 128 thresholds) were frozen before holdout evaluation.
Holdout values never select scales. Symmetric signed range -127..127, zero
point 128 for offline input packing; emitted operators retain their existing
unsigned 0..255 output bounds. Per-output-channel W8 checkpoint weights remain unchanged.

The existing eight SDK-checked emitted bodies are hash-verified and reused.
All live model arithmetic runs in those bodies in `hexagon-sim -mv73`;
C performs reference-only staging. Test frame limits now cover up to 32,768
frames using compile-sized DDR buffers and the same eight-tile VTCM batches.
No kernel or instruction encoding changed.
Frozen scales also avoid redundant full-tensor maximum scans in the packer;
six packed files were checked byte for byte against a completed earlier fixture.

| Holdout | Frozen ranges | Final SNR vs stock (dB) | Final RMSE | Maximum error | Initial values outside range | Side-path clipping events |
|---|---|---:|---:|---:|---:|---:|
| hold-heart | full-range | 18.711 | 0.721986 | 8.176 | 0 | 1 |
| hold-heart | histogram-mse | 22.184 | 0.484018 | 44.903 | 29 | 196 |
| hold-heart | percentile-99.9 | 17.874 | 0.795044 | 108.384 | 869 | 5314 |
| hold-heart | percentile-99.99 | 21.839 | 0.503663 | 79.161 | 64 | 448 |
| hold-michael | full-range | 18.46 | 0.713958 | 7.26 | 2 | 10 |
| hold-michael | histogram-mse | 21.629 | 0.495695 | 34.929 | 67 | 399 |
| hold-michael | percentile-99.9 | 17.065 | 0.838358 | 98.41 | 1063 | 7715 |
| hold-michael | percentile-99.99 | 21.037 | 0.530664 | 69.187 | 124 | 898 |

All eight runs have zero integer-contract mismatches for AdaIN coefficients,
affine, Snake and residual operations. Convolution error is measured against
captured stock FP32; this pilot does not separately prove each convolution's
integer arithmetic. Clipping events count values at each side-path operation,
so one value can contribute at several boundaries. HMX endpoint counts are
recorded separately in the full results, not treated as proven clipping.

Histogram MSE has the lowest final RMSE of these four candidates on both
holdouts: reductions of approximately 33% and 31% versus full range. Its
maximum absolute tensor error is higher (44.90 versus 8.18; 34.93 versus 7.26).
The 99.9-percentile candidate improves first-stage AdaIN on the af_heart
holdout to 30.35 dB yet worsens final block SNR to 17.87 dB. Local error alone
does not select a connected encoding set.

Retain histogram MSE as the candidate beside the full-range baseline for the
next device/integration comparison. Preserve this peak-error tradeoff in
subsequent stock-output and generated-audio checks; no production encoding
is selected from this two-group pilot. Continue the stock integer DSP path.

This small pilot supports choosing the next bounded calibration step. It does
not define a production range set, an audio-quality threshold, phone correctness,
speech, or throughput. The 18.36 dB earlier result used a different capture and
its own ranges, so the valid comparison here is within each holdout.

Reference guidance: [AIMET QuantSim](https://github.com/qualcomm/aimet/blob/6f1416e0bc3868a1dc43ce48072a4d5fe778f042/Docs/tutorials/quantsim.rst).
No AIMET dependency is introduced. Python remains Windows reference-only;
PowerShell quantizes and packs all emitted-region fixtures.

Full results and source/artifact digests: ignored
`build/calibration-pilot-20261006/study-results.json` and `study-provenance.json`.
Study-results SHA-256: `445D23440D68BDEEB7E58865EB13CE0B3FBE6B0ABAC5E1A924498625AF4FFEC6`.
