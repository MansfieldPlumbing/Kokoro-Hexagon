# Hardware Receipt: Kokoro ResBlock R0Sub0 Aligned 7712 Padding & Post-Affine Masking

- Date: 2026-09-23
- Target: Samsung Galaxy S23 (SM-S911U / Snapdragon 8 Gen 2 / SM8550 / Hexagon V73)
- Host Harness: Pure PowerShell 7.4 over FastRPC `libcdsprpc.so` (`dev.mansfieldplumbing.androidsma.preview`)
- Execution Boundary: Unsigned CDSP User Process Domain (Domain ID 3)
- Emitted Artifact: `libkokoro_r0sub0_skel.so` (SHA-256: `5DB9CA283D0D2B9989480BAC1FE162A1E55DEE5646F706639D188D68B9999D00`)

## Objective & Invariant

Verify the impact of eliminating unaligned channel striding by padding activation tensors to 128-byte vector alignment:
1. Padded channel stride: $7712\text{ floats} = 241 \times 32\text{ floats} = 241 \times 128\text{ bytes} = 30,848\text{ bytes} \equiv 0 \pmod{128}$.
2. Channel loop structure: 128 outer channels, 241 inner vector iterations ($128 \times 241 = 30,848$ total vectors).
3. Post-affine masking: Evaluates $y = ((1 + \gamma)\hat{x} + \beta) \cdot m_t$ to zero out trailing padding frames ($t \ge 6721$) and prevent $\beta$ energy bleed into convolution taps.
4. Compare physical execution latency against the previous unaligned flat loop (8.142 ms).

## Verification Chain

1. **Independent Oracle Verification**:
   - Instruction sequence emitted via pure PowerShell named encoders in `src/emit/Hexagon.ps1`.
   - Assembled independently via Qualcomm Hexagon SDK `hexagon-llvm-mc -triple=hexagon -mcpu=hexagonv73 -mattr=+hvxv73,+hvx-length128b,+hvx-ieee-fp`.
   - Code bytes match: **100% bit-exact (544 bytes)**.
   - 12 invalid operands rejected. Zero relocations, zero imports.

2. **Physical Hardware Execution**:
   - Device: Samsung Galaxy S23 (SM8550, Hexagon V73).
   - Execution log from `tools/Invoke-R0Sub0Probe.ps1`:

```text
Job=kokoro-r0sub0-emitted
LibrarySHA256=5DB9CA283D0D2B9989480BAC1FE162A1E55DEE5646F706639D188D68B9999D00
UnsignedPdRc=0
OpenRc=0
WeightsBytes=1195008 InZBytes=3932672 InMaskBytes=30724
SetupMs=222.507
ColdInvokeRc=0 ColdInvokeMs=10.420
InZSHA256=A777245CDEFA47C35FADE8B7280272E3362E2E9D1ADD48B291ADBAB7535FA321
OutSHA256=29070BE9E9F13568184E5F2BBFDC85577D74236A02B61DC0D97238D8F8B2C75D
OutputNonZero=True OutputComputed=True
Iter=0 Ms=7.676
Iter=1 Ms=7.434
Iter=2 Ms=8.116
Iter=3 Ms=7.973
Iter=4 Ms=8.431
Iter=5 Ms=7.634
Iter=6 Ms=7.111
Iter=7 Ms=7.259
Iter=8 Ms=7.403
Iter=9 Ms=7.399
Iter=10 Ms=7.337
Iter=11 Ms=7.534
WarmMedianMs=7.484 MinMs=7.111 MaxMs=8.431
WrongFramesRc=14
WrongChannelsRc=14
PostIntegrity=True
CloseRc=0
Passed=True
StartupRestored=True
```

## Comparative Latency Analysis

| Implementation | Geometry / Layout | Vector Loops | Pointwise Operations | Warm Median Latency | Min Latency |
|---|---|---:|---|---:|---:|
| **Scalar Affine Baseline** | Flat [128, 7681] | 0 (Scalar) | Affine Only | 25.998 ms | 25.412 ms |
| **HVX Flat Streaming Floor** | Flat [128, 7681] | 30,724 | Memory In/Out Stream | 5.212 ms | 5.094 ms |
| **HVX Flat AdaIN + Snake** | Flat [128, 7681] | 30,724 | AdaIN + Snake (unmasked) | 8.142 ms | 7.820 ms |
| **HVX Aligned 7712 Padded** | Channel-Aligned [128, 7712] | **30,848** | **AdaIN + Snake + Post-Affine Mask** | **7.484 ms** | **7.111 ms** |

### Key Findings

1. **Alignment Dividend Evidence & Compound Effects**:
   - Despite processing **124 more vector iterations** (30,848 vs 30,724 vectors) and executing **additional vector multiplication** (`y * mask`), the aligned channel geometry reduced median execution time by **-0.658 ms** (from 8.142 ms to 7.484 ms), with a floor of **7.111 ms**.
   - **Measurement Boundary**: While eliminating the unaligned load hazard and keeping memory transactions 128-byte aligned is very plausibly responsible for a meaningful performance gain (since the new kernel does strictly more arithmetic and still wins), this is not an isolated single-variable measurement. The kernel simultaneously introduced padded loop geometry and in-register post-affine masking. An exact isolated measurement of the unaligned penalty requires an identical mathematical body with only packed vs aligned stride changed.
2. **Post-Affine Zero Tail Enforcement**:
   - The post-affine activation is multiplied by $m_t$ within vector registers before storing or feeding subsequent operations. This guarantees padding frames remain clean 0.0f floats, preventing $\beta$ drift into convolution taps.
3. **Guard Boundary Ratchet**:
   - Tested geometry bounds: $T \ne 7681$ and $C \ne 128$ both immediately reject with `AEE_EBADPARM` (`rc = 14`), enforcing strict type contracts.
