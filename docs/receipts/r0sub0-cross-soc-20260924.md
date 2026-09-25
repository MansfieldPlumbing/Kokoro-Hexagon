# Cross-SoC receipt: model-lowered R0Sub0 versus LLVM

Date: 2026-09-24  
Device under test: retail Motorola razr+ 2024, SM8635  
Prior device: retail Samsung Galaxy S23, SM8550  
Scope: the pinned R0Sub0 elementwise benchmark kernel only

## Reused artifacts

The SM8635 test used the same artifacts and inputs as the prior SM8550 test.
Nothing was recompiled or tuned for the second device.

- Model-aware PowerShell lowering: `EDE5B12562BD6C07EE247B45FA09FE1A67E40E3EE8C5C23D495BF81CA27D7E4B`
- Qualcomm Hexagon Clang 19.0.04 baseline: `F9B01F25D53160ACFC6D431E054E1852652958879527F1DE9A5BB0E09896CF49`
- Android host APK: `F2540FDD33D8511E2CD114B2C04A22F4A2961C878D4118A5D29DF2AD80087180`
- Native-call helper: `B4820C76C79FC0B66EE96E27E8D655689F33181165F55E2B0A96A3A4BE34391D`
- Static weights: `997CF6049BBDF8BD987CC757CE04D5EEF73C167315C4E426FEF275AB4A0F3B05`
- Input tensor: `95BBBE5BAC44721D49F43A773A17728AD75308F3505676DA29B2D47FA5656662`
- Input mask: `2233712F0CCFE5B23C9A1F599BD1D0580285BD127D2F1B32C119A547562255B3`
- Gold and both output hashes: `29070BE9E9F13568184E5F2BBFDC85577D74236A02B61DC0D97238D8F8B2C75D`

The clean device install required the helper, weights, input, and mask to be
staged before the benchmark. Their hashes were checked against the established
SM8550 copies before execution.

## Counterbalanced SM8635 runs

Each competitor received one cold invoke followed by 12 warm invocations. The
second run reversed execution order.

| Execution order | Lowered median ticks | LLVM median ticks | Tick speedup | Lowered median invoke | LLVM median invoke | Invoke speedup |
|---|---:|---:|---:|---:|---:|---:|
| LLVM, PowerShell | 30,584 | 69,916 | 2.286x | 8.095 ms | 10.880 ms | 1.344x |
| PowerShell, LLVM | 33,506 | 77,114 | 2.302x | 11.592 ms | 14.450 ms | 1.247x |

Both runs configured the unsigned protection domain successfully, opened both
libraries, matched the pinned gold output byte-for-byte, passed the performance
ratchet, and restored the host startup files.

Redacted external raw-receipt hashes:

- LLVM-first: `F58FED9940D03D92BBE212FE35112E0DB657E9451E548E210792689B03B9F85D`
- PowerShell-first: `77DAD8648BEF0BCB879E4D889338CBB491807A6EA5532926E81F9AA19FA8DD44`

## Cross-device comparison

The prior SM8550 receipt measured 2.213x and 2.256x median tick speedups. The
unchanged artifacts measured 2.286x and 2.302x on SM8635. Host-side invoke time
was more variable on the SM8635 device, so cross-device latency is not treated
as a silicon comparison.

## Claim boundary

This validates identical R0Sub0 binaries and inputs on two distinct commercial
Qualcomm SoCs, SM8550 and SM8635. It demonstrates portability of this pinned
V73-compatible kernel and preserves output parity on both devices. It does not
establish portability to another vendor, another DSP ISA, unrelated kernels,
or the complete Kokoro model.

The SM8550 measurements and artifact construction evidence are in
`docs/receipts/r0sub0-lowered-vs-llvm-20260924.md`.
