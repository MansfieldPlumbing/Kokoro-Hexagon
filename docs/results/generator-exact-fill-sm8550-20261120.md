# Exact activation fill on SM8550

The three-instruction fill packets measured **104.832 and 104.328 ms**
around a **105.351 ms** packed-fraction control. The quicker trial
produced 11.775 seconds of reference-identical audio at **112.87× DSP
realtime**, 6.203 ms outside the 120× budget. The candidate medians led their
control by 0.518 and 1.023 ms. The warm distributions overlapped, and the
historical 104.149 ms exact result remains faster.

The test started from the experiment definitions at local commit
`7acad5f4475fa1560cb7558f14e4ef20e54f708c`, based on remote
`0adfc12948b278a4e1dcab333687ebefe3f985f3`.

## Current schedule timing

The packed-fraction ELF with instrumented intervals produced exact PCM
in five invocations on the same SM8550. The four warm region times were
108.528–110.073 ms, with a 109.478 ms median. The instrumentation changes
the executable and the timing. These intervals come from its cold capture,
which timed at 109.591 ms.
The instrumented ELF SHA-256 was
`635F1EC563E25C10B66463EA417134CC984BB1D7AF5CADE2994D706EF17C43C4`.

| Lockstep interval | Per-worker total across the utterance |
| --- | ---: |
| AdaIN/Snake fill | 26.69–28.13 ms |
| Matrix lock held, including convolution calls | 11.03–11.13 ms |
| Combine | 8.51–10.17 ms |
| Matrix lock wait | 3.38–5.87 ms |
| Neighbor publication wait | 0.52–0.65 ms |
| Input DMA | 0.78–0.81 ms |
| Mean and output | 1.01–1.09 ms |

Workers overlap. The controller also attributed 6.23 ms to its
AdaIN/Snake markers and 17.90 ms to its HMX-convolution markers outside
the lockstep worker intervals. These are software intervals. They include
addressing, issue and other instruction costs and do not measure matrix
engine occupancy. Main 256-channel execution uses the chunked schedule
while the main 128-channel section and the two source sections use
lockstep. The worker fill totals make that kernel a target even with both
activation planes retained.

Reproduce the interval capture with `section-snake-packed-fraction` and
`Export-ExperimentGenerator.ps1 -ProfileTiming`. Invoke
`tools/Invoke-GeneratorTailProbe.ps1` with the usual fixture and expected
PCM hash, using `-Runs 5` and omitting `-CapturePcm` to retrieve run zero's
diagnostic buffer. Pass its `OutputPath` and the export's
`profile-layout.json` to `Read-ExperimentGeneratorTiming.ps1`.
[Raw interval data](../../tools/experiments/generator-throughput-20261119/exact-packed-fraction-profile.csv).

## Three-instruction packets

The packetizer can schedule a third independent instruction in AdaIN/Snake
fill packets after the packed fractional shift removed two operations.
This change stays local to fill. It preserves the 203 instructions in
the emitted standalone non-mirrored body while reducing its static
packet records from 116 to 107 for both channel widths. The dynamic
instruction stream still includes the original arithmetic and memory operations.

| Trial | Warm DSP median ms | Warm DSP range ms | DSP realtime | Host invoke ms | Host setup ms | Invoke outside region ms | Output handling ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Candidate A | 104.832 | 103.170–105.657 | 112.32× | 148.240 | 2.961 | 43.634 | 1.373 |
| Packed-fraction control | 105.351 | 103.844–106.301 | 111.77× | 148.632 | 2.748 | 43.816 | 1.405 |
| Candidate B | 104.328 | 103.589–105.123 | 112.87× | 143.732 | 3.594 | 39.453 | 1.247 |
| Second seed | 104.669 | 103.747–104.861 | 112.50× | 146.973 | 3.792 | 42.743 | 2.714 |

Every one of 44 invocations returned 282,600 samples. The primary PCM
SHA-256 was `B61ACE349E3090D910E1F6E6EB20378FE70F89D38DD421B4C0AF978BFBE1A6BF`
and the second seed was
`B4DDB8805D48110587F1752F7DC4D7A653BE05EB235FE1D201CE4966DA50B52F`.
The probe verified the staged ELF and reported successful startup
restoration in each trial. The candidate ELF SHA-256 was
`83E9FC7E9CFBD1C8906396023D37F1BDE85CB0847F5C5BBCF41C5405A8B2BED4`
and the packed-fraction control was
`7BD56523941A690E55F787EF1236626F078990C12D79FADA9C9A516C8B3B6ED6`.
The [per-invocation CSV](../../tools/experiments/generator-throughput-20261119/exact-fill-three-runs.csv)
includes cold run zero. Rebuild `section-snake-fill-three` with the
existing experiment checkout and export scripts. Use the test commands in
the [packed-fraction report](generator-exact-packed-fraction-sm8550-20261120.md)
with the packed-fraction variant as control.

## Screening runs

Each screen used one cold and four warm invocations on the primary
seed. The probe verified a distinct ELF, the reference PCM and startup
restoration for all five alternatives. These short unbracketed timings
serve as screening evidence.

| Candidate change | Warm median DSP ms | Outcome |
| --- | ---: | --- |
| Omit the byte mask in the high plane consumed by HMX | 109.797 | Regression, despite preserving PCM and reducing static packets |
| Shorten HMX weight and accumulator-store address setup | 104.630 | Near the packed-fraction timing |
| Use halfword splats and shorter K/M/S coefficient addressing | 104.769 | Near the packed-fraction timing |
| Admit widening multiplies to fill packets with explicit pair dependencies | 104.937 | Removed two static packets, with no clear timing gain |
| Reuse Snake constants across consecutive branch calls | 104.996 | No clear timing gain |

The [screening CSV](../../tools/experiments/generator-throughput-20261119/exact-fill-screening-runs.csv)
includes the five screening binaries, the three-packet screen, and the
instrumented runs. The small changes to outer setup left the repeated
per-row polynomial and both output planes in the fill loop. Reducing that
repeated work, or overlapping it with independently ready work, remains
the larger opportunity suggested by the profile.
