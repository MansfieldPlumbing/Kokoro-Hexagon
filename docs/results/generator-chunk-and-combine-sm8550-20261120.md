# Current exact generator profile and chunked scheduling on SM8550

The comparison started at `68b37f7c161175e9783ba41a93d8fad5303dcd17` with
`section-lockstep-ring-shuffle`, the 102.228 ms primary exact-PCM
checkpoint. All tests used the same SM8550, pinned WinUSB PowerShell
ADB client, and 282,600-sample lighthouse fixture at 24 kHz.

## Profile of the current schedule

The instrumented build produced exact PCM on five runs. Its warm DSP
median was 106.730 ms and the cold profile capture took 106.340 ms.
The instrumentation build's ELF SHA-256 was
`D7D2E5E3AF0DDF58FB1C1CF72737F0DABF66F7CB975BED0862A8CA4C078E8339`.
Rebuild with `Export-ExperimentGenerator.ps1 -ProfileTiming`, run
the probe with full diagnostic capture, then parse with
`Read-ExperimentGeneratorTiming.ps1`.
[Per-interval measurements](../../tools/experiments/generator-throughput-20261119/exact-shuffle-profile.csv).

| Lockstep interval | Per-worker range across the utterance |
| --- | ---: |
| Fill | 24.21–25.71 ms |
| Combine | 8.82–10.12 ms |
| Matrix lock held | 10.83–10.97 ms |
| Matrix lock wait | 3.89–6.21 ms |
| Neighbor publication wait | 0.52–0.69 ms |

Worker intervals overlap across workers. The controller attributed 36.861 ms
to the 256-channel residual stage marker and 54.396 ms to the 128-channel
residual stage marker. Its operation markers attributed 5.656 ms to AdaIN/Snake,
6.807 ms to combine, 5.916 ms to DMA and 17.884 ms to HMX convolution calls.
These intervals bracket software work, including pointer setup, history
movement and publication where applicable. Matrix-lock intervals do not
separate HMX occupancy from instruction issue or staging.

## Chunked ring addresses

The chunked 256-channel main section can use the same two-batch parity
identity as the lockstep worker. To do so it emits two interior block
bodies where the control emitted one. The candidate grows the emitted
code by 52,948 bytes. Every one of 44 confirmation invocations matched
the expected PCM for its seed, and all four trials restored startup.

| Trial | Warm DSP median ms | Warm DSP range ms | Host invoke ms |
| --- | ---: | ---: | ---: |
| Candidate A | 102.545 | 101.481–103.711 | 144.697 |
| Exact control | 102.467 | 100.701–102.844 | 142.061 |
| Candidate B | 102.233 | 101.366–103.153 | 142.323 |
| Second seed | 101.449 | 101.403–101.480 | 143.899 |

The primary medians straddled the fresh control, so this change has no
confirmed gain. The candidate ELF SHA-256 was
`19181B801A9869D472040DB2CE8AE7883EA8616A4A4042916CADD39711CA4839`.
[Per-invocation results](../../tools/experiments/generator-throughput-20261119/exact-chunk-parity-runs.csv).

## Contiguous chunked main section

All the front tiles are ready when the chunked 256-channel main section
starts. The candidate emits one run over the contiguous block ranges,
carrying the next block's stage-zero weights across former span boundaries.
This removes duplicate stage-zero staging and shrinks the emitted code
by 28,640 bytes. The candidate ELF SHA-256 was
`6FD03B6CFF0CA2E82EC0A019B6EECD31B24C082881F87E03A08DACD35742B8A5`.

The primary warm DSP medians were 101.666 / 101.873 / 101.914 ms in
candidate/control/candidate order. The second seed ran at 102.189 ms.
The primary medians again straddled the control. Both PCM hashes and
startup restoration passed in all four trials.
[Per-invocation results](../../tools/experiments/generator-throughput-20261119/exact-chunk-resident-runs.csv).

## Residual coefficient duplication

The residual combine reads one Q15 ratio from the low halfword of
each word. The candidate loads the vector directly from the ratio base
using its encoded displacement. An even-halfword shuffle then copies
the low halfword into both positions, replacing two shifts and an OR.
This reduced the emitted code by 800 bytes. The candidate ELF SHA-256
was `D40CDA3FD448E041DA70FEA896BF7A6B6BA1A488A5DA265DFE9A84D9D4019721`.

A short screen measured 101.122 ms. In the confirmation, the primary
warm medians were 101.454 / 101.413 / 101.488 ms. The second seed ran at
101.500 ms. Every invocation matched the expected PCM and startup
restoration passed. The fresh control ran ahead of both candidate
medians, so the change remains an instruction-count reduction.
[Per-invocation results](../../tools/experiments/generator-throughput-20261119/exact-combine-ratio-runs.csv).

## Two-plane combine hardware loop

The two-plane returning combine kernel now uses Hexagon loop 0 for
each channel block's row-pair loop. The final packet advances the plane,
destination and optional residual pointers and carries the loop-end
parse bits. It replaces a software decrement, compare and jump.
Pointer advances affect disjoint registers, and the arithmetic and
memory access order within the row body are preserved. The inline tail
and three-group combine bodies retain their original loop code.

The emitted code shrank by 576 bytes. The candidate ELF SHA-256 was
`6EF021BFEC875E150970676D928DB293DBFD08FA942BCB5D78582804F5652E58`.

| Trial | Warm DSP median ms | Warm DSP range ms | DSP realtime | Host invoke ms | Host setup ms | Invoke outside region ms | Output handling ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Candidate A | 101.077 | 100.685–102.190 | 116.50× | 143.925 | 3.020 | 42.384 | 1.258 |
| Ring-shuffle control | 101.929 | 100.917–102.967 | 115.52× | 147.937 | 2.438 | 46.339 | 1.156 |
| Candidate B | 101.450 | 100.391–102.536 | 116.07× | 148.749 | 2.745 | 47.723 | 1.438 |
| Candidate, second seed | 101.397 | 100.848–101.930 | 116.13× | 145.677 | 3.093 | 44.287 | 1.543 |

The medians led the fresh control by 0.851 and 0.478 ms. Warm timing
ranges overlapped. The faster primary trial leaves **2.952 ms** to the
98.125 ms target. The [per-invocation comparison](../../tools/experiments/generator-throughput-20261119/exact-combine-hardware-loop-runs.csv)
includes cold runs and the separate second seed.
All 44 invocations produced the expected 282,600-sample PCM. The two
reference hashes were
`B61ACE349E3090D910E1F6E6EB20378FE70F89D38DD421B4C0AF978BFBE1A6BF`
and
`B4DDB8805D48110587F1752F7DC4D7A653BE05EB235FE1D201CE4966DA50B52F`.
Startup restoration passed in every trial. Rebuild
`section-combine-hardware-loop` using the existing experiment
checkout and export scripts and use the primary and second-seed
fixture commands in the
[packed-fraction report](generator-exact-packed-fraction-sm8550-20261120.md).

The separate fill-loop screen used the same loop-end mechanism to fuse
pointer advances with the existing hardware loop in AdaIN/Snake. It
preserved PCM and measured 102.013 ms over four warm runs. Its short
screen does not establish a gain. The
[screening data](../../tools/experiments/generator-throughput-20261119/exact-chunk-combine-screening-runs.csv)
records each binary and its restoration result.
