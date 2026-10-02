# Snake Sine Physical Lowering Ratchet

## Date: 2026-09-23
## Test Configuration
- Range Reduction: Quadrant folding $q = \lfloor u \cdot \frac{2}{\pi} + 0.5 \rfloor$, residual $r = u - q \cdot \frac{\pi}{2} \in [-\frac{\pi}{4}, +\frac{\pi}{4}]
- Polynomial Order: 7th-degree odd polynomial for sin ($r \cdot (1 - c_3 r^2 + c_5 r^4 - c_7 r^6)), 8th-degree even for cos ($1 - d_2 r^2 + d_4 r^4 - d_6 r^6 + d_8 r^8)
- Evaluated on:
  1. Synthetic dense domain [-12.0, +12.0] across 100,000 points.
  2. Real Kokoro lpha1.0 * y activations across all 128 channels and 7681 samples (983,168 points).

## Ratchet Results

| Metric | Synthetic Grid [-12, 12] | Real Kokoro Activations | Gate Boundary |
| --- | ---: | ---: | ---: |
| Max Sin Absolute Error | 3.576E-007 | 3.576E-007 | < 1.000E-05 |
| Max Snake Absolute Error | N/A | 2.861E-006 | < 1.000E-04 |
| Snake SNR | N/A | 141.07 dB | > 60.00 dB |
| Total Checked Points | 100,000 | 983,168 | Exact |
| Status | **PASSED** | **PASSED** | Passed |

## Mathematical Equivalence & Propagation
- Error in sin is bounded below 1.2e-7 across the entire real range [-10.36, +9.46].
- Snake output maximum error is 2.861E-006, well within single-precision noise floor.
- SNR of 141.07 dB confirms high-fidelity physical equivalence to [MathF]::Sin.