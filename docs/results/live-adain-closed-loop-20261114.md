# Live AdaIN: a closed-loop refit of the plan-conditioned moments does not absorb the drift (2026-11-14)

Branch `live-adain`, Kokoro-Hexagon `bcd4847`. Host only; no port change, no phone, no DSP. Receipt:
`build/live-adain-closed-loop-20261114/` (predictions, scripts, both models, logs, per-window observed moments, CSVs,
48 WAVs, `manifest.csv` of SHA-256s).

**Refuted.** Stage B found that when the plan-conditioned moments (P3) are supplied, each site's input then has
moments 4 to 6 dB further from them than the exact moments are. The claim tested here: that drift is systematic, so
refitting each site's set against what it actually receives absorbs it. The plan features explain none of the drift
out of sample, and the corrected set is worse than P3 on held-out windows, in moments and in audio.

## Predictions

`PREDICTIONS-CLOSED-LOOP.md` was written before any render; SHA-256
`3FDF8107C8D11F22AC283DB5683908F438224A59267E8EDA3BFAA4E0B32E2A90`, recorded at 18:30 on 2026-11-14
(`predictions-hash.txt`). Before it, only the fit of model 0 had run (no render). I proposed the refit to Scott and
then, writing the predictions, expected it to be refuted: the drift at a site is its response to the fit's residuals
at the sites above it, and least squares already made those residuals orthogonal to the features.

## Method

- **Model 0** is P3: each channel's ln(inv) and mean x inv regressed on eight plan features over the 490 training
  windows that hold N, against the exact moments Stage B cached.
- **Pass 1**: every 4th of those windows in Stage B's order (123 windows, 143 thousand ticks) rendered through the
  host port's generator with model 0 supplied, keeping the moments each site's input then had (observed).
- **Model 1** = model 0 + the regression, on the same features, of (observed - supplied) in the same coordinates
  over those 123 windows.
- **Evaluation**: the first 16 held-out windows by key (the first 8 are Stage B's render windows), rendered exact,
  with model 0 and with model 1. Boundary SNR over the 9,216 channels of the 48 sites; `CompareAudio` against the
  exact render.

Both sides of every comparison share x, F0, durations, style and the seed-17 draws; model 0 and model 1 renders differ
only in the supplied moments. Training and held-out windows share no text.

## Controls

| Control | Predicted | Observed |
| --- | --- | --- |
| Model 0's moments against Stage B's stored P3 moments, 8 windows | (seen before the predictions) | 0 of 147,456 values differ; held-out boundary SNR 37.85 dB over 59 windows, Stage B's figure |
| Sites whose observed moments are bit-identical to the cached exact ones | exactly two, `noise_res.0.adain1.0` and `noise_res.1.adain1.0` | those two, in all 155 supplied renders |
| Exact and model-0 WAVs of Stage B's 8 windows against Stage B's `-exact` and `-P3` | byte-identical | 16 of 16 byte-identical |
| Model 0 on those 8: observed against supplied, exact against supplied | 33.00 and 37.70 dB | 33.00 and 37.70 dB |

The second control can fail: every other site differs from its cached moments in every render.

## Results

| Quantity | Predicted | Observed |
| --- | --- | --- |
| Pass 1, exact against supplied (in sample, 123 windows) | 38.0 to 39.5 dB | 38.15 dB |
| Pass 1, observed against supplied | 33.0 to 35.0 dB | 33.48 dB |
| Share of (observed - supplied) the features explain, in sample (chance 7.3%) | 7% to 17% | ln inv 11.2%, mean x inv 12.1% |
| The same, two-fold cross-validated | -15% to 0% | -20.0% and -19.8%: **below the range** |
| Model 1 against model 0, held-out observed against supplied (16) | within 0.3 dB | 31.54 against 33.71 dB, 2.17 dB worse: **missed** |
| Model 1 against model 0, mel-cepstral distortion (16; Stage B's 8) | within 0.3 dB | 13.63 against 9.88 dB; 14.40 against 10.83 dB: **missed** |
| Model 0, mel-cepstral distortion on Stage B's 8 | 10.83 dB | 10.83 dB |

Held-out means over 16 windows (`heldout-P0/renders-P0.csv`, `heldout-P1/renders-P1.csv`,
`renders/closed-loop-audio.csv`):

| Set | Exact against supplied | Observed against supplied | Observed against exact | Log-spectral distance | Mel-cepstral distortion | f0 RMSE | Voicing |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Model 0 (P3) | 38.44 dB | 33.71 dB | 36.22 dB | 1.59 dB | 9.88 dB | 40.0 cents | 0.971 |
| Model 1 | 37.38 dB | 31.54 dB | 34.15 dB | 2.02 dB | 13.63 dB | 48.4 cents | 0.956 |

Model 1 has the lower mel-cepstral distortion in 3 of 16 windows and the higher observed-against-supplied SNR in 3 of
16. The refutation clause (cross-validated share under 10% in both coordinates, or no rise in held-out
observed-against-supplied SNR) is met on both counts. A second pass was not run: its rule was a rise of at least
0.5 dB.

I predicted the refutation but not its size. A regression of pure noise on 9 terms over 61 windows scores about
-18% out of sample, so -20% means the features explain nothing of the drift; that much I expected. I expected the
corrected set to be about as good as P3, and it is 3.75 dB worse in mel-cepstral distortion. The correction moved the
supplied moments only 1.06 dB further from the exact ones, yet the stream moved 2.07 dB further from exact under it.
Why a small fitted-noise correction costs that much was not tested.

## Where the drift enters (added after the scores, as the predictions file allowed)

Per site over the 123 pass-1 windows (`pass-1-sites.csv`):

| Sites | Exact against supplied | Observed against exact | Observed against supplied |
| --- | ---: | ---: | ---: |
| `noise_res.0` (6 sites) | 34.4 to 42.3 dB | identical, then 37.2 to 45.3 dB | 32.7 to 41.1 dB |
| Stage 0 resblocks, first site of each | 35.2 dB | 55.9 dB | 35.2 dB |
| Stage 0 resblocks, last site of each | 35.9 to 38.5 dB | 31.0 to 32.9 dB | 29.0 to 31.2 dB |
| `noise_res.1` (6 sites) | 40.6 to 47.5 dB | identical, then 43.3 to 49.7 dB | 40.3 to 45.2 dB |
| Stage 1 resblocks, first site of each | 38.5 dB | 36.8 dB | 32.8 dB |
| Stage 1 resblocks, last site of each | 36.8 to 38.0 dB | 28.2 to 29.5 dB | 27.3 to 28.7 dB |

- The fit's own error is about the same at every depth (35 to 41 dB at the resblock sites).
- The stream's movement grows along each resblock, from its first AdaIN to its sixth, and starts lower at stage 1
  than at stage 0. At the last sites of stage 1 it is 8 to 9 dB larger than the fit's own error.
- So what the supplied moments miss at depth is mostly the stream's response to errors above, which differs per
  utterance and which these eight features do not predict.

## Observations

- Supplied moments cannot be made self-consistent by refitting on the same features. To reduce the drift, the
  moments at the upper sites must be better (more informative features, or the Student emitting them), or the deep
  sites must measure their own input.
- Boundary SNR again fails to rank audio: a 1 dB loss in exact-against-supplied came with a 3.75 dB loss in
  mel-cepstral distortion. Stage C's block arm showed the same in the other direction.
- Distance from stock is not quality. Before this run Scott listened to Stage C's `0EF936E1DE6E-R640P.wav` (causal,
  measured from the stream with a 640-tick prior, 17.76 dB mean mel-cepstral distortion from stock) and reported that
  it sounds good. One window, one arm, one listener; it is the only listening result so far.

## Limitations

- One voice; float32 host port; teacher durations, F0 and N; generator sites only.
- The correction was fitted on 123 of the 490 training windows. A fit on all 490 would carry a quarter of the
  fitting noise; the cross-validated share says there is nothing for it to find, but that fit was not run.
- One pass. A fixed point of repeated passes was not sought, by the stopping rule written beforehand.
- The features are Stage B's eight. A drift that other plan features predict is not excluded.
- Scratch-script notes: the render step failed twice after its first window in a process because a local variable
  shadowed a delegate the port calls (`$draws`); the three windows rendered before the failures were kept, each with
  the two-site control passing, and the logs of both attempts are in the receipt. No score changed. The one-window
  smoke run's line is not in a log; its observed moments are window 1 of `pass-1`.
