# HMX activation reads and VTCM pages, SM8550

Kokoro-Hexagon working tree after `0d443d3`, `Invoke-KokoroDevelopment.ps1 Run -Case hmx-vtcm-pages` (3 runs per
configuration, seed 17). Receipt: `build/hmx-vtcm-pages-20261113T113216/receipt.clixml`. Run on an SM8550 phone other
than the one in earlier SM8550 records; same SoC.

## The rule

**An HMX `:single` activation read faults when its two croutons (Rs and Rs + dY) lie in different pages of the VTCM
mapping.** The pages depend on the grant. As modelled here (`Get-KokoroVtcmPageModel`), a grant is the request rounded up
to 256 KiB, mapped from its base in the largest Hexagon page size that is aligned there and fits: 4 MiB, 1 MiB or
256 KiB. A 768 KiB grant is three 256 KiB pages; 1.5 MiB is 1 MiB + 256 KiB + 256 KiB; 2.5 MiB is two 1 MiB pages and
two 256 KiB pages; 4 MiB is one page.

The 1 MiB rule found in the V73 simulator (`decoder-sm8550-20261009.md`) is this rule with 1 MiB pages. The depth-first
generator requests 7,602,176 B (modelled as one 4 MiB page, three 1 MiB pages and one 256 KiB page), so keeping its
HMX-read regions inside one 1 MiB page remains correct; small grants are where the 256 KiB pages apply.

## What ran

`KokoroHmxPagesRun`: `src/jobs/Kokoro.HmxConvRun.ps1` (one int8 conv, its own power votes, VTCM and HMX context) under the
phone runner, with `-RunnerTelemetry` (VTCM base in word 40, done in word 44). `-Iterations` runs the first N output
tiles of a layout, `-Shift` places every region that far above the granted base, `-VtcmRequest` asks for more VTCM
without moving anything. Inputs are seeded random activations and weights and zero tables; outputs are not checked.

For each configuration the case first predicts the outcome from the emitted read addresses
(`Get-KokoroHmxReadPageCrossing`, which follows `src/kernels/Kokoro.HmxConv.ps1`) and the page model, then runs it.
A fault is recorded as an outcome (`Invoke-KokoroDeviceJob -ReportJobFault`), not raised.

## Result

12 of 12 outcomes as predicted. The VTCM base was 0xFF000000 in every run and every grant equalled the model's.

| Configuration | Grant | Pages | First crossing tile | Predicted | Observed | Ticks |
| --- | ---: | --- | ---: | --- | --- | ---: |
| 128 ch, k3, 32 tiles | 768 KiB | 256K + 256K + 256K | 30 | fault | fault | |
| same, first 30 tiles | 768 KiB | 256K + 256K + 256K | | pass | pass | 135 |
| same, first 31 tiles | 768 KiB | 256K + 256K + 256K | 30 | fault | fault | |
| same, 1 MiB requested | 1 MiB | 1024K | | pass | pass | 143 |
| same, shifted 64 KiB, first 22 tiles | 768 KiB | 256K + 256K + 256K | | pass | pass | 99 |
| same, shifted 64 KiB, first 23 tiles | 768 KiB | 256K + 256K + 256K | 22 | fault | fault | |
| 128 ch, k11, 32 tiles | 1 MiB | 1024K | | pass | pass | 443 |
| 256 ch, k3, 32 tiles | 1.5 MiB | 1024K + 256K + 256K | | pass | pass | 564 |
| 256 ch, k3, 64 tiles, first 62 | 2.5 MiB | 1024K + 1024K + 256K + 256K | | pass | pass | 1,046 |
| 256 ch, k3, 64 tiles, first 63 | 2.5 MiB | 1024K + 1024K + 256K + 256K | 62 | fault | fault | |
| 256 ch, k3, 64 tiles | 2.5 MiB | 1024K + 1024K + 256K + 256K | 62 | fault | fault | |
| 256 ch, k3, 64 tiles, 4 MiB requested | 4 MiB | 4096K | | pass | pass | 1,069 |

Every fault: invoke rc 0x8000040D, stage 5 (both locks held), no stage 6. The last three rows' predictions (onset at
tile 62; no fault under one 4 MiB page) were made before they were first run.

## The read's window, not the rows it uses

With kernel 1 every tap is at row 0, so each `:single` read needs only the first crouton of its pair. If only data
actually used could fault, kernel 1 would pass where kernel 3 faults. Both predictions were stated before the run
(`-Parameters @{Names=...}`, receipt `build/hmx-vtcm-pages-20261113T121644/receipt.clixml`):

| Configuration | Grant | Window model | Fetch-only model | Observed | Ticks |
| --- | ---: | --- | --- | --- | ---: |
| 128 ch, k1, 32 tiles, first 30 | 768 KiB | pass | pass | pass | 52 |
| 128 ch, k1, 32 tiles | 768 KiB | fault at tile 30 | pass | **fault** | |
| 128 ch, k1, 32 tiles, 1 MiB requested | 1 MiB | pass | pass | pass | 50 |

The fault belongs to the instruction's two-crouton window, whatever rows the tap reads. This does not separate a check
of the window made before the read from a read that always fetches both croutons; either way a layout must treat the
whole pair as accessed. Weight reads (`:deep`, one 2 KB-aligned crouton) and output stores (one crouton) cannot span
two pages at all, which is consistent with every fault here coming from activation reads.

## How the rule was found

A timing sweep of `HmxConvRun` (128 and 256 channels, kernels 3, 7 and 11, 8 to 64 tiles) faulted in 6 of 24 points:
every 256-channel point at 64 tiles, and 128 channels at 31 to 33 tiles for kernels 3 and 7 while kernel 11 passed.
Each step below ran from a scratch harness, not this case; the case reproduces the decisive ones.

| Candidate | Test | Result |
| --- | --- | --- |
| HMX used from a thread without its lock (`hmx-thread-gate-sm8550-20261021.md`, same rc and stage) | lock return codes in the faulted runs | both 0 on the conv's own thread: excluded |
| data values | zero inputs | still faults |
| staged writes not yet landed | `syncht` between staging and the conv | still faults |
| absolute placement | whole layout shifted 64 KiB; passing layout shifted 64 to 192 KiB | outcome unchanged |
| distance between a tile's activation reads and its output stores | only the output moved | faults at 0x66000 to 0x7E000, passes from 0x8E000, but the grant also grew from 768 KiB to 1 MiB |
| the grant's pages | 1 MiB requested with nothing moved | passes at the distance that faulted: distance excluded |

The onset tile (30) is the first whose read pairs croutons at 0x3E000 and 0x40000; the shifted layout's onset (22) is
again the first pair to straddle 0x40000.

## Not established

- The page structure itself: inferred from where faults fall. QuRT's mapping was not read; page sizes other than those
  above, and a 512 KiB grant, are untested.
- Whether the window is checked before the read or both croutons are always fetched.
- Whether output stores or weight reads obey a page rule: as single aligned croutons they cannot span a page, so no
  test here could make them.
- Behaviour on SM8635 (4 MiB of VTCM).
