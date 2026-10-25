# Generator PCM with requantized resblock weights, SM8550, 2026-10-20

Kokoro-Hexagon `cddfd18`, `Invoke-KokoroDevelopment.ps1 Run -Case generator-weight-precision`.

## Method

Input: the accepted peach generator input with exact constants
(`build/generator-constants-full-corpus-20261012-143702/A/generator-exact-constants`), 2.125 s. Generator:
`KokoroGeneratorWholeSource16Run`, `GeneratorMoments = Constants`, library SHA-256
`97FD245178351F91A9FD96B0DC6DC8DFDD87DE76BB4EA14CF698CBC63F840408` (unchanged by recording weight regions in its layout).
The unmodified run reproduced the accepted PCM.

The resblock weights (`resblocks.0-5`; 10,321,920 of the generator's 17,260,553 weights: 8,257,536 in stage 0 at 256
channels, 2,064,384 in stage 1 at 128 channels) are stored as 16-bit values per output channel. Each output channel was
requantized by plain rounding to symmetric n-bit levels: 2^(n-1) - 1 steps of max|w| / (2^(n-1) - 1). Each channel's group 0
and group 1 table biases were corrected for the change in its high and low plane row sums, so every convolution is exact
for its new weights. No error feedback, clipping search, grouped scales or compensation was applied. `ups`, `conv_post`
and the source branch were not changed.

Weight SNR is over the requantized weights in 16-bit units. PCM SNR is against the unmodified run; stock SNR is against
stock PCM.

## Result

| Bits | Resblocks | Weight SNR (dB) | PCM SNR (dB) | Stock SNR (dB) |
| ---: | --- | ---: | ---: | ---: |
| 16 | none | | | 31.29 |
| 8 | stage 0 | 40.73 | 32.96 | 30.79 |
| 8 | stage 1 | 39.89 | 34.91 | 29.68 |
| 8 | both | 40.57 | 30.85 | 29.32 |
| 6 | stage 0 | 28.49 | 21.75 | 22.24 |
| 6 | stage 1 | 27.63 | 25.31 | 24.70 |
| 6 | both | 28.33 | 19.87 | 20.30 |
| 5 | stage 0 | 22.18 | 18.81 | 18.81 |
| 5 | stage 1 | 21.34 | 18.68 | 18.57 |
| 5 | both | 22.02 | 16.67 | 16.73 |
| 4 | stage 0 | 15.56 | 9.55 | 9.51 |
| 4 | stage 1 | 14.73 | 11.11 | 11.06 |
| 4 | both | 15.41 | 8.67 | 8.64 |

DSP time per run: 87.1 to 89.5 ms. Receipt: `build/weight-precision-sm8550-20261020T215634/precision.clixml`.

## Observations

- With plain per-channel rounding, PCM SNR is 5 to 10 dB below weight SNR, and weight SNR falls about 6 dB per bit.
  At that rate, 40 dB PCM through weight error alone requires roughly 46 dB weight SNR, more than per-channel int8 gives.
- Maximum-scaled rounding wastes range: int8 reaches only 40.6 dB weight SNR. Clipping search, smaller scale groups,
  error diffusion along each row and output-aware compensation have not been measured.
- Stage 1 (2.1 M weights) costs within 2 to 4 dB of stage 0 (8.3 M weights) at every precision: per weight, stage 1 is
  far more sensitive.
