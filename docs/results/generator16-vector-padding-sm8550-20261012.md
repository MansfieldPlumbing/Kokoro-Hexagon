# Generator16 vector row padding, SM8550, 2026-10-12

Base commit: `8e1b33e`; the padding change is committed with this receipt. Target: SM8550 via `dev.mansfieldplumbing.kokoro`. P1 is the combined statistics job; P3 is the generator-only Constants job. Both use peach, `ResBlockFrames=10201`, four resident HVX threads and batch size 14.

## Emission-time count

A PowerShell breakpoint at the original `$padRows` entry counted every helper invocation while building P1, before any optimization or device run. Evidence: `build/generator-padrows-counts.clixml`.

| Section frames | Calls | Invalid rows per call | Channel blocks | Scalar word iterations |
|---:|---:|---:|---:|---:|
| 1,700 | 74 | 28 | 8 | 530,432 |
| 10,201 | 74 | 7 | 4 | 66,304 |
| Total | 148 | | | 596,736 |

Each scalar iteration loaded a word, preserved its valid halfword, inserted the padding halfword, stored it and updated the loop. These counts support row padding as the measured TileFix cost. The category has 350 calls: 148 padding calls and 202 unchanged fill calls.

The replacement constructs each row-pair's keep mask and padding vector once per tile, then reuses them across channel blocks. Each affected 128-byte vector is loaded, selected with existing `vand`/`vor`, and stored. An odd valid-row count preserves the lower halfword of the first affected vector. The two sections require 8,288 and 1,184 vector operations respectively, 9,472 total. No new encoder instruction or lowered-encoder change was required.

## Phone gate and timing

Command: `Invoke-KokoroDevelopment.ps1 Run -Case generator-pmu -Parameters @{Parity='Pcm'} -OutputDirectory build/generator-padrows-vector-20261012-165316`.

Evidence: `build/generator-padrows-vector-20261012-165316/profile.clixml`. The PCM parity mode records changed library hashes, checks unprofiled PCM, then checks both PMU counter sets. Each configuration runs three times. Unprofiled and profiled PCM match their pre-change references byte for byte:

- P1 PCM SHA256: `E6456751BDBCCE0D5CB38DA8226B4EEC8B1C514E16626755C5BD975699374054`, the accepted FEFF54DF library's output.
- P3 PCM SHA256: `452A5A96CB9A15C6A75ADF191F99743EFBBD9035B382E7A033057D01C3B79449`.

| Profile | TileFix before ms | TileFix after ms | After HVX packets | Unprofiled DSP median ms |
|---|---:|---:|---:|---:|
| P1 | 22.556406 | 1.182656 | 88,599 | 123.791 |
| P3 | 22.536615 | 1.361615 | 88,707 | 98.103 |

TileFix times and packets are from the final set-A execution, not medians. This category includes the unchanged fills and PMU overhead. Site 33 remains 14.879323 ms in P1 and 14.877448 ms in P3; this commit does not change the harmonic conversion.

New unprofiled library SHA256s:

| Profile | SHA256 |
|---|---|
| P1 | `DA3DFE876F80C3339B593391BD189443AC3748AA47209CECF26824FE0B708C42` |
| P3 | `58FEE8016EAB1FDBADDB53686F96618672BADA3378B267B27B4FB7BA73DD644C` |

Set-A profiled library SHA256s are P1 `A062B3710BD8B31B8BB40DB2394C4A0F6E716A9846871ACECB11A32B5F0D4EAA`, P3 `CE909CE68E44F2E094B4BFD487C0128896B17FB159CCC84AF18EB7B4957DF2D1`. All counter-set artifact hashes remain in the CLIXML receipt.

`Invoke-KokoroDevelopment.ps1 Verify` passed before commit. Only the `$padRows` hunk was staged from the generator source, with `git apply --cached`; its unrelated runtime-frame edits remain unstaged. No pushes.
