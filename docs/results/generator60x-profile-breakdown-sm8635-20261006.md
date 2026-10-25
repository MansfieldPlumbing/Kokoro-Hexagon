# Generator60x Performance Attribution Breakdown — SM8635 (2026-10-06)

Diagnostic performance-attribution experiment on the verified 19-stage `Generator60x` worker (K3, K7, K11 residual branches + 3-branch mean, 7,801 frames / 244 tiles) on Motorola Razr+ 2024 (`ro.soc.model = SM8635`).

- **ELF (PROFILE-ONLY)**: `761A351219A3EEE1AA6929B6F4FD62CE6378F78A813806131FEFA43CDF9E0C54`
- **Output SHA-256**: `1D23542E5CA3FA6AD4A57EACF54D8547DDDF98D941A11FDC03F431CB8DB85A7E`
- **Correctness (3/3 runs)**: 19/19 stages, 0/999,424 output mismatches, 0/18,432 coefficient mismatches.

---

## Device Execution Runs (SM8635)

| Run | Region Ticks (19.2 MHz) | DSP Region Time (ms) | Host Invoke Time (ms) | Host Delta (ms) | Output Matches | Coefficient Matches |
|:---:|---:|---:|---:|---:|:---:|:---:|
| Run 0 | 10,765,778 | 560.72 | 585.86 | 25.14 | 999,424 / 999,424 | 18,432 / 18,432 |
| Run 1 | 9,908,926 | 516.09 | 543.37 | 27.28 | 999,424 / 999,424 | 18,432 / 18,432 |
| Run 2 (Median) | 10,391,666 | 541.23 | 571.25 | 30.01 | 999,424 / 999,424 | 18,432 / 18,432 |

- **Median DSP Region**: **10,391,666 ticks = 541.23 ms** (29.8 GMAC/s).
- **Median Host Invoke**: **571.25 ms** (FastRPC overhead: ~30 ms).

---

## Category Timing Breakdown (SM8635 Median Run: 10,391,666 ticks = 541.23 ms)

| Category / Operation | Ticks (19.2 MHz) | Time (ms) | % DSP Region | Notes |
|---|---:|---:|---:|---|
| **HMX Output Copy (VTCM $\to$ DDR)** | 2,838,457 | 147.84 | 27.3% | 558 blocking memcpy transfers |
| **Snake Activation (HVX integer)** | 2,264,244 | 117.93 | 21.8% | 18 full-group passes (36 MB total) |
| **Halo & Input Staging (DDR $\to$ VTCM)**| 1,562,745 | 81.39 | 15.0% | 558 blocking memcpy transfers + halo zeroing |
| **Residual (HVX Add + DDR Skip Copy)** | 1,399,721 | 72.90 | 13.5% | 9 HVX additions + 18 DDR-DDR copies |
| **AdaIN Affine Pass (HVX integer)** | 1,295,007 | 67.45 | 12.5% | 18 full-group passes |
| **AdaIN Statistics (HVX moments)** | 663,116 | 34.54 | 6.4% | 18 full-group sum & sq-sum passes |
| **Three-Branch Mean Body** | 91,294 | 4.75 | 0.9% | 1 native-layout 3-way average pass |
| **HMX Convolution Arithmetic** | 73,589 | 3.83 | 0.7% | Raw HMX matrix multiply |
| **AdaIN Coefficient Generation** | 46,771 | 2.44 | 0.4% | Exact trial-bit integer sqrt & division |
| **Weight Copy (DDR $\to$ VTCM)** | 38,238 | 1.99 | 0.4% | Scales with kernel size |
| **Parameter Copy (DDR $\to$ VTCM)** | 3,108 | 0.16 | <0.1% | 18 records of 8 KB |
| **Final Coefficient Copy** | 432 | 0.02 | <0.1% | Staging for next group |
| **Unexplained Remainder** | 114,944 | 5.99 | 1.1% | Loop setup, row masks, barriers |
| **Total DSP Region** | **10,391,666** | **541.23** | **100.0%** | Reconciles to outer timer |

---

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

---

## Comparison: SM8550 vs SM8635 (Median Runs)

| Category | SM8550 ms | SM8550 % | SM8635 ms | SM8635 % | SM8635 vs SM8550 Delta |
|---|---:|---:|---:|---:|---:|
| **HMX Output Copies (VTCM $\to$ DDR)** | 147.83 | 24.1% | 147.84 | 27.3% | +0.01 ms |
| **Snake (HVX integer)** | 142.21 | 23.2% | 117.93 | 21.8% | -24.28 ms |
| **Halo & Input Staging (DDR $\to$ VTCM)**| 87.96 | 14.3% | 81.39 | 15.0% | -6.57 ms |
| **Residual (HVX Add + DDR Copies)** | 100.81 | 16.4% | 72.90 | 13.5% | -27.91 ms |
| **AdaIN Affine Pass (HVX)** | 75.28 | 12.3% | 67.45 | 12.5% | -7.83 ms |
| **AdaIN Statistics (HVX moments)** | 37.13 | 6.1% | 34.54 | 6.4% | -2.59 ms |
| **Three-Branch Mean** | 6.51 | 1.1% | 4.75 | 0.9% | -1.76 ms |
| **HMX Convolution Arithmetic** | 2.03 | 0.3% | 3.83 | 0.7% | +1.80 ms |
| **AdaIN Coefficient Generation** | 2.46 | 0.4% | 2.44 | 0.4% | -0.02 ms |
| **Weight Copy (DDR $\to$ VTCM)** | 2.89 | 0.5% | 1.99 | 0.4% | -0.90 ms |
| **Parameter Copy (DDR $\to$ VTCM)** | 0.21 | <0.1% | 0.16 | <0.1% | -0.05 ms |
| **Remainder** | 7.95 | 1.3% | 5.99 | 1.1% | -1.96 ms |
| **Total DSP Region** | **613.30** | **100.0%** | **541.23** | **100.0%** | **-72.07 ms (-11.8%)** |

Key architectural insights confirmed across both platforms:
1. **Raw HMX arithmetic is < 1% of time** (2.03 ms on SM8550, 3.83 ms on SM8635).
2. **AdaIN square-root & division bit-search is < 0.5% of time** (2.46 ms on SM8550, 2.44 ms on SM8635).
3. **Blocking memory transfers between DDR and VTCM consume ~40% of time** (~230–236 ms).
4. **82 independent full-tensor passes over DDR consume ~54–58% of time** (~293–355 ms).
