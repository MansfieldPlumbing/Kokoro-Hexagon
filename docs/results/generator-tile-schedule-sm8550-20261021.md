# Depth-first schedule for the 128-channel generator section, SM8550

Kokoro-Hexagon `f50254b`, `Invoke-KokoroDevelopment.ps1 Run -Case generator-tile-equivalence`. Design:
`generator-depth-first-w4-design.md` (build order step 2, with today's 16-bit weights).

## What ran

Fixture: `build/speak-20261010-h0-fast/job-input/generator60x16-fixture-20261008-holdout2`, the 128-channel residual
section (resblocks 3 to 5 and their mean), 10,201 frames, 319 tiles. Kernel `KokoroGenerator60x16Run`:

- Layer schedule (reference): each stage over every tile, 22 tiles per batch, four HVX threads, each stage's weights
  copied into VTCM before it runs.
- Tile schedule: all 18 stages' weights, records and K/M/S resident in VTCM; at step i, stage q of every branch processes
  tile i - q; residual rings of 8 tiles per branch and stage rings of 4 per pair; interior steps in a `loop1` hardware
  loop with ring slots computed in registers, the six steps at each end unrolled; one tile per call, main thread only.

Both ran with the same supplied AdaIN values, exported on the phone by the layer schedule in Export mode and converted
with `New-KokoroDecoderConstantsTables`, and the same input and weights.

## Result

| | Layer schedule | Tile schedule |
| --- | ---: | ---: |
| Output tensor SHA-256 | `9D5F9DABDE7BC814...` | `9D5F9DABDE7BC814...` |
| Differing bytes (2,613,248) | | 0 |
| VTCM | 7,274,496 B | 5,373,952 B |
| Library | 491,764 B | 180,468 B |
| DSP median, 3 runs | 31.29 ms | 151.46 ms |

The compared region holds 1,305,560 non-zero values of 1,306,624, 24,139 distinct, RMS 3,165 LSB; the 4 KiB before it is
uniform. Libraries: layer `C649E874...`, tile `F0F8F2BC...`. Receipt: `build/generator-tile-equivalence-*/equivalence.clixml`.

`VerifyEmission` against `build/emission-consolidation/baseline.csv` after the change: 56 identical, 4 recorded failures
unchanged; default emissions of `KokoroGenerator60x16Run` and `KokoroGeneratorWholeSource16Run` identical.

## Observations

- The depth-first order reproduces the layer schedule exactly: every stage reads the values the layer schedule gives it.
- The tile schedule is 4.8 times slower as built: every call is one tile on the main thread (the other three HVX contexts
  idle), with three input DMAs per step. The three branches are independent at every step, tiles can be batched within
  the 16-tick period, and the matrix unit can overlap the next tile's convolution with the current tile's epilogue; none of
  these changes the arithmetic.

## Blocks of tiles on every HVX thread

Kokoro-Hexagon `f6171f2`, `Run -Case generator-tile-equivalence -Parameters @{TileBlock=<B>}`. A step now moves a block
of B tiles: rings hold blocks (residual rings of 8 blocks, stage rings of 4), and the tile-parallel bodies (window fill,
combines, mean) split each block over the four HVX threads. The convolution stays on the main thread.

| Block (tiles) | Steps | VTCM | Library | DSP median, 3 runs | Output tensor |
| ---: | ---: | ---: | ---: | ---: | --- |
| 1 | 319 | 5,373,952 B | 180,468 B | 151.28 ms | `9D5F9DABDE7BC814...`, 0 differing bytes |
| 2 | 160 | 5,898,240 B | 307,444 B | 100.32 ms | `9D5F9DABDE7BC814...`, 0 differing bytes |
| 4 | 80 | 6,946,816 B | 364,788 B | 57.50 ms, 57.37 ms (two runs) | `9D5F9DABDE7BC814...`, 0 differing bytes |

The layer schedule measured 30.89 to 31.22 ms in the same sessions. The receipt now also stores both tensors
(`layer-tensor.bin`, `tile-tensor.bin`) and the list of differing tiles.

The first block-of-4 build used a `loop1` hardware loop for the interior steps and ended it early: the output was
correct for the first 2 to 4 blocks and zero after them, and where it stopped changed from run to run (one run faulted).
With one tile per block, the interior step made no worker-join calls; with blocks, the main thread waits for the workers
in a QuRT futex trap inside the loop, and LC1 did not survive that wait. The interior steps now count in r17 with a
compare and branch, and every block size is byte-identical.

### Observations

- Time falls with the number of steps (0.47 ms per step at one tile, 0.72 ms at four), so per-step overhead dominates:
  each step makes 37 tile-parallel dispatches (window fill and combine for each of 18 stages, then the mean), each a
  futex wake and join, plus 36 single-tile halo fills and two synchronizations around every convolution.
- Blocks of 8 tiles do not fit with 16-bit weights resident (rings and windows scale with the block; weights take
  4,128,768 B). Resident W4 weights halve that and leave room for them.

## Fewer and lighter dispatches

Two changes to the per-step overhead, each checked with `generator-tile-equivalence` (output tensor
`9D5F9DABDE7BC814...`, 0 differing bytes, at every row below):

1. Kokoro-Hexagon `aab77f4`: each stage's window fill is one segmented dispatch. Each halo tile is its own segment and
   the block's tiles split over the remaining HVX threads, replacing two single-tile calls on the main thread and a
   tile-parallel call.
2. Kokoro-Hexagon `ea2db1b`: the pool waits by polling with `pause(#16)` instead of QuRT futex traps (job parameter `PoolWait`, default `Spin`
   for the tile schedule, `Futex` otherwise). Workers poll the pool sequence between dispatches; the main thread
   polls each worker's completion. Neither side makes a trap per dispatch. The `pause` encoding was checked against
   LLVM's `test/MC/Hexagon/instructions/system_user.s` (`pause(#255)` = `0x5440DF1C`).

| Schedule | Block (tiles) | DSP median, 3 runs | Library |
| --- | ---: | ---: | ---: |
| Tile, separate halo calls, futex | 4 | 57.37 to 57.50 ms | 364,788 B |
| Tile, segmented fill, futex | 4 | 45.71 ms | 340,212 B |
| Tile, segmented fill, futex | 1 | 88.69 ms | 241,908 B |
| Tile, segmented fill, spin | 4 | 39.76 to 40.05 ms (two runs) | 311,540 B |
| Layer (reference) | 22 | 30.85 to 31.20 ms | 491,764 B |

`VerifyEmission` after each change: 60 of 60 recipes match `build/emission-consolidation/baseline.csv`.

## One resident int8 weight plane

Kokoro-Hexagon `aca8e94`, `Run -Case generator-tile-equivalence -Parameters @{TileBlock=4; WeightPlanes=1}`. Both
jobs run int8 weights q = round(w / 256), clamped to +-127, stored as 256 q in the 16-bit weights file (low plane zero),
with the zero-point table biases corrected (group 0 by -128 times the change in each output channel's high-plane sum,
group 1 by 128 times its old low-plane sum). The layer job runs them through its two weight planes and three
accumulator groups, in which every low-plane term is zero; the tile job keeps only the high plane resident and runs two
accumulator groups and the two-group combine (`New-KokoroPlaneCombineSteps -Groups 2`), reading the same tables through
a three-group column stride.

| | Layer schedule (int8 values, two planes) | Tile schedule (one plane) |
| --- | ---: | ---: |
| Output tensor SHA-256 | `438C6CD5829871B9...` | `438C6CD5829871B9...` |
| Differing bytes | | 0 |
| Distinct values / non-zero | | 24,107 / 1,306,624 of 1,306,624 |
| VTCM | | 4,849,664 B (two planes: 6,946,816 B) |
| DSP median, 3 runs | 31.05 ms | 34.16 ms (two planes: 40.1 ms) |

One plane is the matrix work of W4 as well: W4A8 and W8A8 take the same compute per tile on SM8550
(`hmx-w4a8-direct-readback-20260924.md`). What W4 adds is VTCM: the whole main path is 13,356,288 weights
(`generator-depth-first-w4-design.md`), 13.4 MB at W8 and 6.7 MB at W4 against 8 MiB. Open for W4: the deep 4-bit
weight form's encoding (no builder record) and the nibble order, which the dense-input W4A8 receipt does not establish.

## Controller contact

Kokoro-Hexagon `generator-tile-equivalence -Parameters @{ControllerContact=$true}`, blocks of 4, two weight planes.
Each window fill reads its tile's controller word (v shifted left 16) and computes K = K_base + P_K v and
M = M_base + P_M v per channel with the Q31 multiply it already uses for K x; K_base, M_base and S come from the
stage's supplied AdaIN values as before. P_K and P_M per stage (here fixed pseudo-random, |P| at most 2^20) and one
controller word per tile come from the parameters input after the constants table.

| Proof | Result |
| --- | --- |
| v = 0 against the layer job | byte-identical, 0 differing tiles |
| v = 8192 on every tile | all 319 tiles differ from v = 0 |
| step from 0 to 8192 at tile 160, tiles 0 to 151 | equal to the v = 0 run |
| same step, tiles 168 to 318 | equal to the v = 8192 run |
| same step, tiles 152 to 167 | 10 tiles differ from the v = 0 run (convolution reach) |
| same step at blocks of 1 against blocks of 4 | byte-identical |

DSP median, 3 runs: 40.69 ms with the contact at v = 0, against 40.1 ms without it and 31.13 ms for the layer job;
VTCM 7,012,352 B. The step run at blocks of 1 took 76.07 ms. `VerifyEmission`: 60 of 60 match the baseline.

## Seeded source noise

`Run -Case source-seeded-noise`, harmonic source fixture `build/speak-20261010-h0-fast/job-input/harmonic-source-fixture-20261008`
(51,000 samples, used for its f0 and harmonic weights). The source's noise term, previously captured stock draws, is
generated on the DSP from a seed and the sample's position: two counter-based 32-bit hashes (lowbias32) per sample, the
four 16-bit halves summed (Irwin-Hall), centred and scaled to sqrt(sum w_h^2) = 0.76353 in Q12 (scale 5,417). The host
reference (`Get-KokoroSourceNoise`) fed to the captured-noise job gives the same har planes and signal samples, byte
for byte, as the seeded job generating them on the DSP; the only differing bytes are padding outside the signal's
samples, which the job leaves undefined (433 and 441 bytes in two runs).

| Noise | Mean | Std | Kurtosis | Lag-1 correlation |
| --- | ---: | ---: | ---: | ---: |
| Seeded (target std 0.76353) | 0.00 | 0.76 | 2.67 | -0.01 |
| Captured stock draws | -0.00 | 0.76 | 3.00 | 0.01 |

The kurtosis follows from summing four uniforms (2.7 for the sum; 3 for a Gaussian). Source job 7.08 ms with seeded noise,
5.13 ms reading captured noise; the generation is a scalar loop, one sample per iteration.

Through the whole generator (`Run -Case generator-seeded-noise`; the accepted constants input of the weight-precision
measurement, 51,000 samples, stock PCM from `data/baselines/decoder-generator-bank-input-sm8550-20261010`):

| Noise | PCM SNR against stock | PCM SNR against the captured-noise run | DSP |
| --- | ---: | ---: | ---: |
| Captured stock draws | 31.29 dB | | 89.69 ms |
| Seeded, seed 1 | 17.96 dB | 17.74 dB | 90.98 ms |
| Seeded, seed 2 | 17.84 dB | 18.18 dB | 91.71 ms |
| Seeded, seed 3 | 19.82 dB | 19.78 dB | 91.37 ms |

A different noise realization alone limits waveform SNR to about 18 to 20 dB on this input. Waveform SNR against a
reference therefore requires the reference to use the same draws: the syllabus port has to render with the same seeded
noise (`Get-KokoroSourceNoise`) for the end-to-end gates to measure the generator rather than the noise.

The convolution still runs on the main thread while the workers wait for the combine. The three branches are
independent within a step, so the next branch's window fill can run on the workers during a branch's convolution.

## Each window tile filled once

Kokoro-Hexagon `86cdafc`, `Run -Case generator-tile-equivalence -Parameters @{TileBlock=4; WeightPlanes=1;
BranchesPerStage=3; VectorPackets=$true; FillOnce=$true}`. Each stage keeps its own conv-input window (18 windows, high
and low planes). The windows of blocks j - 1 and j share two tiles: the last tile of block j - 1 and the first of block
j. They are copied from positions 5 and 6 of the stage's window to positions 0 and 1 (two tiles per plane on the main
thread), and the fill computes only tiles 1 to 3 of the block and the next block's first tile. A block of 4 tiles costs
4 tile fills instead of 6, and the fill's four segments are one tile each instead of 1, 2, 2 and 1 tiles, so the
slowest HVX thread fills one tile instead of two. The planes stay in the first 1 MiB of VTCM; each window lies inside
one 1 MiB page (`hexagon-v73-notes.md`).

| Run (alternated) | Tile job | Layer job | Output tensor |
| --- | ---: | ---: | --- |
| Without FillOnce | 29.69 ms | 30.78 ms | `438C6CD5829871B9...`, 0 differing bytes |
| FillOnce | 22.78 ms | 30.92 ms | `438C6CD5829871B9...`, 0 differing bytes |
| Without FillOnce | 29.72 ms | 31.04 ms | `438C6CD5829871B9...`, 0 differing bytes |
| FillOnce (earlier run) | 22.95 ms | 31.00 ms | `438C6CD5829871B9...`, 0 differing bytes |

DSP medians of 3 runs each. VTCM 5,373,952 B without, 7,340,032 B with; two weight planes do not fit with 18 windows.
Library 196,852 B. `VerifyEmission`: 60 of 60 match `build/emission-consolidation/baseline.csv`.

### Observations

- The tile schedule is now faster than the layer schedule on this section (22.8 against 30.8 to 31.0 ms), the first
  configuration where the depth-first order gains time rather than only VTCM and per-tile control.
- The saving (6.9 ms) is more than a third of the window fill: the fill's critical path per stage halved, from two
  tiles on the busiest thread to one.
## Time per category of the tile schedule

Kokoro-Hexagon `c79fc56`, `Run -Case generator-tile-equivalence -Parameters @{TileBlock=4; WeightPlanes=1;
BranchesPerStage=3; VectorPackets=$true; FillOnce=$true; PmuSplit=$true}`. Unprofiled 22.81 ms, output equal to the
layer job (30.88 ms) byte for byte; the profiled runs (event sets A and B) produce the same output and take 25.02 and
25.18 ms. Event set A:

| Category | ms | Calls | HVX packets |
| --- | ---: | ---: | ---: |
| AdaIN and Snake fill | 9.17 | 480 | 15,944,652 |
| Matrix-unit convolutions (main thread) | 5.36 | 480 | 0 |
| Plane combine | 4.06 | 480 | 7,045,443 |
| Tile fixes (carried tiles, zero tiles, padded rows) | 2.44 | 2,970 | 736,632 |
| AdaIN coefficients (K, M, S for 18 stages, once per run) | 2.24 | 18 | 0 |
| DMA | 0.55 | 237 | 0 |
| Synchronization | 0.39 | 1,040 | 0 |
| Unmarked | 0.35 | 1,040 | 0 |
| Mean | 0.21 | 80 | 266,046 |

### Observations

- Coordination is small: synchronization and unmarked time together are 0.74 ms for 1,040 meetings.
- Moving data and per-run setup are not: the carried-tile copies and other tile fixes take 2.44 ms, and computing the
  coefficients takes 2.24 ms, which session residency pays once per session rather than per run.
- The convolutions run only on the main thread, 5.36 ms during which the other three HVX threads wait.
## Backward convolutions, every stage on the newest block

Kokoro-Hexagon `c7786e0`, `Run -Case generator-tile-equivalence -Parameters @{Schedule='Backward'; TileBlock=4;
WeightPlanes=1; BranchesPerStage=3; VectorPackets=$true}`. Every convolution taps one tile late (TapDelay 32 rows), so it
reads only rows at or before its output, and step j runs all 18 stages on block j. Stage s's conv-input tile m holds
position m - s (outside the section's tiles, the conv-input zero, and the last tile's rows past the frames padded as
before); a pair's residual adds the previous level two tiles back; the three branches end six tiles shifted, so the
mean needs no offsets and is written at position m - 6. Rings are indexed by virtual tile (two blocks, a power-of-two
mask). Each conv-input ring has two guard tiles before it, written by the fill as a second store of the ring's last two
tiles, so the matrix unit reads two tiles of history contiguously and no tiles are copied. One input ring serves the
three branches. The look-ahead is six tiles (192 frames, 40 ms of this section).

| Run (alternated) | Section | Layer job | Output tensor |
| --- | ---: | ---: | --- |
| Backward | 21.82 ms | 30.98 ms | `438C6CD5829871B9...`, 0 differing bytes |
| Centred, fill once | 22.82 ms | 30.97 ms | `438C6CD5829871B9...`, 0 differing bytes |
| Backward | 21.91 ms | 30.85 ms | `438C6CD5829871B9...`, 0 differing bytes |

DSP medians of 3 runs. VTCM 7,536,640 B, library 172,276 B (centred: 7,340,032 B and 196,852 B).
`VerifyEmission`: 60 of 60.

Profiled (event set A, 23.66 ms): fill 9.39, convolutions 5.53, combine 4.26, coefficients 2.26, tile fixes 0.47
(2.44 centred), synchronization 0.39, DMA 0.38, unmarked 0.36, mean 0.22 ms.

### Observations

- Removing the carried-tile copies took tile fixes from 2.44 to 0.47 ms; what remains is ring setup and the zero and
  padded tiles at the section's edges.
- Fill, convolutions and combine rose slightly: the six-tile delay adds two steps (82 against 80), and the fill's last
  two tiles of every odd block are stored twice.
- Every stage now reads only what earlier steps or earlier stages of the same step wrote, which is the order a
  lockstep rotation of threads needs; the centred schedule's reads of the next block are gone.
- One delay for every convolution keeps every join tile-aligned; delays per convolution at their reach would cut the
  look-ahead to about 60 frames but bring back row offsets at the residual and the mean. Kept as an explicit choice.
## Controller contact on the backward schedule; centred schedule removed

Kokoro-Hexagon `7be348f`. The backward schedule carries the controller contact: each fill reads the controller word of
its tile's position (m - s). The mirrored stores' delta is a constant chosen when the code is built (the interior loop
body is an even and an odd step), which frees r5 for the contact. The centred tile schedule and its options (windows,
carried-tile copies, block rings, matrix-thread and matrix-lock variants, branches per stage, fill once) are removed;
only the layer schedule (the reference) and the backward schedule remain.

| Proof (`generator-tile-equivalence -Parameters @{VectorPackets=$true; ControllerContact=$true}`) | Result |
| --- | --- |
| v = 0 against the layer job | byte-identical |
| v = 8192 on every tile | all 319 tiles differ from v = 0 |
| step from 0 to 8192 at tile 160, outside tiles 152 to 167 | equal to the v = 0 run before, the v = 8192 run after |
| same step, tiles 152 to 167 | 10 tiles differ from the v = 0 run |
| same step at blocks of 2 against blocks of 4 | byte-identical |
| step output before and after removing the centred schedule | identical (`3FDF41463386E033...`) |

Without the contact: output equal to the layer job byte for byte, 22.04 ms against 31.03 ms; library 192,756 B (the
two-step loop body), VTCM 7,536,640 B. With the contact: 22.14 to 22.37 ms. `VerifyEmission`: 60 of 60.
## One tile of delay per residual pair

Kokoro-Hexagon `94a16fe`. In each residual pair (kernel K, dilation d, then 1) the first convolution taps its reach
r1 = d (K - 1)/2 rows late and the second 32 - r1; r1 + r2 is at most 30 rows, so both read only rows at or before their
output and the pair emerges exactly one tile late. The residual adds the previous level one tile back and the three
branches end three tiles shifted (96 frames, 20 ms of this section, against six tiles with one tile of delay per
convolution). A pair's first output lands mid-tile, so each fill sets its rows outside the section's frames to the
conv-input zero by row range.

| Run | Section | Layer job | Output tensor |
| --- | ---: | ---: | --- |
| One tile per pair | 21.60 ms | 30.87 ms | `438C6CD5829871B9...`, 0 differing bytes |
| One tile per pair, controller contact | 22.15 ms | 30.92 ms | v = 0: 0 differing bytes |
| One tile per convolution (`7be348f`) | 22.04 ms | 31.03 ms | 0 differing bytes |

Contact proofs with one tile per pair: v = 8192 changes all 319 tiles; a step at tile 160 leaves the tiles outside
152 to 167 equal to the v = 0 and v = 8192 runs, 10 tiles differ in the transition; blocks of 2 equal blocks of 4. A
fill's controller word is its pair's tile (m - p). Library 205,044 B; `VerifyEmission`: 60 of 60.
## Lockstep

Kokoro-Hexagon `b9d32aa`, `Run -Case generator-tile-equivalence -Parameters @{VectorPackets=$true}`. Thread k (the main
thread is thread 0) carries tile 4 j + k of every block through all 18 stages, calling the stage bodies directly with a
count of one. After each stage a thread publishes a progress word (after `syncht`); before a stage's convolutions it waits
until the thread holding the previous tile has completed that stage, which covers the two tiles of history and the
residual one tile back. A thread takes the matrix lock (try-lock, `trap0(#0x1d)`, r5 = 2) around a stage's three
convolutions, 6 lock pairs per tile. One dispatch runs the section; the main thread releases the job's matrix lock before
it and takes it back after. The per-stage dispatches are removed.

| Run | Section | Layer job | Output tensor |
| --- | ---: | ---: | --- |
| Lockstep | 17.86 ms | 30.60 ms | `438C6CD5829871B9...`, 0 differing bytes |
| Lockstep (profile run, unprofiled) | 17.84 ms | 30.89 ms | 0 differing bytes |
| Lockstep, controller contact | 18.12 to 18.29 ms | 30.82 ms | v = 0: 0 differing bytes |
| Per-stage dispatches (`94a16fe`) | 21.60 ms | 30.87 ms | 0 differing bytes |

Profiled (event set A, 17.94 ms): the lockstep section 15.15 ms, AdaIN coefficients 2.41 ms (computed once per run before
it), ring setup 0.2 ms, DMA 0.12 ms. Contact proofs pass (319 tiles change at v = 8192; 0 differing tiles before and
after the step at tile 160, 10 in the transition; blocks of 2 equal blocks of 4); the step output equals the per-stage
dispatch schedule's (`6ADF95BCD54D7AE4...`). Library 229,620 B; VTCM 7,602,176 B. `VerifyEmission`: 60 of 60.

### Observations

- The section is now 1.73 times faster than the layer job (17.84 against 30.89 ms).
- The convolutions no longer run alone on the main thread; the saving (3.7 ms) is close to the bound set by the 5.5 ms
  of convolutions that ran alone before, less the lock and the per-stage progress words.
- The AdaIN coefficients, computed serially before the section, are now 13% of the run; they depend only on the voice
  and the supplied values, so session residency computes them once.