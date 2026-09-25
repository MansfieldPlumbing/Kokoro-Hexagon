# Hardware receipt: model-lowered R0Sub0 versus LLVM

Date: 2026-09-24  
Device: retail Samsung Galaxy S23, SM8550, Hexagon V73  
Scope: the pinned R0Sub0 elementwise benchmark kernel only

## Compared artifacts

- Model-aware PowerShell lowering: `EDE5B12562BD6C07EE247B45FA09FE1A67E40E3EE8C5C23D495BF81CA27D7E4B`
- Qualcomm Hexagon Clang 19.0.04 baseline: `F9B01F25D53160ACFC6D431E054E1852652958879527F1DE9A5BB0E09896CF49`
- Gold and both output hashes: `29070BE9E9F13568184E5F2BBFDC85577D74236A02B61DC0D97238D8F8B2C75D`
- Emitted code passed the pinned SDK assembler oracle byte-for-byte: 1,032 code bytes, zero imports, zero relocations.

The lowered schedule uses eight independent lanes and 30 HVX vector registers. Each lane preserves the graph's floating-point operation order. Hardware timing uses `c31:30` around the compute region; host timing covers the FastRPC invoke.

## Counterbalanced physical runs

Each competitor received one cold invoke followed by 12 warm invocations. The second run reversed execution order.

| Execution order | Lowered median ticks | LLVM median ticks | Tick speedup | Lowered median invoke | LLVM median invoke | Invoke speedup |
|---|---:|---:|---:|---:|---:|---:|
| LLVM, PowerShell | 32,726 | 72,416 | 2.213x | 5.522 ms | 7.851 ms | 1.422x |
| PowerShell, LLVM | 34,524 | 77,890 | 2.256x | 6.548 ms | 8.777 ms | 1.340x |

Across both orders, the slowest lowered hardware sample was 40,036 ticks and the fastest LLVM sample was 63,739 ticks. Output parity and both performance gates passed in both runs. The host startup files were restored and hash-checked after each run.

External raw receipts:

- LLVM-first SHA-256: `5F2AAAD8E6F0FE4319F6C73F474F132AB58A84566A9DED6FFB7AE53233FA71A9`
- PowerShell-first SHA-256: `28A786FD7DEB97CD9D1E9348005D612A632E096B6D51A44585A56984F270491B`

## Claim boundary

This demonstrates that the model-aware eight-lane specialization outperforms the pinned LLVM-generated implementation for this kernel on this device. It is not a claim about unrelated kernels, other devices, or LLVM in general.
