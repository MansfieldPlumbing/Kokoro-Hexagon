# r0.0 HVX Physical-Substrate Receipt (R0SUB0-HVX-POINTWISE-R001)

## Date: 2026-09-23
## Target: Samsung Galaxy S23 (SM8550 / Hexagon V73)
## Host: AndroidSMA Preview Host (`dev.mansfieldplumbing.androidsma.preview`)

---

## 1. Proven Scope vs. Architectural Boundary

### What This Receipt Proves:
1. **PowerShell-Authored Native HVX Emission**: Pure PowerShell named encoders in `src/emit/Hexagon.ps1` emitted genuine V73 HVX instructions (`vload-post`, `vstore-post`, `vadd-sf`, `vmpy-sf`, `vsplat`).
2. **Physical Hardware Execution on SM8550**: The in-memory synthesized ELF shared object loaded and executed on the physical Qualcomm Snapdragon 8 Gen 2 cDSP.
3. **128-byte HVX Vector Geometry Verified**: The loop geometry $983,168 / 32 = 30,724$ vector iterations matches physical HVX width (128 bytes = 32 FP32 lanes).
4. **Whole-Path Streaming Floor**: Pure 128-byte vector streaming moved/read/wrote 7.86 MB (3.93 MB in, 3.93 MB out) with a warm median latency of **5.212 ms** (minimum 4.704 ms), establishing an effective whole-path throughput floor of ~1.51 GB/s under the current admission path.
5. **In-Register Pointwise Vector Arithmetic Executed**: Adding an 11-instruction vector floating-point arithmetic body (affine scale, shift, polynomial evaluation, squaring, inverse scaling) raised wall-clock latency to **8.142 ms** (minimum 7.251 ms)—an addition of **+2.930 ms** of execution time across all 983,168 elements.
6. **Scalar Path Superseded**: The prior 25.998 ms scalar affine receipt (`kokoro-affine-emitted-20260923.md`) is superseded ($25.998 / 8.142 \approx 3.19\times$ wall-clock speedup) despite the HVX path performing substantially more arithmetic.

### What Is NOT Yet Demonstrated (Not Full `r0.0` Parity):
- **AdaIN Temporal Statistics**: Full-tensor temporal reductions for $\mu_c, \sigma_c$ were not executed in this pass.
- **Snake Semantic Parity**: `OutputComputed=True (non-zero)` confirms that HVX vector polynomial arithmetic executed on hardware; it does **not** establish semantic equivalence or error bounds against Kokoro's exact $\sin^2$ function at the resblock output boundary.
- **Convolution Layers**: Neither Conv1 ($128 \times 128 \times 3$) nor Conv2 was accumulated.
- **Full Resblock Parity**: Residual addition and end-to-end bit-exact match against `reference_sub0.f32` remain ahead.

---

## 2. Hardware Measurements & Comparative Benchmark

| Specimen / Kernel | Execution Mode | Measured Hardware Time (Warm Median, 12 calls) | Code Size | Output Verification |
|---|---|---:|---:|---|
| **Prior Scalar Affine Baseline** | Scalar R-register (`sfmpy` + `sfadd`) | **25.998 ms** | 1,216 bytes | Bit-exact reference |
| **HVX 128-byte Vector Streaming** | 128-byte HVX (`vload-post` + `vstore-post`) | **5.212 ms** (min 4.704 ms) | 428 bytes | `VectorStreamingMatch=True` (exact byte echo) |
| **HVX In-Register Pointwise Arithmetic** | 128-byte HVX Pipeline (11 vector ops/iter) | **8.142 ms** (min 7.251 ms) | 508 bytes | `OutputComputed=True` (non-zero arithmetic output) |

### Arithmetic vs. Memory Traversal Profile:
```text
Whole-path streaming floor:     5.212 ms
Pointwise arithmetic execution: 8.142 ms
Difference:                     2.930 ms
```
- Moving 7.86 MB in and out across the host-DSP execution path accounts for **64% of the wall-clock time** (5.212 ms).
- The vector arithmetic itself adds only **2.930 ms** across nearly 1 million values ($<3\text{ ns}$ per element).
- **Core Architectural Takeaway**: The vector arithmetic is sufficiently fast that memory traversal and buffer materialization are the dominant latency bottlenecks to attack.

### Analytical Instruction Estimate:
- Scalar reference required 983,168 scalar iterations (~5.9M dynamic instructions estimated).
- HVX 128-byte vectors process 32 single-precision elements per vector instruction, requiring **30,724 vector loop iterations** (~368k dynamic instructions estimated)—an analytical reduction of $\approx 16\times$ in dynamic instruction traffic.

---

## 3. Admission & Platform State

- **Unsigned PD Configuration**: `remote_session_control(2, {3, 1}, 8)` returned `rc=0`.
- **FastRPC Handle Lifecycle**: Opened `file:///libkokoro_r0sub0_skel.so?kokoro_r0sub0_skel_handle_invoke&_modver=1.0&_dom=cdsp` with `rc=0`, closed with `rc=0`.
- **Parameter Validation Guards**:
  - Altered frame dimension ($7681 \rightarrow 7680$) rejected with `WrongFramesRc=14` (`AEE_EBADPARM`).
  - Altered channel dimension ($128 \rightarrow 64$) rejected with `WrongChannelsRc=14`.
- **Host Hygiene**:
  - Device serial numbers pass exclusively via `$env:KOKORO_QNN_SERIAL` and are redacted to `[DEVICE_SERIAL_REDACTED]`.
  - Temporary `/data/local/tmp/` staging directories scrubbed on exit.
  - Startup scripts (`Start.ps1`, `PROFILE.PS1`) verified and restored (`StartupRestored=True`).

---

## 4. Provenance & Artifact Hashes

- **Emitted Library**: `libkokoro_r0sub0_skel.so`
  - SHA-256: `10F7D4B928B2A7A48F94B626680A341CB65AAAFFC2F33DDD46BB695397FF6D4A`
  - Bytes: 8,384 bytes (Code: 508 bytes)
  - Verification: 100% bit-exact match against independent SDK `hexagon-llvm-mc` assembler.
- **Input Tensor (`in_z.f32`)**:
  - SHA-256: `95BBBE5BAC44721D49F43A773A17728AD75308F3505676DA29B2D47FA5656662`
  - Bytes: 3,932,672 bytes ($128 \times 7681 \times 4$)
- **Computed Output Tensor**:
  - SHA-256: `E3CFD7ADC0CD17DD02ED36986C7AF40E9ACF030FA158684E3ECB9BA292B5566E`
  - Bytes: 3,932,672 bytes
