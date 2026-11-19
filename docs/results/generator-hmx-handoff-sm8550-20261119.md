# Lighthouse generator HMX handoff on SM8550

Revision `371ee3e` rendered the 11.775 s lighthouse passage using `pwsh` and the repo-pinned `adb.ps1`. The scratch trace captured `256_c256`, zero-based span 2, block 44 (tiles 176–179). This is the last block of an interior span. The stage 0→1 handoff stays within the block and requires no edge padding. The packer and production schedule stayed unchanged.

| Warm median from stage 0 branch 2 return | Queued schedule |
| ---: | --- |
| −32.99 µs | Stage 1 branch 0 panel is queued into its freed slot while the remaining stage 0 branches run. |
| 0.00 µs | Stage 0 branch 2 returns. |
| 0.05 µs | Final stage 1 panel has been submitted. DMA can drain during history save, plane combine, history restore and activation fill. |
| 5.36 µs | Stage 0 history save has finished. Plane combine starts. |
| 13.15 µs | Combine has joined and stage 1 history is in place. AdaIN/Snake starts filling the four new tiles. |
| 49.43 µs | The fill joins. The activation window is ready for consumption after the following `syncht`. |
| 49.48 µs | `dmwait` has returned, guaranteeing all panels are ready in VTCM. Stage 1 branch 0 enters HMX call setup. |

The queued handoff took 49.43–49.53 µs over four warm runs. The activation chain gated the next call. AdaIN/Snake fill, including dispatch and worker join, was the largest interval at 36.30 µs, about 73% of the gap. The queued fence took at most one 19.2 MHz tick (0.052 µs). With the existing queued-weight control disabled, the three blocking copies took 28.57 µs before activation preparation. The fill still took 36.30 µs and the handoff grew to 77.99 µs.

The marks resolve DMA submission and the shared fence. They cannot distinguish individual panel completion, DMA service versus queue residence, or the exact overlap with each compute step. The fill interval includes dispatch and worker join. The HMX markers bracket the software call, including the next call's argument setup. The exact matrix instruction boundaries remain unresolved.

| Whole-generator DSP | Warm runs | Median | Range |
| --- | ---: | ---: | ---: |
| Queued, instrumentation off | 7 | 227.08 ms | 224.59–228.07 ms |
| Queued, scratch trace | 4 | 226.17 ms | 224.21–227.36 ms |
| Synchronous, scratch trace | 4 | 239.04 ms | 237.43–240.09 ms |

The traced and untraced queued ranges overlap, so the batches do not resolve trace overhead. All runs returned PCM SHA-256 `B61ACE349E3090D910E1F6E6EB20378FE70F89D38DD421B4C0AF978BFBE1A6BF`. Local build receipts are [instrumentation off](../../build/pcm-return-20261118T115942/handoff-baseline-current.log), [queued](../../build/pcm-return-20261118T115942/handoff-study/queued-header.log) and [synchronous](../../build/pcm-return-20261118T115942/handoff-study/sync-header.log).
