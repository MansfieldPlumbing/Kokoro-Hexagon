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

## Issue interval (set C, 1 run, skel `7EC1C5A32E1538162FF5220A7702B6036DB4348F06D8E32FB1692D3F5D01CB6F`)

Events 0x7 committed one cycle after the thread's previous packet (B2B), 0x4 two cycles after
(BSB), 0xeb cluster busy (interlock, port conflict, "no B2B HVX", HVX FIFO full), 0x300 cycles
with one packet committed, 0x3, 0x8 SMT packets, 0x25 packets with one thread running, 0x306
cycles with both clusters committing. Numbers from the V75 PRM in SDK 6.4.0.2 (the V73 table
is not compared); 0x3 here equals set A's within 0.03%.

| Category | Packets | B2B | BSB | HVX packets (set A) | Cluster busy |
| --- | ---: | ---: | ---: | ---: | ---: |
| AdaIN + Snake | 52.47 M | 11.92 M | 39.87 M | 40.41 M | 10.20 M |
| Residual | 4.46 M | 0.64 M | 3.64 M | 3.94 M | 0.03 M |
| Coefficients (scalar) | 1.69 M | 1.10 M | 0.49 M | 0 | 0.44 M |

In the HVX bodies the two-cycle commits match the HVX packets and the back-to-back commits
match the scalar packets: one thread issues an HVX packet at most every second cycle, and
scalar packets fill the cycle between. SMT packets are under 0.2%: no other thread runs.
For one thread the HVX body costs about 2 cycles per HVX packet plus interlocks
(AdaIN + Snake: 2 x 40.41 M + 6.63 M register-order stalls + others = 95.8 M cycles).

## What this changes

- The stage is one HVX body, not data movement: AdaIN + Snake is 79% of the time, DMA 0.6%.
- One thread issues one HVX packet per two cycles. Two levers follow: more HVX instructions
  per packet (the time is per packet, not per instruction), and a second thread for the idle
  cycle. The thread-scaling run measures the second.
- In the AdaIN + Snake body the permute pipe sets the packing floor: 64 `vlut16` per vector
  against 128 HVX packets today, so packing alone is worth up to 2x on 79% of the stage.
