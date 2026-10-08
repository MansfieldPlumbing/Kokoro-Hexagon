# Resident 60x stage, HVX worker threads on SM8550 — 2026-10-07

Base commit `e1a3ab8` plus uncommitted `-HvxThreads` in
`src/emit/Kokoro.Generator60xResidentRun.ps1` (pool, worker, dispatch) and the pool record
reader in `src/runspace/KokoroResBlockRunProbe.ps1`. Fixture
`build/generator60x-run-fixture-20261006`, harness `tools/Invoke-ResBlockRunProbe.ps1 -Graph Generator60x`,
PMU event set B (see `generator60x-pmu-sm8550-20261007.md`). Without `-HvxThreads` the skel is
byte-identical to the receipted one (`11F85FEE…`); every skel below matches SDK 6.4.0.2
`hexagon-llvm-mc` byte for byte.

## Method

Each fused AdaIN + Snake call (one batch, up to 18 tiles) splits its tiles into contiguous
parts; the job thread runs the first, worker threads the rest. Workers are created once per
job with the exported `qurt_thread_create` (attributes and priority as the SDK 6.4.0.2
multithreading example), lock their own 128-byte HVX context, and wait on a futex for each
dispatch; the job thread waits on each worker's completion word. Futex and HVX lock calls are
the `libqurt.a` trap stubs emitted inline. AdaIN + Snake is elementwise per tile, so the split
does not change the output.

## Results (3 runs each, all 0/999,424 output lanes and 0/18,432 coefficient bytes)

| HVX threads | Skel SHA-256 | Stage median ms | AdaIN + Snake ms (run 0) | Speed-up of that body |
| ---: | --- | ---: | ---: | ---: |
| 1 | `FCB5567A…` | 86.66 | 68.36 | 1.00 |
| 2 | `9C53874C6EC8AC0EDCCFCA3CB7202C894296B41774A82A62D1BD8A09BFAD771B` | 53.22 | 34.95 | 1.96 |
| 3 | `8A50F47F40BED18DD4814EDC3E197754F832B587B6E9F6AD2FF8B2ECD137A0F8` | 44.60 | 26.02 | 2.63 |
| 4 | `55A5C314CDEAE6A371D133EA6130817B2A42547E8066A08313BA67B9D10ABCE0` | 40.76 | 22.15 | 3.09 |

- The AdaIN + Snake cycles with 2, 3 and 4 HVX contexts running (events 0x116, 0x117, 0x12c):
  2 threads 47.3 M of 49.0 M cycles at 2; 3 threads 28.5 M at 3; 4 threads 13.5 M at 4 and
  13.3 M at 3.
- Its instruction counts are unchanged (permute 20.20 M, HVX packets 40.4 M): the same work,
  spread over contexts.
- Four threads lose to the split: 18 tiles in parts of 5, 5, 5, 3 against an even 4.5.
- Join returns `QURT_ENOTHREAD` (30) for workers that already exited; documented in
  `qurt_thread.h`, exit status 0, all 288 dispatches completed by every worker.
- Phases still on one thread: residual 6.6 ms, moments 4.2 ms, coefficients 2.4 ms,
  HMX conv 2.0 ms, tile fixes 1.3 ms, mean 1.1 ms.

Stage at four threads: 40.76 ms for 1.625 s of audio (86.05 ms before).

## Residual and moments on the pool, batch size (four threads, event set A, 3 runs each)

Commit `8de4969` puts the residual and moments bodies on the pool (moments per worker into
private VTCM buffers, added after the join). `-BatchTiles` sets the tiles per batch; each
window is BatchTiles + 2 tiles. All runs 0/999,424 output lanes, 0/18,432 coefficient bytes.

| Batch tiles | Window split per thread | Skel SHA-256 | Stage median ms |
| ---: | --- | --- | ---: |
| 16 | 5, 5, 5, 3 | `6799A9595E33808FB53E907734F8EBC63595530838153DF605A908B71ADCC4CE` | 34.68 |
| 14 | 4, 4, 4, 4 | `A0CA6DABBB4002D43165A0B22E430AE98A267300B7272F1CB362BB24E0362BFE` | 33.85 |
| 22 | 6, 6, 6, 6 | `6011B2D791A523D447A6B37D41713A9BF4601D6EFDE115C2321F1656CEA64DFA` | **31.48** |

At 22 tiles: AdaIN + Snake 19.3 ms, residual 2.4 ms, moments 2.1 ms, coefficients 2.4 ms,
HMX conv 2.0 ms. Every worker's `qurt_hvx_lock` returned 0 (recorded since `506427d`).
**Banked baseline: 31.48 ms per 1.625 s of audio, 8-bit stage, 86.05 ms single-thread.**
