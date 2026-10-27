# Generator with its source branches on the DSP (SM8550)

Kokoro-Hexagon `3964190`. Case `generator-tile-equivalence -Joint WholeSource`,
fixture `build/generator-whole-source-fixture-20261008` (7,801 frames, 1.625 s; input x, f0 and the noise draws).

## Method

The depth-first whole job computes its own source.

**Job start.** The harmonic source, its STFT and the `har` layouts run once over the whole input, as in the layer job.

**Source sections.** Each front's `noise_res` is a one-branch depth-first section of its own, on the chunked schedule
with its weights streamed. It uses the original weights, records and AdaIN sites.

**Per span:**
1. `noise_convs` runs over a tile range from `har`, with a tile of halo each side, into the source section's input.
2. The source section's steps run from its saved state, far enough ahead of the front that consumes them.
3. The front reads the source N from the workspace.

Weights are int8 for the resblocks and `noise_res`, with supplied (constants) AdaIN values and blocks of 4 tiles.

## Result

Every section's input and output, both computed sources and the PCM are equal to the layer job's byte for byte. The PCM
SHA-256 is AF52480D4594AC4EFD49CAC413CFD6CE6C5C7B86599C15330FEF8E0E33049B93.

| Job | DSP ms | Times real time |
| --- | ---: | ---: |
| Depth-first, source on the DSP | 61.75 | 26.3 |
| Layer job, source on the DSP (reference) | 66.41 to 66.69 | 24.4 |
| Depth-first, supplied source (`generator-depth-first-joints-sm8550-20261023.md`, other fixture, same length) | 38.58 | 42.1 |
| Harmonic source stage alone (`-StopAfterSpanStage Start`) | 8.04 | |

The source costs about 23.2 ms on top of the supplied-source job. The harmonic source and STFT take 8.0 ms of it, and
`noise_convs` and `noise_res` about 15.2 ms (by difference).

**VTCM and library.** VTCM 7,602,176 B. Library 1,245,428 B (the layer job's: 983,284 B).

**Weight traffic** (arithmetic from the span plan, DDR to VTCM per run):

| Part | Bytes |
| --- | ---: |
| 256-channel section: 11 chunked steps × 8.26 MB | 90.8 MB |
| `noise_res.0`: 11 steps × 2.75 MB | 30.3 MB |
| `noise_res.1`: 62 steps × 1.08 MB | 67.0 MB |
| `ups.0`: 7.86 MB in each of 3 spans | 23.6 MB |
| `ups.1`, `noise_convs`, tail and the 128-channel section's load | about 6.6 MB |
| Total | about 219 MB |

At the measured 37 to 55 GB/s DDR-to-VTCM DMA (`dma-copy-sm8550-sm8635-20261007.md`), that is 4 to 6 ms, all of it
synchronous. Section state saves and restores come on top; their sizes are now in the layout (`Sections[].StateBytes`).

## Defect found

In jobs with a chunked section, workers take r5 from pool slot 56 after the count. A five-argument tile-parallel call
(the `har` phase-major layout's) therefore ran its workers with a stale count, and the job faulted. Such calls now store
their count in slot 56 as well.

## Reproduced as a baseline (2026-10-27)

Kokoro-Hexagon `80a57cd`, `Test-KokoroGeneratorTileEquivalence -Joint WholeSource -Runs 5`, same fixture, schedule
Backward, blocks of 4 tiles, int8 weights in one plane (q = round(w / 256)), supplied (constants) AdaIN values.

| Job | DSP median, 5 one-shot runs | Per audio second | VTCM | Library |
| --- | ---: | ---: | ---: | --- |
| Layer, source on the DSP | 66.17 ms | 40.7 ms (24.6 times real time) | 7,208,960 B | 983,284 B, `246983CA...` |
| Depth-first, source on the DSP | 62.58 ms | 38.5 ms (26.0 times real time) | 7,602,176 B | 1,253,620 B, `1062E99B...` |

- PCM SHA-256 `AF52480D...` for both jobs, as above; every section's input and output, both computed sources and the
  `har` layouts are byte-identical between the jobs.
- PCM against stock Kokoro for the same captured inputs: 29.43 dB (int8 weights).
- Timing covers the job on the DSP from its start tick to its end tick: weight DMA, harmonic source and STFT, source
  branches, sections, tail and PCM. It excludes what is supplied or prepared on the host: the decoder output `x`,
  the AdaIN constants (exported by a separate layer-job run on the same input, so whole-input moments), `f0` and the
  noise draws, int8 weight conversion, constants packing, FastRPC dispatch and app launch.
- Receipt: `build/generator-baseline-wholesource-20261027T113146/baseline.clixml` and `equivalence.clixml`.

### Profile of the baseline (2026-10-27)

`-PmuSplit`, two event sets, one-shot runs whose output equals the unprofiled run's. Timing runs are now resident with a
one-shot proof run whose PCM they must reproduce (`-OneShotTiming` restores one-shot timing): depth-first 62.61 ms
resident, 63.50 ms one-shot, layer 66.82 ms resident.

The instrumented run took 65.79 ms (event set A); the categories sum to 65.73 ms, 4.94 ms of it between marks.

| Category | ms | Calls |
| --- | ---: | ---: |
| Lockstep (the 128-channel section's steps, one region) | 13.44 | 3 |
| Coefficients (AdaIN coefficients expanded from the supplied constants) | 8.92 | 48 |
| DMA (synchronous) | 7.30 | 1,177 |
| HMX convolution | 7.28 | 669 |
| AdaIN and Snake | 6.99 | 504 |
| Combine | 4.80 | 699 |
| Between marks | 4.94 | 52 sites |
| Source (harmonic source and STFT) | 4.21 | 1 |
| Tile fixes | 3.83 | 2,908 |
| Boundary | 3.39 | 22 |
| Synchronization | 0.56 | 1,340 |
| Mean, setup | 0.07 | 12 |

By stage: front of the 128-channel section 13.35 ms, front of the 256-channel section 12.17, 128-channel section 9.46,
128-channel source 7.89, 256-channel section 7.15, harmonic layouts 4.38, harmonic source 4.21, 256-channel source 3.72,
tail 3.36 ms. The source branch (harmonic source, its layouts and both source stages) is 20.2 ms.

Receipt: `build/generator-profile-wholesource-20261027T114800/profile.clixml`.

## Not yet done

- **Profile:** a per-stage profile of the source sections. The one-branch chunked `noise_res.1` runs 62 steps with
  per-stage dispatch for little work each. The 128-channel source could run on the resident lockstep schedule instead.
- **Overlap:** weight DMA overlapped with computation.
- **Length:** the harmonic source and the `har` layouts are whole-length in VTCM, which limits length to about 2 s.
  Spanning them removes that limit.
