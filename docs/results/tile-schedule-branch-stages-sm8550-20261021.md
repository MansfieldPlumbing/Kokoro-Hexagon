# Tile schedule with three branches per stage, SM8550

Kokoro-Hexagon `13960f8`, `Run -Case generator-tile-equivalence -Parameters @{BranchesPerStage=$g; WeightPlanes=$p}`:
the 128-channel residual section (fixture `generator60x16-fixture-20261008-holdout2`, 319 tiles, 10,201 frames), four
HVX threads, blocks of four tiles, convolutions on the main thread, window fill without instruction packets.

## Change

`BranchesPerStage 3` runs each of the six stages over all three branches: one window-fill dispatch and one combine
dispatch per stage instead of one per branch, each body repeated over the branches at fixed VTCM strides, and the three
convolutions back to back. A step meets the worker threads 13 times instead of 37. Each branch has its own windows and
planes. The default (`BranchesPerStage 1`) emits the same library as before (`B786E795...`).

## Checks

- SDK 6.4.0.2 `hexagon-llvm-mc` (19.0.04): both schedules match byte for byte.
- Phone: in all eight runs the tile job's output equals the layer job's byte for byte.

## Time

Receipts `build/generator-tile-equivalence-20261021T105630` to `T110110`, in table order:

| Weight planes | Branches per stage | Layer job ms | Tile job ms | Tile VTCM bytes |
| --- | ---: | ---: | ---: | ---: |
| 2 | 1 | 31.15 | 39.91 | 6,946,816 |
| 2 | 3 | 31.18 | 39.30 | 7,602,176 |
| 2 | 1 | 30.91 | 39.94 | 6,946,816 |
| 2 | 3 | 31.18 | 39.37 | 7,602,176 |
| 1 | 1 | 30.92 | 34.33 | 4,849,664 |
| 1 | 3 | 30.99 | 33.45 | 5,373,952 |
| 1 | 1 | 31.04 | 34.02 | 4,849,664 |
| 1 | 3 | 31.01 | 33.12 | 5,373,952 |

Grouping saves about 0.6 ms with two weight planes and 0.9 ms with one. About 1,900 fewer dispatches account for under
1 ms, so a dispatch costs well under a microsecond here, and dispatch count does not explain the tile schedule's extra
time over the layer job.

## Observation for the next step

Each stage fills a window of the block's tiles plus one halo tile on each side, each halo tile its own segment: at
blocks of four, six tiles of AdaIN and Snake per four tiles of output, half as much again as the layer schedule, which
fills each tile once.
