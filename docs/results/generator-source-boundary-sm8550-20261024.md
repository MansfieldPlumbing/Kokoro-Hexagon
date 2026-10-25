# Generator source insertion points: fitted replacement measured and rejected (SM8550)

Kokoro-Hexagon `da1b1db`. Cases `generator-source-boundary` (receipt `build/generator-source-boundary-20261024T053701`)
and `generator-tile-equivalence -Joint Whole -SourceStreams Zero|Model|LayerOutput`.

## Question

Whether the source branches (`noise_convs`, `noise_res`; about 7.4 G multiply-accumulates per audio second) could be
replaced by a model of the add's result Y on the upsampled signal U, with no convolution weight tensors.

## Method

- **Capture:** the layer decoder-and-generator job exports, at both fronts, U, the source N and the add's result Y. It
  ran on three utterances: hello, timing-passage-0 and speak.
- **Models:**
  - M0: Y = U.
  - M1: per-channel gain and offset on U.
  - M2: M1 plus a 5-tap temporal filter.
- **Folds:** each model is fitted on two utterances and frozen for the third.
- **PCM test:** the frozen fit that holds out hello is injected after the add in the depth-first whole job
  (`-SuppliedSectionInputs`). With both sections modelled, a first pass gives section 1 its own U from the fitted
  section 0. PCM is compared with the layer job on the generator-whole fixture.

## Result

**Boundary.** Held-out SNR of Y; "mean removed" is Y with each channel's mean subtracted:

| Section | M1 | M1, mean removed | M2 gain over M1 |
| --- | ---: | ---: | ---: |
| 256-channel | 21.4 to 22.1 dB | 19.8 to 20.4 dB | at most 0.3 dB |
| 128-channel | 28.9 to 29.1 dB | 20.3 to 20.8 dB | at most 0.0 dB |

**Parts of the add.** These are scaled by the add's Q14 ratios:

| Section | Source part power, relative to U's | Parts over Y power | Median U-N correlation |
| --- | ---: | ---: | ---: |
| 256-channel | 0.18 | 0.94 | 0.07 |
| 128-channel | 3.3 | 0.84 | 0.39 |

No Y values saturate.

**PCM** against the layer job:

| Run | PCM SNR | Level error | Level-matched SNR |
| --- | ---: | ---: | ---: |
| No source | -15.67 dB | +15.56 dB | 0 dB |
| 256-channel section modelled (M1) | 0.53 dB | -0.32 dB | 1.51 dB |
| 128-channel section modelled (M1) | 0.04 dB | -11.08 dB | 0.11 dB |
| Both, connected (M1) | -0.09 dB | -11.06 dB | 0.05 dB |
| Control: the layer job's own Y injected | identical | 0 dB | identical |

The add's inversion (supplying the source N^ that yields Y^) realizes Y^ to 66.2 dB in the 256-channel section and only
30.9 dB in the 128-channel section. It is kept only as a diagnostic.

## Conclusion

The injection path reproduces the reference exactly (the control), so the failure is the model's. About 20 dB of
waveform fidelity at the boundary gives no PCM fidelity. The source branches stay, computed on the DSP
(`generator-source-on-dsp-sm8550-20261024.md`).

Limits of the evidence: three utterances, one noise draw each.
