# One-process request lifetime, SM8550, 2026-10-12

Based on `973544f`, using the unchanged resident-payload worker
`FFF1155E6FEE0124FF7832F0BA73333A7DB834A81BFF7C02A84EA2BA5FBFCAC5`.
Authorized app: `dev.mansfieldplumbing.kokoro`. Captured peach inputs,
not unseen-text synthesis. Reference PCM: receipt `541aa1e`.

`Invoke-GeneratorTailProbe.ps1 -ResidentPayloads -RequestLifetime -Runs 31`
starts one measurement process, opens one FastRPC handle, maps weights and
tables once, then performs one warmup and 30 requests. There is no process,
runspace or session restart between requests or gap conditions. The process
and runspace thread are checked at each request; identifiers are not recorded.
The output array and argument block are allocated and pinned once. Cleanup
closes the session and restores the startup files after the entire experiment.

Each request plays and drains its 51,000 PCM samples at 24 kHz before closing
the AAudio stream. Requested idle sleeps of 0, 1 and 5 seconds alternate after
that cleanup; other host bookkeeping is additional to those sleeps. The
recorded span is 138,480.749 ms, including warmup. This playback workload is
different from the earlier uninterrupted invoke-only warm-five measurement.

| Requested idle gap (s) | Requests | Median host invoke (ms) | Median DSP region (ms) |
| --- | ---: | ---: | ---: |
| 0 | 10 | 131.827 | 100.585 |
| 1 | 10 | 139.868 | 100.528 |
| 5 | 10 | 141.592 | 100.626 |

| Request | Requested idle gap (s) | Host invoke (ms) | DSP region (ms) |
| --- | ---: | ---: | ---: |
| 1 | 0 | 118.405 | 98.619 |
| 2 | 1 | 124.848 | 99.157 |
| 3 | 5 | 136.843 | 100.713 |
| 4 | 0 | 124.144 | 100.531 |
| 5 | 1 | 140.993 | 100.616 |
| 6 | 5 | 145.069 | 100.675 |
| 7 | 0 | 143.079 | 100.755 |
| 8 | 1 | 128.418 | 100.945 |
| 9 | 5 | 141.058 | 100.136 |
| 10 | 0 | 126.839 | 100.640 |
| 11 | 1 | 142.854 | 100.565 |
| 12 | 5 | 142.440 | 100.613 |
| 13 | 0 | 140.093 | 100.661 |
| 14 | 1 | 138.742 | 99.883 |
| 15 | 5 | 131.834 | 100.331 |
| 16 | 0 | 121.147 | 98.877 |
| 17 | 1 | 132.233 | 100.490 |
| 18 | 5 | 144.446 | 98.726 |
| 19 | 0 | 134.884 | 100.472 |
| 20 | 1 | 141.828 | 100.758 |
| 21 | 5 | 136.679 | 100.487 |
| 22 | 0 | 128.770 | 100.515 |
| 23 | 1 | 143.175 | 100.206 |
| 24 | 5 | 142.126 | 100.698 |
| 25 | 0 | 135.047 | 100.757 |
| 26 | 1 | 136.468 | 100.620 |
| 27 | 5 | 146.211 | 100.638 |
| 28 | 0 | 135.082 | 100.679 |
| 29 | 1 | 141.276 | 100.355 |
| 30 | 5 | 125.023 | 100.777 |

All 31 invocations returned success, stage 7 and done 1. Every PCM hash was
`67E722EF3D6D3671ADFC8E15ADC870A9A0A5EC91C15B0A4E0F398D6B4BB66028`,
identical to `541aa1e`. All 31 playback drains completed with zero xruns;
both payload unmaps returned zero and startup restoration passed.
Per-call buffers remain pinned managed arrays: control 20 bytes,
activations 202,624 bytes, output/workspace 22,519,808 bytes. No latency
control was requested. Making that workspace resident is a separate step.

Raw receipt and output are under ignored `build/request-lifetime/`.
`Invoke-KokoroDevelopment.ps1 Verify` passed; the shared case-pair check
reported zero pairs in the two changed PowerShell files. No runtime-frames
files were edited and nothing was pushed.
