# Generator AdaIN normalization across streams, SM8550

Kokoro-Hexagon `d73f7be`, `Invoke-KokoroDevelopment.ps1 Run -Case generator-normalization` (Student
`-Step Normalization` with the speech renderer). The Student does not run: the inputs are the syllabus's own x and f0.

## Method

- Streams: 130-tick stretches (1.625 s) from the middle of the first ten syllabus windows of at least 130 ticks,
  `af_heart`. Eight are fitted; two are held out.
- Each stream's exact generator AdaIN moments are exported on the phone by the layer job (`Constants`), for all 48
  sites (9,216 channels).
- Fit, per site, over the eight fitted streams: `ln(1/std)` and the mean in std units of each channel and stream as a
  channel profile (its mean over streams) plus one level per stream (the stream's mean over channels less the
  profile's). LevelShare is the part of the across-stream variation that the level explains.
- Each held-out stream is rendered with the source-complete depth-first generator (int8, one weight plane, seeded
  noise, seed 1) with the same x, f0, seed and weights, under:
  - Matched: its own exported moments.
  - Voice base: the mean of the eight fitted streams' moments (`VoiceBase`).
  - Profile and level: the fitted profile with the held-out stream's own level per site (an oracle level: it is taken
    from the finished stream).
  - Controls: the matched input rendered again, and rendered on the other job path (resident listener or one-shot
    relaunch).

## Result

| Held-out | Condition | RMS | PCM SNR against matched | Largest site gain error | PCM SHA-256 prefix |
| --- | --- | ---: | ---: | ---: | --- |
| 0 | Matched (resident) | 0.02 | | 0 dB | `CDF967AED2514568` |
| 0 | Repeat (resident) | 0.02 | equal | 0 dB | `CDF967AED2514568` |
| 0 | One-shot | 0.02 | equal | 0 dB | `CDF967AED2514568` |
| 0 | Voice base | 0.04 | -3.11 dB | 4.08 dB | `BB0DC7824579B3A0` |
| 0 | Profile and level | 0.02 | -1.40 dB | 3.97 dB | `6C295C4B0028CE6E` |
| 1 | Matched (resident) | 0.04 | | 0 dB | `A2D630D147754C86` |
| 1 | Repeat (resident) | 0.04 | equal | 0 dB | `A2D630D147754C86` |
| 1 | One-shot | 0.04 | equal | 0 dB | `A2D630D147754C86` |
| 1 | Voice base | 0.04 | 2.78 dB | 5.68 dB | `F646B3CACF2068F5` |
| 1 | Profile and level | 0.03 | 0.59 dB | 5.43 dB | `35061FE13F8AFF45` |

Site gain error is 20 log10 of the condition's 1/std over the matched 1/std, per channel. DSP time per render 63.6 to
65.5 ms. The same hashes and figures were produced by an earlier session with one-shot renders.

Fit over the eight streams, per site:

| | Mean | Minimum | Maximum |
| --- | ---: | ---: | ---: |
| Across-stream std variation (RMS, dB) | 0.58 | 0.33 | 0.96 |
| LevelShare of `ln(1/std)` | 0.11 | 0.01 | 0.49 |
| LevelShare of the mean in std units | 0.02 | 0.00 | 0.06 |

The largest LevelShare (0.49) is at stage 0 of `resblocks.3`, `.4` and `.5`, which read the same section input; the
256-channel section's stage-0 sites follow at 0.26.

## Observations

- **Renders are deterministic.** The repeat equals the matched render byte for byte on both streams, and the resident
  and one-shot paths give the same PCM.
- **On syllabus x the normalization is nearly fixed per channel.** Each channel's std moves by 0.33 to 0.96 dB RMS
  between streams, and the voice base is within 4.1 to 5.7 dB at the worst channel of any site.
- **The voice base does not remove the output level on syllabus x.** The loss of level recorded in
  `student-stage1-audition-sm8550-20261025.md` was for x far from the syllabus.
- **A per-site level explains little of the remaining variation** (11% on average for `ln(1/std)`, 2% for the mean)
  and does not bring the largest channel errors down: the largest errors are per-channel.
- **Waveform SNR does not separate these conditions.** Renders within about 1 dB per channel of the matched
  normalization reach -3.1 to 2.8 dB PCM SNR against it, with deterministic renders. Comparisons of normalization
  variants need a spectral measure as well.
- **The fitted mean level enlarges some source-branch offsets.** At `noise_res.1.stage4` the mean offset grows from
  0.21 std (voice base) to 0.39 std (profile and level) on held-out 0.

## Execution

- Constants exports are cached by the hash of their inputs (`build/generator-constants`); the int8 weight conversion
  is cached once per weights file and layout (`build/generator-int8`): 559.7 s cold, 0.86 s cached, tables, weights
  and 36,864 correction pairs byte-identical to the cold conversion.
- Renders run on the resident listener: 5 to 8 s per warm render, about 30 s per one-shot relaunch; the first
  resident job after a one-shot job starts a new listener (about 35 s).

## Gain and offset levels separated

Same streams, renderer and seed; resident renders. Each profiled condition starts from the fitted profile (equal to
the voice base) and adds the held-out stream's own per-site level to the gain term (`ln(1/std)`), the offset term (the
mean in std units) or both, at all sites or only at the source-branch (`noise_res`) or `resblocks` sites. The
harmonic-to-noise ratio is measured over voiced ticks from the energy projected onto the first ten harmonics of each
tick's f0; over one tick the harmonics are not exactly orthogonal, so it compares renders of the same x and f0 and is
not an absolute value.

| Condition | Held-out 0 RMS | Held-out 0 HNR change | Held-out 1 RMS | Held-out 1 HNR change |
| --- | ---: | ---: | ---: | ---: |
| Matched (6.59 dB; 7.51 dB) | 0.02 | 0 | 0.04 | 0 |
| Voice base | 0.04 | +1.39 dB | 0.04 | -2.34 dB |
| Profile, gain and offset levels | 0.02 | +0.44 dB | 0.03 | +0.22 dB |
| Profile, gain level | 0.02 | -1.17 dB | 0.01 | -2.96 dB |
| Profile, offset level | 0.04 | +1.72 dB | 0.03 | -2.98 dB |
| Profile, offset level at `noise_res` | 0.04 | +1.41 dB | 0.04 | -2.41 dB |
| Profile, offset level at `resblocks` | 0.03 | +1.79 dB | 0.03 | -2.90 dB |

HNR change is against the stream's matched render. The matched, repeat, voice-base and both-levels renders reproduce
the PCM hashes above. Receipt: `build/generator-normalization-session/run-20261026T121839/normalization.clixml`.

- **The offset level at the source-branch sites leaves the render close to the voice base** (+1.41 against +1.39 dB;
  -2.41 against -2.34 dB).
- **The gain level moves both streams the same way.** Against the voice base it lowers RMS (0.04 to 0.02; 0.04 to
  0.01) and the harmonic-to-noise ratio (by 2.56 dB; by 0.62 dB).
- **The offset level's effect on the harmonic-to-noise ratio changes sign between the streams** (+1.72 dB; -2.98 dB).

## Not yet done

- A stream-independent gain control: one uniform offset to `ln(1/std)` at every site, swept, with RMS and the
  harmonic-to-noise ratio measured at each setting.
- The same comparison on decoder-produced x (the Student's controls through the DSP decoder).
- A spectral comparison of the normalization variants.

Receipt: `build/generator-normalization-session/run-20261026T120330/normalization.clixml`, with the WAVs beside it.
