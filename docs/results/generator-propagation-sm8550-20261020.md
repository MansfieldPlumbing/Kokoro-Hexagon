# Propagation of generator input error to PCM, SM8550, 2026-10-20

Kokoro-Hexagon `34d61b2`, `Invoke-KokoroDevelopment.ps1 Run -Case generator-propagation`.

## Method

Input: the accepted peach generator input with exact constants
(`build/generator-constants-full-corpus-20261012-143702/A/generator-exact-constants`), 2.125 s, 170 ticks,
51,000 samples. Generator: `KokoroGeneratorWholeSource16Run` with `GeneratorMoments = Constants`, library SHA-256
`97FD245178351F91A9FD96B0DC6DC8DFDD87DE76BB4EA14CF698CBC63F840408`. The unperturbed run reproduced the accepted
PCM (`E6456751BDBCCE0D5CB38DA8226B4EEC8B1C514E16626755C5BD975699374054`) before any perturbation.

Gaussian noise, seed 17, at a requested level r = 10^(-dB/20):

- X: each decoder-output channel, noise RMS r times the channel's RMS over the utterance, requantized to the stored
  16-bit format. Three stored values at -32768 re-encode as -32767 (encoder clamp); no other value changes.
- F0: each voiced tick's f0 multiplied by (1 + r g), independent per tick.
- F0Offset: each voiced tick's f0 multiplied by (1 + r), a constant relative offset.
- AdaIn: at all 48 sites and every channel, the constant 1/std scaled by (1 + r g1) and the mean shifted by
  r g2 std, independent per channel.

Boundary SNR is measured after requantization. PCM SNR is against the unperturbed run (propagation alone); stock
SNR is against stock PCM of the same sentence.

## Result

| Input | Boundary SNR (dB) | PCM SNR vs unperturbed (dB) | PCM SNR vs stock (dB) |
| --- | ---: | ---: | ---: |
| None | | | 31.29 |
| X | 20.01 | 18.06 | 17.79 |
| X | 30.03 | 29.86 | 26.26 |
| X | 39.97 | 38.60 | 30.74 |
| X | 50.00 | 44.53 | 31.16 |
| X | 59.98 | 47.48 | 31.15 |
| F0 | 20.33 | -2.98 | -2.96 |
| F0 | 30.03 | -1.89 | -1.88 |
| F0 | 39.97 | 2.99 | 2.98 |
| F0 | 49.91 | 15.43 | 15.36 |
| F0 | 61.60 | 12.43 | 12.29 |
| F0Offset | 20.00 | -2.65 | -2.64 |
| F0Offset | 30.00 | -2.22 | -2.20 |
| F0Offset | 40.00 | -3.34 | -3.32 |
| F0Offset | 50.00 | -1.32 | -1.31 |
| F0Offset | 60.00 | 1.99 | 2.00 |
| AdaIn | 19.94 | 7.39 | 7.44 |
| AdaIn | 29.96 | 15.50 | 15.74 |
| AdaIn | 39.96 | 25.35 | 25.26 |
| AdaIn | 49.95 | 31.03 | 27.92 |
| AdaIn | 59.97 | 39.74 | 31.54 |

DSP time per run: 87.2 to 89.3 ms. Receipt: `build/propagation-sm8550-20261020T153740/propagation.clixml`.

## Observations

- X error passes to PCM nearly one for one up to 40 dB and saturates near 47 dB: below that level the generator's
  own requantization sets the difference from the unperturbed run.
- AdaIN error is amplified by 14 to 20 dB through the 48 sites. 40 dB PCM requires about 60 dB in the supplied
  scale and mean under independent per-channel error. Structured (low-rank) error has not been measured.
- Waveform SNR does not tolerate pitch error: a 0.1% constant f0 offset leaves 2 dB, because phase integrates f0
  over the utterance. Pitch is scored separately from waveform SNR, and the waveform comparison uses the same phase
  trajectory on both sides.
- The unperturbed run is 31.29 dB against stock; its decoder output comes from the DSP decoder.

Single seed and a single utterance; repeated draws and further utterances have not been run.
