# Where the DSP ALBERT job loses accuracy (SM8550 and host)

Kokoro-Hexagon `fbb537b`. Phone: `AlbertJob` (`Test-KokoroAlbertJob`, emitter kernel `KokoroAlbert16Run`), test capture
`stock-albert-capture-hello` (16 tokens), every LSB planned from the calibration captures bench1-3 and howareyou,
W8 weights (one plane), 16-bit activations. Host: the same stock captures, with the job's planning rule (calibration
peak times 1.25 over 32,767) and its weight format (symmetric, one step per output channel, largest weight over 127)
applied in float64.

## Phone

Whole job: `d_en` 25.72 dB against stock, 12.99 ms (one run, as `albert-connected-sm8550-20261009.md`). Stream after
`mapping_in` and after repeats 0 to 11: 46.13, 36.90, 26.98, 24.43, 24.01, 25.03, 26.38, 25.53, 26.63, 26.76, 27.53,
27.12, 27.58 dB.

Each operator of repeats 0 and 1, the job stopped after it (`-StopAfter`, one run each), against stock (sums where the job
adds into the stream):

| Operator | Repeat 0 | Repeat 1 |
| --- | ---: | ---: |
| query | 43.81 | 36.47 |
| key | 44.33 | 30.72 |
| value | 42.04 | 35.67 |
| attention | 38.26 | 23.01 |
| dense (sum into the stream) | 40.01 | 26.63 |
| LayerNorm after attention | 40.99 | 29.07 |
| ffn | 39.99 | 30.75 |
| gelu_new | 38.79 | 28.31 |
| ffn_output (sum into the stream) | 45.45 | 34.27 |
| LayerNorm after ffn | 36.90 | 26.98 |

## Host

**Storage is not the limit.** Stock tensors held at the job's planned LSBs, with stock arithmetic otherwise:

| Check | SNR |
| --- | ---: |
| Repeat 0's last LayerNorm, input held at its one LSB (6.2e-3) | 58.19 dB |
| The same, one LSB per channel | 89.71 dB |
| query, key, value of repeat 1 from the stream held at its LSB (1.9e-3) | 62.66, 73.72, 62.20 dB |

**The LayerNorm amplifies an error that is small against the outlier channels.** Its input after repeat 0 has a few
large channels (channel 504 peaks at 162.9 in calibration) that it weights lightly (gain 0.53 against a median of 1.85).
White noise at 45.45, 50 and 55 dB on that input gives 36.67, 41.17 and 46.08 dB at its output; the phone measured
45.45 dB in and 36.90 dB out.

**The weights are the limit.** Repeat 0's ffn and ffn_output alone, everything else exact: W8 gives 48.19 dB at the sum
and 40.05 dB after the LayerNorm; W16 gives 95.06 and 88.13 dB.

**Corrections to W8, on repeat 1's key with exact inputs** (held out: statistics from the calibration captures,
scored on the test capture):

| Weights | SNR |
| --- | ---: |
| W8 | 49.14 dB |
| W8, bias corrected by the rounding error times the calibration input mean | 50.10 dB |
| W8 with a rank-1 correction u(vᵀx), the error's leading direction under the calibration inputs | 50.07 dB |
| W8 after input-column equalization by rms^α (α 0.25, 0.5, 0.75) | 43.95, 37.87, 31.49 dB |
| W8 with the step clipped to 0.9 or 0.8 of the largest weight | 21.17, 15.13 dB |
| W8 with the 1, 2, 4, 8 or 16 input columns of largest calibration peak kept exact | 53.07, 53.75, 54.63, 56.08, 56.45 dB |

## Observations

- Repeat 1's key reaches 49 dB from exact inputs but 30.72 dB on the phone: most of repeat 1's loss is repeat 0's error
  carried through the linears, then sharpened by the attention.
- Offline changes to W8 alone (bias correction, a rank-1 correction, equalization, clipping) recover at most 1 dB here;
  equalization and clipping lose.
- Keeping the outlier input columns at higher precision recovers 4 to 7 dB; 16-bit weights recover about 40 dB.

## Not yet done

- The accuracy ALBERT's output needs, from the predictor's durations, F0 and N with error added at known levels.
- 16-bit weights (two planes) on the phone, and the job beyond one 32-token tile.
- A check of the phone's LayerNorm on its own input.
