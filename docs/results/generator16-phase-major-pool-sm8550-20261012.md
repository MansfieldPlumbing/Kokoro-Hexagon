# Generator16 phase-major conversion on the existing pool, SM8550, 2026-10-12

Base commit: `98a9bd5` (vector row padding); the pool change is committed with this receipt. Target: SM8550 through `dev.mansfieldplumbing.kokoro`. P1 is the combined statistics job; P3 is the generator-only Constants job. Both use peach, `ResBlockFrames=10201`, `ResidentHvxThreads=4`, `ResidentBatchTiles=14`.

## Source inspection before implementation

`src/kernels/Kokoro.HarPhaseMajor16.ps1:2-10` specifies `X'[22 rho + c][m'] = har[c][6 m' + rho]`. The conversion copies the value byte of each halfword in both planes from 22 source channels into 132 phase-major channels of a 256-channel tensor. Unwritten channels and rows retain the prefilled zero. The ordinary entry processes six phases per output row; the trailing-row entry processes one phase.

The row addressing at `src/kernels/Kokoro.HarPhaseMajor16.ps1:31-44` computes the destination only from the absolute output row and phase/channel; source values are read without modification. Complete output tiles therefore have disjoint write addresses and no dependencies on one another. Source and destination planes occupy separate existing VTCM regions (`src/jobs/Kokoro.Generator60x16Run.ps1:184`).

The STFT currently computes polar values into its 64-channel har planes, then copies those planes to DDR (`src/jobs/Kokoro.HarmonicStft16Run.ps1:86-99`). The polar writer could also scatter directly to phase-major destinations using `m'=floor(t/6)`, `rho=t%6`, channel `22 rho+c`. This would need to preserve the current har layout for the 60x front, the trailing one-phase row and all zero padding. This is a possible writer change, not an implemented or measured saving; STFT and harmonic-source files were not changed.

## Pool admission and implementation

The existing `$parallel` dispatcher runs 53 complete 32-row destination tiles on the control thread and three existing workers. The chunks contain 14, 14, 14 and 11 tiles. Their output row intervals are `[0,448)`, `[448,896)`, `[896,1344)` and `[1344,1696)`. The original row entry handles rows 1696 through 1699; the original one-phase entry handles row 1700. The complete-tile ranges and serial tail are disjoint and complete; host evidence is `build/generator-phase-major-partition.clixml`.

The kernel's `-TileBatch` entry adapts the existing pool arguments to the unchanged row-copy body. It derives the absolute first row from `(chunkHigh-fullHigh)/512`, restores the full destination bases and processes `32*tileCount` rows. Source-plane pointers stay fixed; only destination pointers use the pool's 16384-byte tile stride. It uses caller-saved registers and existing instruction encodings. The live-frame work in progress retains its original serial call path and remains unstaged.

## Output gate and measurements

Command: `Invoke-KokoroDevelopment.ps1 Run -Case generator-pmu -Parameters @{Parity='Pcm'} -OutputDirectory build/generator-phase-major-pool-20261012-170255`.

Evidence: `build/generator-phase-major-pool-20261012-170255/profile.clixml`. Three runs per unprofiled configuration and per PMU counter set. Both unprofiled outputs and all four profiled outputs match their accepted pre-optimization PCM byte for byte:

- P1: `E6456751BDBCCE0D5CB38DA8226B4EEC8B1C514E16626755C5BD975699374054`, the accepted FEFF54DF library's PCM.
- P3: `452A5A96CB9A15C6A75ADF191F99743EFBBD9035B382E7A033057D01C3B79449`.

| Profile | Site 33 before ms | Site 33 after ms | Unprofiled DSP median ms | Profiled DSP median A / B ms |
|---|---:|---:|---:|---:|
| P1 | 14.879323 | 4.535313 | 113.628 | 117.180 / 118.305 |
| P3 | 14.877448 | 4.466354 | 89.178 | 91.763 / 91.374 |

Before means the vector-padding measurement at `98a9bd5`. Site times are from the final set-A execution and include pool dispatch, completion waits and the serial tail. They are not medians. Category and stage ticks agree exactly for every profiled output. Final TileFix measurements are P1 1.168906 ms and P3 0.954375 ms; its implementation is unchanged from `98a9bd5`.

New unprofiled library SHA256s:

| Profile | SHA256 |
|---|---|
| P1 | `EB1B905E057FD2454AA1A555BF8F64400DD9B956C8BC23EB37EC559768A47BC5` |
| P3 | `97FD245178351F91A9FD96B0DC6DC8DFDD87DE76BB4EA14CF698CBC63F840408` |

Set-A profiled SHA256s are P1 `670EDFD86555A6DA083C3A66B7B4FE7F6F60198C7EEFA471549EE34FE8ABD535`, P3 `6359863AA5669E8B0338D8183052ADDFCDE9491F35AB83D627887DE49399B789`. Full counter-set artifact identities remain in the CLIXML receipt.

`Invoke-KokoroDevelopment.ps1 Verify` passed before commit. The generator's own three hunks were staged with `git apply --cached`; the remaining unstaged generator changes match the pre-task runtime-frame hunks exactly. Other protected source-file hashes are unchanged. No pushes.
