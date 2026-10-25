# 16-bit generator 60x stage: holdout calibration and the low x low group, SM8550 — 2026-10-08

Stage as `generator60x-16bit-sm8550-20261008.md` (resblocks.3-5 and mean, 7,801 frames, hello-world sentence,
af_heart, seed 17), with three changes:

- Low x low group combined: its window sits at shift L + 8 and leaves HMX through its low plane only
  (`Kokoro.PlaneCombine.ps1 -Groups 3` sign-extends it). The fixture builder computes that window on every
  capture it reads (`Get-LowLowWindowKernel`) and fails above 127: peak 45 (in-sample), 59 (holdout).
- Every group's table bias now rounds to nearest (half a window LSB) instead of flooring.
- Phase turns in Q22 instead of Q24 (`Kokoro.AdaInSnakeTurns.ps1 -TurnsBits 22`): K gets 4x the int32 range at
  no instruction cost. Needed for the holdout: under Q24, resblocks.4 stage 0 channel 112 left 1.00-1.05x
  between the K bound and the residual peak on the long sentences, and calibration over two sentences failed.

Holdout: scales from `stock-generator-sentence-af_heart-20261007` (seed 41, 19,801 frames) and
`stock-generator-weight-calibration-20261007` (seed 29), both whole-generator captures read through
`Read-KokoroResBlockCapture`; the evaluated sentence contributes only its input, style and frame count.

Skel SHA-256 `3697161DAEE9A295D146616838AEB03833F1A3B734CB6D62D4F863B32FFB03E4`, instruction bytes match SDK
6.4.0.2 `hexagon-llvm-mc`. Holdout fixture `tables.bin` `EB8CA876DBC33455…`, `weights.bin` `D7E2624A10A8AEAF…`.

## Result (3 runs each, identical output, every HVX/HMX lock 0)

| Fixture | Branch 0 | Branch 1 | Final (mean) | Final max abs error | DSP region median |
| --- | ---: | ---: | ---: | ---: | ---: |
| Previous (two groups, floor, Q24, in-sample) | 64.95 dB | 62.85 dB | 66.68 dB | 0.036 | 29.40 ms |
| Three groups, rounded, Q24, in-sample | 68.42 dB | 67.24 dB | 69.93 dB | 0.036 | 30.03 ms |
| Three groups, rounded, Q22, in-sample | 68.43 dB | 67.13 dB | 69.88 dB | — | 30.04 ms |
| **Three groups, rounded, Q22, holdout** | **67.88 dB** | **65.73 dB** | **68.76 dB** | 0.032 | **29.84 ms** |

Branch 0 stage 0 K/M/S equal the integer formula on 128/128 channels in every run. Holdout workspace
SHA-256 `1D3543A639B5A79B…`.
