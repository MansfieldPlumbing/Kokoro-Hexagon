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

### Site coefficients computed on the host (2026-10-27)

With `-HostCoefficients` the depth-first job reads each site's K, M and S finished from the parameters (one DMA per
site) instead of computing them from the supplied ratios with the scalar coefficient kernel (two bit-serial divisions
per channel, 48 sites). `ConvertTo-KokoroGeneratorStageCoefficients` reproduces the kernel's integer arithmetic on the
host from the same int8-converted parameters. Alternated over two rounds, 5 resident runs each after a one-shot proof:

| Round | Coefficients | Depth-first, resident | One-shot proof | Layer | Library |
| --- | --- | ---: | ---: | ---: | --- |
| 1 | DSP | 63.46 ms | 62.24 ms | 66.97 ms | `1062E99B...` |
| 1 | host | 53.84 ms | 53.48 ms | 66.79 ms | `35B57166...` |
| 2 | DSP | 62.88 ms | 63.56 ms | 66.72 ms | `1062E99B...` |
| 2 | host | 53.91 ms | 53.02 ms | 66.76 ms | `35B57166...` |

PCM (`AF52480D...`) and the compared tensor (`607A350B...`) are identical in all four, and both equal the layer job's:
the host arithmetic gives the kernel's K/M/S exactly at every site. The depth-first job drops by 9.3 ms, from 38.9 to
33.2 ms per audio second (25.7 to 30.2 times real time). The coefficients are now computed on the host before the job;
that time is not in the DSP figure and has not been measured on the phone's CPU.

Receipt: `build/host-coefficients-ab.clixml` and the four `build/host-coefficients-ab-*` directories.

### DMA ledger of the depth-first job (2026-10-27, arithmetic from the emitted layout)

Depth-first job with host coefficients (library `35B57166...`), 244 tiles, 3 spans. Section state is the VTCM range each
section saves to the DDR workspace before another section runs and restores after (`Sections[].StateBytes`; for the
Backward section from its first conv-input ring to the end of stage 17's weights, for the Chunked sections from the
history region to the stage-weight region):

| Section | Channels | Schedule | State per switch |
| --- | ---: | --- | ---: |
| 0, main | 256 | Chunked | 4,456,448 B |
| 1, main | 128 | Backward | 7,176,192 B |
| 2, source of 0 | 256 | Chunked | 1,703,936 B |
| 3, source of 1 | 128 | Chunked | 983,040 B |

The 128-channel section's state holds, besides its rings, its 18 stages' resident int8 weights (about 2.1 MB), the
supplied moments, K/M/S, records and progress. Its conv-input rings hold ten tiles each, of which the next step reads two.

DMA per run, with the weight streaming of the 2026-10-24 accounting above:

| Traffic | MB per run |
| --- | ---: |
| `noise_res.1` weights, 62 steps of the same 1.08 MB | 67.0 |
| 256-channel section weights, 11 steps of 8.26 MB | 90.8 |
| `noise_res.0` weights, 11 steps of the same 2.75 MB | 30.3 |
| `ups.0` weights, 7.86 MB per span | 23.6 |
| Section state, saved and restored around the span switches | about 57 |
| `ups.1`, `noise_convs`, tail, tables | about 6.6 |
| Total | about 276 |

At the measured 37 to 55 GB/s DDR-to-VTCM rate that is 5 to 7.5 ms, against the profile's 7.30 ms of synchronous DMA.
About 96 MB repeats the same source-branch weights at every step, and about 57 MB moves state of which much is
read-only (weights, coefficients, records) or not read after the switch. State traffic grows with the number of spans:
at 24.4 s (31 spans) it would be about 890 MB per run.

**Resident source sections.** Each section's layout starts at VTCM offset 0, and the `har` layouts are read from the DDR
workspace, so a source section has the whole 8 MiB while it runs. The Backward layout (`Kokoro.Generator60x16Run.ps1`,
`$sectionLayout`) is written for three branches (three plane sets, three fills per stage and plane, nine level and stage
rings, 18 stages); the `noise_res` sections have one. The same layout arithmetic with one branch, batch 4 and one weight
plane (the three-branch case reproduces section 1's 7,176,192 B of state exactly):

| Section | Planes | Fills | Rings, mean, K/M/S, records | Weights | Total VTCM | Margin to 8 MiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `noise_res.1` (128, kernel 11) | 131,072 | 1,048,576 | 851,968 | 1,081,344 | 3,112,960 B | 5,275,648 B |
| `noise_res.0` (256, kernel 7) | 262,144 | 2,162,688 | 1,376,256 | 2,752,512 | 6,553,600 B | 1,835,008 B |

Both fit. Resident, each loads its weights once per span (3 times) instead of once per step: 3.2 MB instead of 67.0 MB
and 8.3 MB instead of 30.3 MB, about 86 MB less. Their live state per switch grows (1.90 MB against 0.98 MB, 3.54 MB
against 1.70 MB), about 11 MB more over the run's saves and restores if, as estimated here, each is saved and restored
twice. The net is about 75 MB, about 2 ms at the profile's DMA rate (7.30 ms for about 276 MB). The step count also drops:
`noise_res.1` runs 62 chunked steps with per-stage dispatch.

### `noise_res.1` resident (2026-10-27)

The Backward layout and lockstep now take the section's branch count. A one-branch section keeps its six stages'
weights resident and writes its last level (position m - 3) as its output in place of the three-branch mean. With
`-ResidentSourceChannels 128` (`Test-KokoroGeneratorTileEquivalence`, `GeneratorResidentSourceChannels`) the depth-first
job runs `noise_res.1` this way; its section state per switch is 2,981,888 B (VTCM 7,602,176 B, unchanged; library
1,302,772 B, `5DC60DBB...`). Without the parameter the libraries are unchanged (`35B57166...`, layer `246983CA...`). A
resident source section's steps are emitted as constants, so such a job does not use the span loop.

Host coefficients, alternated over two rounds, 5 resident runs each after a one-shot proof:

| Round | `noise_res.1` | Depth-first, resident | One-shot proof | Layer |
| --- | --- | ---: | ---: | ---: |
| 1 | resident | 50.14 ms | 49.91 ms | 66.81 ms |
| 1 | chunked | 53.69 ms | 53.27 ms | 66.85 ms |
| 2 | resident | 50.53 ms | 50.49 ms | 66.95 ms |
| 2 | chunked | 53.63 ms | 53.10 ms | 66.72 ms |

PCM (`AF52480D...`) and the compared tensor (`607A350B...`) are identical in all four runs and equal the layer job's.
The job drops by 3.3 ms, from 33.0 to 31.0 ms per audio second (30.3 to 32.3 times real time).

Receipt: `build/resident-source-ab.clixml` and the four `build/resident-source-ab-*` directories.

**`noise_res.0` resident as well** (`-ResidentSourceChannels 128,256`): its section state per switch is 6,291,456 B
(1,703,936 B chunked), of which 2,752,512 B are its weights; VTCM 7,602,176 B, unchanged; library 1,343,732 B,
`91A0B066...`. Same protocol, against `noise_res.1` resident alone:

| Round | Resident sources | Depth-first, resident | One-shot proof | Layer |
| --- | --- | ---: | ---: | ---: |
| 1 | 128 and 256 | 49.22 ms | 48.95 ms | 66.74 ms |
| 1 | 128 | 50.16 ms | 50.19 ms | 66.83 ms |
| 2 | 128 and 256 | 49.08 ms | 49.15 ms | 67.04 ms |
| 2 | 128 | 50.31 ms | 50.03 ms | 66.75 ms |

PCM and the compared tensor are identical in all four runs and equal the layer job's. Both resident is 1.1 ms faster:
30.2 ms per audio second, 33.1 times real time. Against both chunked (an earlier pairing, same protocol) it measured
49.0 against 53.5 and 53.9 ms. Its larger saved state is moved at every switch, read-only weights included.

Receipt: `build/resident-source-256-vs-128-ab.clixml`, `build/resident-source-256-ab.clixml` (against both chunked)
and their `build/resident-source-256-*` directories.

### DMA ledger emitted by the job (2026-10-27)

The job now records every transfer it emits in `Layout.DmaLedger` (section, span, class, transfers and bytes per run,
loop bodies counted by their trip counts; the tail's own transfers are not included). Classes follow the base register:
weights, parameters, the section's state slot (save, restore), and tensors. Library bytes are unchanged. For the job
with both sources resident (`91A0B066...`):

| Section | Weights | State save | State restore | Tensors | Parameters |
| --- | ---: | ---: | ---: | ---: | ---: |
| 256-channel main (with `ups.0`) | 114.43 MB | 8.91 MB | 8.91 MB | 6.37 MB | 1.14 MB |
| 128-channel main (with `ups.1`) | 5.60 MB | 14.35 MB | 14.35 MB | 8.73 MB | 0.52 MB |
| `noise_res.0` (with `noise_convs.0`) | 3.54 MB | 6.29 MB | 6.29 MB | 4.02 MB | 0.54 MB |
| `noise_res.1` (with `noise_convs.1`) | 1.23 MB | 5.96 MB | 5.96 MB | 8.98 MB | 0.30 MB |
| Total | 124.80 MB | 35.52 MB | 35.52 MB | 28.09 MB | 2.50 MB |

226.43 MB per run. The 256-channel weights (90.8 MB of chunked streaming and 23.6 MB of `ups.0`, loaded once per span)
are the largest class; state saves and restores, 71.0 MB, the second.

## Not yet done

- **State:** sections save and restore their read-only regions (weights, records, K/M/S) and whole rings with their
  live state.
- **Overlap:** weight DMA overlapped with computation.
- **Length:** the harmonic source and the `har` layouts are whole-length in VTCM, which limits length to about 2 s.
  Spanning them removes that limit.
