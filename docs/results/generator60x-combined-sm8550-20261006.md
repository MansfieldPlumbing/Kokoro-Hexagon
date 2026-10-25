# Combined Generator 60x residual stages on SM8550 — 2026-10-06

Baseline commit `08b8df2b4049ddc941c4b2a847b99d0ac60d7e65`.
Stock Kokoro source: `dfb907a02bba8152ca444717ca5d78747ccb4bec`, `kokoro/istftnet.py`
checkpoint SHA-256: `496DBA118D1A58F5F3DB2EFC88DBDC216E0483FC89FE6E47EE1F2C53F18AD1E4`.

One PowerShell-emitted DSP proof job composes all three 128-channel generator residual
branches (`resblocks.3`, `resblocks.4`, and `resblocks.5`, kernel sizes 3, 7, 11) and the
native-layout three-branch average into a single connected DSP execution.
The execution covers 19 stages: 18 live convolution/AdaIN/Snake stages across the three
branches plus the final branch average, processing 7,801 frames (244 native tiles)
without host round-trips.

Emitted ELF SHA-256: `3DA827414366BC38B0DB061FDC730F2F337D5F8266F70B918B684B93D9733D31`.
Reproduced byte for byte from committed source `03be78359af2b17da5b1203527dd7d86cee6d8e4`.

## SM8550 Device Verification (3/3 exact)

Executed on the attached SM8550 device using the existing debuggable host probe
`Invoke-ResBlockRunProbe.ps1 -Graph Generator60x`.

| Run | Invoke status | Power / Lock status | Completed stages | Output mismatches | Coefficient mismatches | Region ticks (19.2 MHz) | Region ms | Invoke wall ms |
|---|---|---|---:|---:|---:|---:|---:|---:|
| 0 | 0 | 0 / 0 / 0 | 19 | 0 / 999,424 | 0 / 18,432 | 12,847,729 | 669.153 | 692.443 |
| 1 | 0 | 0 / 0 / 0 | 19 | 0 / 999,424 | 0 / 18,432 | 11,485,794 | 598.218 | 623.067 |
| 2 | 0 | 0 / 0 / 0 | 19 | 0 / 999,424 | 0 / 18,432 | 12,266,574 | 638.884 | 666.438 |

- **Median DSP Region**: 12,266,574 ticks = 638.884 ms (25.2 GMAC/s diagnostic connected rate).
- **Median Invoke Wall Time**: 666.438 ms.
- **VTCM granted**: 524,288 bytes.
- **Output hash**: `1D23542E5CA3FA6AD4A57EACF54D8547DDDF98D941A11FDC03F431CB8DB85A7E`.
- **Coefficient hash**: `7790A70339453CBCC3A2E704F51B6DE16F6E251E58F0370CDF5300ACCD99D8E6`.
- **Output tensor equality**: Byte-identical to the full V73 simulation output tensor across all 1,998,848 bytes.
- **Numerical comparison vs stock FP32**: 22.665159 dB SNR, RMSE 0.3973752604, maximum absolute error 3.777032830.
- **Startup restoration**: Verified by SHA-256 match on `files/Start.ps1` and `files/PROFILE.PS1`.

## Scope and Boundary

This is a connected generator-stage correctness and diagnostic measurement across
the three 128-channel residual branches and branch average. It is **not** a whole-generator
RTF or whole-model TTFA measurement. Staging utilizes synchronous shared DDR buffers
and blocking copies for diagnostic capture. The next connected boundary joins the
final LeakyReLU, 22-channel `conv_post`, magnitude/phase nonlinearities, and 20-point iSTFT.
