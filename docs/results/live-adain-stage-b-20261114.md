# Live AdaIN Stage B: per-token contributions do not compose a scope's moments better than the voice base (2026-11-14)

Branch `live-adain`, Kokoro-Hexagon `d7fb475` plus the `Observed` field this commit adds to the host port. Host only; no
phone. Stage B of `docs/fable-opus-brief-live-adain-20261113.md`, on the generator levels of
`live-adain-groundwork-20261114.md`. Receipt: `build/live-adain-stage-b-20261114/` (`PREDICTIONS-STAGE-B.md`, scripts,
CSVs, logs, renders, `manifest.csv` of SHA-256s; the 616 per-window level files, 10.7 GB, are kept beside it and not in
the manifest).

## Predictions

`PREDICTIONS-STAGE-B.md` was written at 08:57 while the capture ran, before any captured statistic was looked at; its
SHA-256 `1DDB5A423507457D87D1FB952B15E9400BE29D256A34DA00E5F68255274296B8` is unchanged. The question it states: do
per-token contributions add up to a scope's AdaIN moments, well enough that moments composed from other utterances'
contributions land closer to a held-out utterance's exact moments than the voice base does?

## Data and measure

Host port generator, float32, `af_heart`, each window at its own voice row, port seeds. 616 cached syllabus windows split
by book position (512-token blocks, mod 8: 7 held out, 6 development, otherwise training, with no shared token): 500
training, 57 development, 59 held out; all 48 generator sites, 9,216 channels. Per window and site the capture keeps the
exact whole-window mean and variance and each token's row count, sum and sum of squares per channel (float32).

Boundary SNR = 10 log10(2N / sum over channels [(inv'/inv - 1)^2 + ((mean' - mean) inv)^2]), inv = 1/sqrt(var + 1e-5),
over all 9,216 channels, the definition of `generator-adain-representation-sm8550-20261020.md`; mean over windows.

## Result against the predictions

Held out, 59 windows:

| Arm | Boundary SNR | Predicted | Outcome |
| --- | ---: | --- | --- |
| A0 voice base (training mean of ln inv and mean x inv) | 34.07 dB | 18 to 24 dB | wrong: 10 dB better than predicted |
| A1 the window's own token sums | 130.59 dB | above 80 dB | as predicted |
| A2 type bank | 29.73 dB | 2 to 5 dB above A0 | refuted: 4.3 dB below A0 |
| A3 context bank, MinCount 20 (chosen on development) | 28.58 dB | 0.5 to 2 dB above A2, below 30 dB | refuted: 1.2 dB below A2 |
| A2o oracle type means | (= A1) | more than 3 dB above A3 | ill-posed, see below |
| A6 breath groups against the whole window | 13.99 dB | 15 to 22 dB | below the range |
| A6 400-tick stretches against the whole window | 19.28 dB | 18 to 25 dB | in the range |

A2o is ill-posed: type means taken from the window itself, multiplied by the same window's rows per token, sum to the
window's own type totals, so the arm is A1 by construction. It was not run.

Development (57 windows) agrees: A0 34.15 dB, A2 30.27 dB, A3 (MinCount 2, 5, 20, 80) 29.08, 29.00, 29.20, 28.86 dB.
A2 beats A0 in 6 of 59 held-out windows and A3 in none. In the 42 held-out windows of at least 800 ticks: A0 35.46 dB,
A2 32.12 dB, A3 31.16 dB.

By section (held out): A0 34.19 / 33.90 / 34.20 / 34.72 dB (256-channel main, 256-channel source, 128-channel main,
128-channel source); A2 31.44 / 34.58 / 26.56 / 35.74 dB. The type bank loses most in the 128-channel main section.

**A5 fixed point** (8 held-out windows, the first 8 by key; composed moments supplied at every site, then the moments of
each site's actual input measured):

| Arm | Observed vs composed | Exact vs composed | Observed vs exact |
| --- | ---: | ---: | ---: |
| A0 | 28.80 dB | 34.38 dB | 31.42 dB |
| A2 | 18.86 dB | 28.72 dB | 21.82 dB |
| A3 | 16.92 dB | 27.56 dB | 19.81 dB |

Predicted: observed closer to composed than exact is. Refuted in every window and arm: the stream moves away from the
supplied moments, by 4.4 to 13.0 dB. An error at an early site changes the input of every later one, and the errors
compound with depth rather than settling.

**A7 audio** (the same 8 windows; `CompareAudio` against the exact seed-17 render; mean):

| Render | Log-spectral distance | Mel-cepstral distortion | Magnitude SNR | f0 RMSE | Voicing | Loudness |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Seed 18 (yardstick) | 1.43 dB | 4.58 dB | 26.11 dB | 15.6 cents | 0.986 | +0.00 LU |
| A0 | 2.27 dB | 13.04 dB | 16.59 dB | 48.0 cents | 0.965 | +0.12 LU |
| A2 | 4.91 dB | 25.15 dB | 11.67 dB | 79.7 cents | 0.896 | -1.97 LU |
| A3 | 5.46 dB | 33.13 dB | 10.15 dB | 87.6 cents | 0.864 | -1.68 LU |

Predicted: A3 below A0, both above the yardstick. A3 is above A0, refuted. A0's mel-cepstral distortion is above the yardstick in
all 8 windows (7.1 to 24.4 dB against 4.3 to 5.1 dB; log-spectral distance is level with it only in `0EF936E1`), worst in the shortest windows (378 ticks: 24.4 dB, at a
boundary SNR of 28.6 dB). The yardstick's single 55-cent f0 figure (`084C155A`) is a seed effect, not a moments effect.

## What the residual follows

The refutation clause asks what the residual follows. These arms were added after the scores above were seen and are
exploratory; none was predicted.

- **Variance, not mean.** Split into its two halves, A2's noise is a mean offset at 34.56 dB (A0 34.40 dB) and a scale
  term at 27.77 dB (A0 33.88 dB). A2's variance is 0.184 dB too high on average (A0 +0.003 dB).
- **The pads.** Across held-out and development windows, A2's signed variance error correlates 0.90 with the share of
  rows in the start and end pads (A3 0.95), and -0.76 with length. Short windows, whose pads hold 12 to 16% of the rows,
  are overestimated by up to 2.0 dB; long windows lie within -0.03 dB.
- **Own pads.** With the two pads taken from the window's own sums (not reachable by a Student) and the interior from the
  bank, A2 rises to 34.62 dB, gain error 0.18 dB RMS, beating A0 in 42 of 59 windows; A3 rises to 32.10 dB. So the pads
  cost the type bank 4.9 dB, and without them type composition improves on the voice base by 0.55 dB.
- **Not the spread of window levels.** Banking each token standardized by its own window's moments and placing the
  composition about the voice base (A2z, A3z) changes nothing: 28.94 and 27.78 dB, variance bias +0.18 dB.
- **Context keys hurt the mean.** A3's offset half is 30.94 dB against A2's 34.56 dB, with or without own pads. Why is not
  established.

## Observations

- **One set of moments per voice is the best predictor of the whole-window moments tried here**, at 34 dB, and it needs
  no lookahead. Composition from phone types does not improve it unless the pads are known, and then by 0.5 dB.
- **34 dB is not transparent.** A0 audio sits clearly outside the second-seed yardstick, and the moment error grows
  through the network (A5) rather than staying where it is supplied. A per-voice constant is not a substitute for the
  stream's own moments.
- **The breath group and 5 s scopes sit 14 and 19 dB from the whole window**, further than A0 is. If Kokoro trained on
  StyleTTS2's at-most-5 s crops (`live-adain-groundwork-20261114.md`, task 3), whole-window moments were never what the
  network saw in training, and distance from the stock whole-window render (A7's reference) is a distance from stock, not
  a measure of quality. Whether a scoped render sounds worse than stock is not measured here.
- **For the brief:** Stage B's premise, that the Student can supply a scope's moments from per-token contributions, does
  not hold on this data. What remains for depth-first live AdaIN is measuring moments from the stream itself over a
  bounded causal scope, which needs the scope arm's question answered by listening and audio measures rather than by
  boundary SNR against the whole window.

## Limitations

- One voice; float32 host port, not the DSP; teacher durations (Student durations not run); decoder sites not in this
  experiment.
- Each window at its own voice row, so style varies with length across training and held-out windows; the groundwork
  measured the row moving main-section gains by about 1 dB.
- A5 and A7 cover 8 held-out windows, the first 8 by key, 378 to 1,656 ticks.
- Mel-cepstral distortion is `CompareAudio`'s definition; only its relation to the yardstick is interpreted.
- `Measure-StageB.ps1` first stopped in the scope arm: a PowerShell `if` expression unrolled a one-range list into a bare
  pair, so a window with one breath group passed a non-range to the scope kernel. Fixed by direct assignment and rerun;
  only the development MinCount means had printed before it stopped, and the rerun reproduced them.

## Port change

`OfflineLevelRecord.Observed`: in Supplied mode each site also records the measured moments of its actual input, which
the supplied levels normalized (A5). Live mode is unchanged.

## Plan-conditioned base (added the same day, exploratory)

Question: does a base that moves with features of the utterance's plan, all known before synthesis, land closer to the
exact whole-window moments than the voice base? Predictions `PREDICTIONS-PLAN-BASE.md` (SHA-256
`E1BD18308B50599BF80715C4D64B930B0F97F753081CA7CE5D41CCF52EAEF1E8`, 14:51) were written after Stage B's scores and
before any fit.

Each channel's coordinates ln(inv) and mean x inv (A0's coordinates) are fitted by least squares on the training
windows against standardized plan features (ridge 1e-6), then scored as above (`Measure-StageBPlan.ps1`,
`stage-b-plan-scores.csv`). Features, from the cached phonemes, durations, F0 and N: pad share; ln(frames);
punctuation and space share; voiced share; mean and standard deviation of ln F0 over voiced ticks; mean and standard
deviation of N.

| Arm | Features | Held out (59) | Worst window | Under 600 ticks | Development (57) | Predicted, held out |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| P0 | intercept | 34.07 dB | 23.07 dB | 28.53 dB | 34.15 dB | 34.07 dB (control): exact |
| P1 | + pad share | 36.24 dB | 29.07 dB | 33.44 dB | 36.51 dB | 35.0 to 36.5 dB: in range |
| P2 | + ln(frames) | 36.30 dB | 29.10 dB | 33.68 dB | 36.63 dB | 0.2 to 1.0 dB above P1: below, +0.06 dB |
| P3noN | + the four share and F0 features | 37.61 dB | 32.29 dB | 34.70 dB | 37.92 dB | not predicted |
| P3 | + mean and sd of N | 37.85 dB | 32.70 dB | 34.89 dB | 38.15 dB (56) | 36.5 to 39 dB, worst above 27 dB: in range |

P3's two halves are a mean offset at 40.50 dB and a scale term at 36.26 dB (A0: 34.40 and 33.88 dB); its variance bias
is +0.002 dB. Eight scalars of the plan and a linear fit move the base 3.8 dB on average and 9.6 dB in the worst window.
A plan-conditioned base is one K/M/S set per utterance, known before the first sample, so it loads once per job as the
host coefficients do today and needs no coefficient change inside a job.

Deviation from the predictions: 11 cached windows hold no N (10 training, 1 development). P3 is fitted on the 490
training windows that do and leaves the one development window out; P3noN (not predicted) uses all windows.

Not measured: audio with these moments; whether the stream then drifts from them as in A5; Student-produced F0, N and
durations in place of the teacher's.

### Audio and drift with the plan-conditioned base

Predictions `PREDICTIONS-PLAN-AUDIO.md` (SHA-256 `98C1EAA894938130B127D6082A663D910BE33CDE301546B56FE0A8AFBEB44E7B`,
14:59), written before any render. The same 8 held-out windows as A5 and A7, rendered with the P1 and P3 moments
supplied at every site (`renders-plan/`); A0 and the second-seed yardstick are Stage B's renders. Control: all 8 exact
renders are byte-identical to Stage B's.

| Render, mean over 8 windows | Log-spectral distance | Mel-cepstral distortion | Magnitude SNR | f0 RMSE | Voicing |
| --- | ---: | ---: | ---: | ---: | ---: |
| Seed 18 (yardstick) | 1.43 dB | 4.58 dB | 26.11 dB | 15.6 cents | 0.986 |
| A0 | 2.27 dB | 13.04 dB | 16.59 dB | 48.0 cents | 0.965 |
| P1 (pad share) | 1.88 dB | 11.23 dB | 19.27 dB | 36.5 cents | 0.967 |
| P3 (eight features) | 1.78 dB | 10.83 dB | 20.21 dB | 34.2 cents | 0.967 |

| Prediction | Outcome |
| --- | --- |
| P3 mel-cepstral distortion 8 to 11 dB | 10.83 dB: in range |
| P3 log-spectral distance 1.8 to 2.1 dB | 1.78 dB: just below the range |
| P3 below A0 on mel-cepstral distortion in at least 6 of 8 windows | 8 of 8 |
| P1 between A0 and P3 | on both means; in three windows P1 is below P3 |
| The stream still drifts 4 to 7 dB from the supplied moments | 4.0 to 6.0 dB (mean: exact-vs-composed 37.70 dB, observed-vs-composed 33.00 dB) |

P3 closes about a quarter of the mel-cepstral gap between A0 and the yardstick (13.04 to 10.83 dB against 4.58 dB) and
is above the yardstick in every window (6.5 to 18.1 dB against 4.3 to 5.1 dB). The two shortest windows stay worst
(378 ticks: 18.1 dB; 502 ticks: 15.1 dB). P3's log-spectral distance is below the yardstick's in 4 of 8 windows; the
arms share the exact render's seed and the yardstick does not, so that says a reseed moves the log spectrum more than
P3's moment error does there, and nothing about the cepstral measure.

Read together: the plan predicts part of the whole-window moments, and the audio follows the boundary score, but a linear
fit on eight scalars is not enough to reach the yardstick, and supplied moments still drift with depth. Not tried: more
or richer plan features (the per-token plan, not eight scalars), a fit in the stream's own drift (closed loop), and
moments measured from the stream.
