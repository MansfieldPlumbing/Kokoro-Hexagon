# Resident 60x stage, hardware counters on SM8550 — 2026-10-07

Base commit `4e4ffd6` plus uncommitted changes: `-PmuEvents` in
`src/emit/Kokoro.Generator60xResidentRun.ps1`, the `upcycle` form in `src/emit/Hexagon.ps1`,
the record reader in `src/runspace/KokoroResBlockRunProbe.ps1`. Fixture
`build/generator60x-run-fixture-20261006`, harness `tools/Invoke-ResBlockRunProbe.ps1 -Graph Generator60x`.

Without `-PmuEvents` the skel is byte-identical to the receipted one (`11F85FEE…`). Instrumented
skels (instruction bytes match SDK 6.4.0.2 `hexagon-llvm-mc`):

| Event set | Skel SHA-256 | Runs | Output |
| --- | --- | --- | --- |
| A | `44549386B79050CA2628189DD5C109590746FDC159F6E1C62783F7B50EAA53CD` | 3 | 0/999,424 lanes, 0/18,432 coefficient bytes |
| B | `FCB5567A6208BC338E91C95D5147B8A7F825B8A28B7233047703FE69C45802CC` | 1 | same |

Median region 86.55 ms instrumented (86.05 ms receipted without counters).

## Method

QuRT PMU calls are the `libqurt.a` trap stubs (SDK 6.4.0.2 `computev73/lib/pic/libqurt.a`,
SHA-256 `8e0ba5fd…`) emitted inline; the DSP image does not export them to the skel (an import
build failed to load, `0x80000406`). Event selects: A = 0x3 committed packets, 0x111 HVX packets,
0x100 HVX active, 0x101 HVX register-order stalls, 0x105 VTCM outstanding, 0x128 ALU pipe,
0x129 multiply pipe, 0x103 L2 load outstanding. B = 0x12a shift pipe, 0x12b permute pipe,
0x115/0x116/0x117/0x12c cycles with 1/2/3/4 HVX contexts running, 0x3, 0x111. Cycles from
UPCYCLE, time from UTIMER (19.2 MHz). A mark after each segment charges the counts since the
previous mark to that segment's category.

## Results (run 0, set A; runs 1-2 within 0.4%)

| Category | ms | Share | Packets / cycle | Notes |
| --- | ---: | ---: | ---: | --- |
| AdaIN + Snake body | 68.35 | 79.0% | 0.55 | 40.41 M HVX packets, 6.63 M register-order stalls |
| Residual | 6.57 | 7.6% | 0.48 | |
| Moments | 4.20 | 4.9% | 0.49 | |
| Coefficients (scalar) | 2.43 | 2.8% | 0.49 | |
| HMX conv | 2.02 | 2.3% | 0.32 | |
| Tile fixes | 1.24 | 1.4% | 0.17 | |
| Branch mean | 1.08 | 1.2% | 0.43 | |
| DMA | 0.54 | 0.6% | 0.01 | |
| Sync | 0.11 | 0.1% | 0.33 | |

- `qurt_hvx_get_units()` = `0x400`: four 128-byte HVX contexts. Only one is used today
  (cycles with 1 context running = HVX active cycles, 95.48 M; 2-4 contexts: 0).
- UPCYCLE / UTIMER = 73.0, i.e. 1.40 GHz while the stage runs.
- One packet per HVX instruction: the counted HVX packets, ALU-pipe, multiply-pipe (2 per 16-bit
  multiply), shift-pipe and permute-pipe counts equal the static counts of
  `tools/Measure-HexagonPackingBound.ps1` exactly (AdaIN + Snake: 128 HVX, 82 shift, 64 permute
  instructions per vector). 0x12a and 0x12b, provisional for V73 from the manuals, count the
  shift and permute pipes.
- L2 load stalls 0 and VTCM stalls 0.7 M against 95.8 M cycles: the stage is not memory-bound.

## What this changes

- The stage is one HVX body, not data movement: AdaIN + Snake is 79% of the time, DMA 0.6%.
- One thread commits 0.48-0.55 packets per cycle in scalar and vector code alike;
  register-order stalls explain 6.6 M of the 43 M cycles above one packet per cycle. Whether a
  second thread fills those cycles is the next measurement (a thread-scaling run).
- In the AdaIN + Snake body the permute pipe sets the floor: 64 `vlut16` per vector against
  165 packets today.
