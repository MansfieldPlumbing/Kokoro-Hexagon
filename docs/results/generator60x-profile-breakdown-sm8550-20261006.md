# Generator60x Performance Attribution Breakdown — 2026-10-06

Diagnostic performance-attribution experiment on the verified 19-stage `Generator60x` worker (K3, K7, K11 residual branches + 3-branch mean, 7,801 frames / 244 tiles).
ELF (PROFILE-ONLY): `761A351219A3EEE1AA6929B6F4FD62CE6378F78A813806131FEFA43CDF9E0C54`.
Correctness verified across 3/3 runs on SM8550: 19/19 stages, 0/999,424 output mismatches, 0/18,432 coefficient mismatches, output hash: `1D23542E5CA3FA6AD4A57EACF54D8547DDDF98D941A11FDC03F431CB8DB85A7E`.

## Phase 1 — Category Timing Breakdown (SM8550 Median Run: 11,775,365 ticks = 613.30 ms)

| Category / Operation | Ticks (19.2 MHz) | Time (ms) | % DSP Region | Notes |
|---|---:|---:|---:|---|
| **HMX Output Copy (VTCM $\to$ DDR)** | 2,838,338 | 147.83 | 24.1% | 558 blocking memcpy transfers |
| **Snake Activation (HVX integer)** | 2,730,355 | 142.21 | 23.2% | 18 full-group passes (36 MB total) |
| **Residual (HVX Add + DDR Skip Copy)** | 1,935,555 | 100.81 | 16.4% | 9 HVX additions + 18 DDR-DDR copies |
| **Halo & Input Staging (DDR $\to$ VTCM)**| 1,688,886 | 87.96 | 14.3% | 558 blocking memcpy transfers + halo zeroing |
| **AdaIN Affine Pass (HVX integer)** | 1,445,360 | 75.28 | 12.3% | 18 full-group passes |
| **AdaIN Statistics (HVX moments)** | 712,907 | 37.13 | 6.1% | 18 full-group sum & sq-sum passes |
| **Three-Branch Mean Body** | 125,014 | 6.51 | 1.1% | 1 native-layout 3-way average pass |
| **Weight Copy (DDR $\to$ VTCM)** | 55,490 | 2.89 | 0.5% | Scales linearly with kernel size |
| **AdaIN Coefficient Generation** | 47,270 | 2.46 | 0.4% | Exact trial-bit integer sqrt & division |
| **HMX Convolution Arithmetic** | 38,993 | 2.03 | 0.3% | Raw HMX matrix multiply (5.89 TMAC/s) |
| **Parameter Copy (DDR $\to$ VTCM)** | 4,084 | 0.21 | <0.1% | 18 records of 8 KB |
| **Unexplained Remainder** | 152,708 | 7.95 | 1.3% | Odd-byte row masking, input copy, barriers |
| **Total DSP Region** | **11,775,365** | **613.30** | **100.0%** | Reconciled to outer timer |

## Host-Side Control Timing

- **Host Invoke Wall Time**: 638.51 ms
- **DSP Region Time**: 613.30 ms
- **Host Delta**: **25.21 ms** (FastRPC dispatch & resource acquisition overhead)

## Static Traversal & Staging Metrics

- **Total bytes copied DDR $\to$ VTCM**: 47,038,480 bytes (~44.86 MB)
- **Total bytes copied VTCM $\to$ DDR**: 35,979,264 bytes (~34.31 MB)
- **Total DDR $\leftrightarrow$ VTCM traffic**: 83,017,744 bytes (~79.17 MB)
- **Total DDR $\to$ DDR copies**: 41,994,240 bytes (~40.05 MB)
- **Total `memcpy` calls**: 1,177 calls
- **Total `syncht` operations**: 613 barriers
- **Complete 7,801-frame tensor passes**: 82 passes
- **AdaIN coefficient evaluations**: 2,304 (128 channels $\times$ 18 stages)
- **HMX tile batches**: 558 batches (540 batches $\times$ 8 tiles, 18 batches $\times$ 4 tiles)

## Phase 2 — Counterfactual Ablations (SM8550)

| Experiment | Emitted SHA-256 | DSP Region (ms) | Delta vs Baseline | Finding |
|---|---|---:|---:|---|
| **Baseline (Instrumented)** | `761A3512...` | 648.27 | 0.00 | Full execution |
| **Ablation A (`-BypassAdaInCoefficients`)** | `BE82DF39...` | 645.69 | -2.58 ms | Sqrt/div bit search is NOT a bottleneck (0.4%) |
| **Ablation B (`-BypassStatisticsAndCoefficients`)** | `7D2D34EA...` | 569.58 | -78.69 ms | Moments pass accounts for ~78 ms |
| **Ablation C (`-BypassHmxCompute`)** | `1F34E9C0...` | 455.73 | -195.12 ms | HMX conv + DDR $\leftrightarrow$ VTCM staging is ~195 ms |

## Key Findings

1. **HMX Compute is negligible**: The actual HMX matrix multiplication takes only **2.03 ms** across all 18 convolutions.
2. **AdaIN exact sqrt/division is negligible**: `body_coeff` takes only **2.46 ms** (0.4%). Replacing it is completely unnecessary at this stage.
3. **Memory traffic and staging dominate**: Blocking DDR $\leftrightarrow$ VTCM copies account for **235.79 ms (38.4%)**.
4. **HVX activation traversals dominate compute**: Snake, Residual, and Affine account for **318.30 ms (51.9%)**, driven by traversing 2 MB DDR tensors 82 times.
