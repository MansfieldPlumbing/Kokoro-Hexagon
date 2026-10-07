# Resident generator 60x stage on SM8550 — 2026-10-07

Stock Kokoro `dfb907a02bba8152ca444717ca5d78747ccb4bec` (`istftnet.py`, resblocks.3/4/5 and
their mean), checkpoint SHA-256 `496DBA11…`. Base commit `f5d9a19` plus uncommitted files.
Design: `docs/generator60x-resident-design.md`. Emitter:
`src/emit/Kokoro.Generator60xResidentRun.ps1`; new bodies `Kokoro.AdaInSnakeInteger.ps1`
and `Kokoro.AdaInStatisticsAccumulate.ps1`; DMA from `Kokoro.DmaCopy.ps1`.

Skel `libkokoro_resblock_run_skel.so`, SHA-256
`11F85FEE20A410D15865C0B71AE2AC26D380778CE72248C2A5444C75B744CD14`; instruction bytes match
SDK 6.4.0.2 `hexagon-llvm-mc` (`fc64c65a…`). VTCM request 4,653,056 B (granted 4,718,592).
Same method-2 contract, fixture (`build/generator60x-run-fixture-20261006`) and harness
(`tools/Invoke-ResBlockRunProbe.ps1 -Graph Generator60x`) as the frozen worker.

## What changed

DDR is touched only by user DMA: stage input in, per-stage weights and parameter records in,
branch 0/1 outputs out and back for the mean, final tensor and coefficients out. The
residual stream and the first conv output of each pair stay resident in VTCM; the conv input
is an 18-tile window produced by the fused AdaIN + Snake body just ahead of each HMX conv;
moments accumulate in the epilogue of the producing conv or residual. No `memcpy`.

## Correctness

| Check | Result |
| --- | --- |
| Fused AdaIN + Snake vs frozen affine -> Snake, V73 simulator | 18/18 stage parameter sets, 786,432 B each, 0 mismatches |
| Resident stage, V73 simulator | 19/19 stages, 0 output-lane and 0 coefficient-byte mismatches; full 1,998,848-byte output tensor SHA-256 `1D23542E…` (even bytes included) |
| Resident stage, SM8550 | 3/3 runs: 19 stages, 0/999,424 output lanes, 0/18,432 coefficient bytes |

The output equals the frozen worker's, so its error against stock FP32 is the frozen
receipt's (22.67 dB SNR) by construction.

## Timing, SM8550 (19.2 MHz ticks)

| Run | Region ticks | Region ms | Invoke ms |
| --- | ---: | ---: | ---: |
| 0 | 1,650,979 | 85.99 | 109.83 |
| 1 | 1,660,632 | 86.49 | 104.99 |
| 2 | 1,657,752 | 86.34 | 106.94 |

Median 86.34 ms against 638.88 ms for the frozen worker in its combined receipt (same
harness and fixture; 613.30 ms in the instrumented profile run): 7.4×. One HVX thread, one
instruction per packet, synchronous DMA. 7,801 frames are 1.625 s of audio at 24 kHz
(`istftnet.py:263`, hop 5), so this stage alone runs at real-time factor 0.053.

The DMA probe (`dma-copy-sm8550-sm8635-20261007.md`) proved the transport only; this run
is the measurement of the saving inside the 60x stage.

## Not covered

- SM8635: the 2-byte layout needs 4.65 MB at 7,801 frames; the 4 MiB tiled path is not built.
  Shorter groups (up to 7,200 frames at 16-tile batches) fit; none has been run there.
- No category breakdown yet; profiling comes before thread or packet work.
- A simulator fault found while building: an HMX activation read straddling the 4 MiB VTCM
  boundary raises exception 0x26. The layout keeps the conv-input window inside one 4 MiB
  page. Not tested on a phone. Pinned llama.cpp `ad215653` uses single-tile HMX load regions
  (`Rt = 2047`, `ggml/src/ggml-hexagon/htp/hmx-utils.h:29`).
