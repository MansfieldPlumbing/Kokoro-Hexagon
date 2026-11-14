# Live AdaIN Stage C: moments measured from the stream do not come closer to stock than the plan-conditioned base (2026-11-14)

Branch `live-adain`, Kokoro-Hexagon `a4cb108` plus the Measured level mode this commit adds to the host port. Host
only; no phone, no DSP. Brief: `docs/fable-opus-brief-stage-c-20261114.md` (untracked; "Stage C" there and here is
this experiment, not the Student-emits-controls stage of the 2026-11-13 brief). Receipt:
`build/live-adain-stage-c-20261114/` (predictions, scripts, plan, CSVs, logs, every WAV, the compiled kernels,
`manifest.csv` of SHA-256s, 398 files).

**Refuted.** No causal arm has a lower mean mel-cepstral distortion than P3's 10.83 dB. The best is R640 at
20.13 dB, and 17.76 dB with the pads contributing (an arm added after the scores were seen). No causal arm beats P3 in
any of the 8 windows except that added arm, in one.

## Predictions

`PREDICTIONS-STAGE-C.md` was written at 15:38 on 2026-11-14, before any render; its SHA-256
`62EFE0051B204644B898AF74B87E3957323186E02E205A91541DCC973221A6B7` is unchanged (`predictions-hash.txt`). Before it,
only the kernels on a 12-value toy input and `Get-StageCPlan.ps1` (window lengths, breath groups and the derived
reach, no render) had run.

## Port change

`tools/Invoke-KokoroPrecomputedDecoder.ps1`, all lowered by the pinned compiler (CoreLib only):

- `OfflineRenderMath.MeasureCumulative`: per point (one generator tick's rows; the 128-channel sites' reflection row
  joins point 0) the cumulative row count, sum and sum of squares of the site's input, accumulated in `MeasureLevels`'
  order, with one contribution flag per token.
- `OfflineMomentPolicy` (a class): `Whole`, `Block` (a remainder under half a block joins the block before it),
  `Groups`, `Running` (window, lookahead, prior weight in ticks). Its `Moments` gives each point's mean and variance
  from the cumulative table and the prior, rounded through float as `MeasureLevels` rounds; a point with no rows and
  no prior throws. It also carries the probe ticks and the one-unit nudge used by control 2.
- `OfflineRenderMath.ApplyPointLevels`: `ApplyLevels`' float arithmetic with per-point moments.
- `Invoke-OfflineGenerator -LevelMode Measured -MomentPolicy (New-OfflineMomentPolicy ...)`, prior through
  `-SuppliedLevels`. Each site measures its own actual input. `OfflineLevelRecord.Probed` keeps the moments at the
  policy's probe ticks. Live and Supplied are unchanged.

The brief's "whether pads contribute" is implemented as one flag per token, so a truncated render keeps the long
render's flags for its tokens (by position, the cut's last token would otherwise count as a pad).

`Verify`: every check passes but `handoff` (`handoff-20261101.md has no next steps`), as before (`verify.log`).

## Controls

| Control | Predicted | Observed |
| --- | --- | --- |
| 1. `Whole`, no prior, all tokens, against Live, 3 windows | byte-identical | byte-identical in 3 of 3 |
| 2. One float unit on one mean (`resblocks.2.adain1.1`, point 100, channel 5) | hash changes | changed; first difference at sample 0 |
| Exact renders against Stage B's | byte-identical | 8 of 8 byte-identical (16 of 16 counting the added arms' rerun) |
| 3. Slice | the short render receives the long render's prefix | prefix holds (draws, F0, x); fresh draws of the short length differ, so slicing was needed |
| 3. Truncation, `Whole` | first difference below sample 300 | sample 0 |
| 3. Truncation, R160 and RW400 | identical before 113,355; first difference in [113,355, 113,655) | identical; first difference at 116,067: **missed** |
| 3. Truncation, RL4 | identical before 91,755; first difference in [91,755, 92,055) | identical; first difference at 108,352: **missed** |
| 4. `Verify` | all but `handoff` | all but `handoff` |

Truncation: window `07089683` (1,640 ticks), cut after token 81 at tick 400 (sample 120,000), the long render's
draws sliced. The causal arms are causal: the prefix is byte-identical up to the derived reach, and `Whole` differs
from sample 0. The reach was derived from the checkpoint's kernels by carrying the first row that may differ through
the harmonic interpolation, STFT, noise convolutions, both stages' resblocks, conv_post and iSTFT, with each causal
AdaIN moving it to the start of its point (`Get-StageCPlan.ps1`): 6,645 samples (22.15 ticks) with no lookahead,
28,245 (94.15 ticks) with 4 ticks per site. The first differences arrive later (3,933 and 11,648 samples before the
cut), so the derivation is an upper bound, not exact as I predicted. The likely reason, not tested: the bound assumes
every path reaches the output, and the harmonic source ignores F0 phase in unvoiced samples.

**Lookahead compounds with depth.** A lookahead at every site adds up along the deepest chain of AdaIN sites
(noise_res.0, a stage-0 resblock, a stage-1 resblock: 18). RL80 as the brief specifies it reads about
18 x 80 + 22 = 1,462 ticks ahead, which covers the whole truncation prefix, so it was not truncation-tested and is
not a one-second arm. RL4 (4 ticks per site, 94.15 ticks end to end) was added before rendering to answer "what about
one second of latency".

## Arms

The 8 held-out windows of Stage B (378 to 1,656 ticks), generator only, teacher x and F0, port seed 17, `af_heart` at
each window's voice row. Priors are Stage B's P3 and P0 moments per site. Both sides of every comparison share x, F0,
style and the seed-17 draws; they differ only in the generator's AdaIN moments. Seed 18 shares everything but the
draws.

How far each arm reads ahead: S400 to the end of its 400-tick block, G to the end of its breath group (neither
causal); R40, R160, R640, RV160, RW400, R160P and R640P are causal, their own tick per site, 22.15 ticks of network
reach end to end; RL4 94.15 ticks; RL80 about 1,462.

`CompareAudio` against the exact seed-17 render, mean over 8 windows (`renders/stage-c-audio.csv`; the seed-18, A0
and P3 rows are Stage B's renders measured again here, and the whole-render means reproduce Stage B's):

| Render | Log-spectral distance | Mel-cepstral distortion | First 160 ticks | Rest | f0 RMSE | Voicing | Predicted mel-cepstral |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Seed 18 (yardstick) | 1.43 dB | 4.58 dB | 4.90 dB | 4.56 dB | 15.6 cents | 0.986 | |
| A0 voice base | 2.27 dB | 13.04 dB | 13.91 dB | 12.97 dB | 48.0 cents | 0.965 | |
| P3 | 1.78 dB | 10.83 dB | 11.51 dB | 10.75 dB | 34.2 cents | 0.967 | |
| S400 | 2.38 dB | 12.97 dB | 11.88 dB | 13.15 dB | 64.9 cents | 0.942 | 9 to 19: in range |
| G | 4.44 dB | 28.01 dB | 30.42 dB | 28.19 dB | 87.2 cents | 0.876 | 13 to 30: in range |
| R40 | 5.36 dB | 35.45 dB | 53.73 dB | 32.73 dB | 104.0 cents | 0.817 | 12 to 22: above |
| R160 | 4.65 dB | 29.08 dB | 33.10 dB | 29.40 dB | 106.2 cents | 0.853 | 11 to 20: above |
| R640 | 3.53 dB | 20.13 dB | 16.17 dB | 21.31 dB | 87.5 cents | 0.905 | 10 to 16: above |
| RV160 | 4.76 dB | 29.57 dB | 33.52 dB | 29.70 dB | 113.4 cents | 0.851 | R160 + 0.5 to 2: +0.49, just below |
| RW400 | 4.93 dB | 32.72 dB | 33.10 dB | 33.40 dB | 99.4 cents | 0.854 | R160 + 1 to 5: +3.64, in range |
| RL80 | 4.33 dB | 24.42 dB | 33.34 dB | 22.75 dB | 109.6 cents | 0.869 | 9 to 15, below R160: above the range, below R160 |
| RL4 (added before rendering) | 4.60 dB | 28.45 dB | 31.22 dB | 28.87 dB | 99.1 cents | 0.850 | within 1 dB of R160: -0.63 |
| R160P (added after scores) | 4.46 dB | 27.93 dB | 34.38 dB | 27.99 dB | 85.8 cents | 0.871 | not predicted |
| R640P (added after scores) | 3.13 dB | 17.76 dB | 20.75 dB | 17.54 dB | 80.8 cents | 0.925 | not predicted |

Log-spectral distance was predicted 2 to 4, 1.8 to 3.5 and 1.6 to 3 dB for R40, R160 and R640: all three above.

S400 is the exact render in the two one-block windows (502 and 378 ticks) and G in the one-group window, so their
means include zeros. On the windows where they are not the exact render: S400 17.29 dB over 6 windows (P3 8.90 dB on
the same), G 32.02 dB over 7 (P3 9.78 dB). Per window, no running arm is below P3 in any window; R640P is below it in
one (`0EDE8237`, 378 ticks: 15.7 against 18.1 dB). Every running arm is above the yardstick in every window.

**Convergence**: boundary SNR of each point's moments against the exact whole-window moments, mean over the windows
long enough (n), and the moments each site's input actually had over the whole window against the exact ones
(observed; `stage-c-arms-main.csv`, `renders-added/stage-c-arms.csv`):

| Arm | 40 ticks | 80 | 160 | 400 (7) | 800 (5) | Observed | Predicted |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| R40 | 24.31 | 19.36 | 18.75 | 21.09 | 22.30 | 21.17 | |
| R160 | 33.02 | 26.44 | 23.75 | 23.84 | 23.78 | 21.79 | 30-36 / 28-34 / 25-31 / 24-30 / 26-32: first in range, rest below |
| R640 | 37.20 | 34.24 | 31.27 | 29.15 | 27.30 | 23.97 | above R160 by 1 to 4 dB at 40 to 160: by 4.2, 7.8, 7.5 |
| RV160 | 32.33 | 26.33 | 23.65 | 23.86 | 23.87 | 21.57 | |
| RW400 | 33.02 | 26.44 | 23.75 | 23.84 | 24.50 | 24.29 | |
| RL80 | 25.77 | 24.35 | 24.90 | 23.37 | 23.76 | 21.27 | |
| RL4 | 31.71 | 26.21 | 23.50 | 23.66 | 23.67 | 22.04 | |
| R160P (added) | 23.75 | 26.20 | 26.95 | 26.26 | 25.50 | 27.23 | |
| R640P (added) | 29.36 | 30.98 | 33.26 | 33.22 | 30.25 | 31.84 | |
| S400 (6 windows, 5 at 800) | 29.50 | 29.50 | 29.50 | 29.50 | 24.56 | 41.72 | 17 to 22 at every probe: above |
| G (7 windows, 5 at 800) | 22.70 | 23.11 | 22.53 | 21.38 | 19.52 | 29.54 | 11 to 17: above |

For comparison, Stage B's P3 render had its observed moments 35 dB (mean over these windows) from the exact ones.

## Where the loss sits

The refutation clause asks whether the loss is at the start or throughout. It is throughout, and it follows how much
of the moments come from the stream rather than from the prior:

- Only the weakest prior loses most at the start (R40: 53.73 dB in the first 160 ticks against 32.73 dB after; my
  prediction of a gap above 3 dB held). With R160 the start is 3.7 dB worse than the rest (predicted within 3 dB:
  missed by 0.7). With R640 the start is better than the rest (16.17 against 21.31 dB; predicted a gap under 2 dB the
  other way: missed). As the prior's weight fades, R640's moments move away from the exact ones (37.2 dB at 40 ticks
  to 27.3 dB at 800) and the audio follows.
- **The pads.** Leaving them out keeps the running moments from converging: once the start is past, the arms that
  leave them out sit at about 23 to 24 dB from the exact whole-window moments, however long they run. With the pads
  in (added arms), the observed moments come 5 to 8 dB closer (R160 21.79 to 27.23 dB, R640 23.97 to 31.84 dB) and
  R640's mel-cepstral distortion falls from 20.13 to 17.76 dB. This is Stage B's pad finding from the other side: the
  pads are a large part of what the whole-window moments are. It does not close the gap to P3.
- **Measuring from the stream drifts too.** Even with the pads, R640P's observed moments are 31.84 dB from the exact
  ones, against about 35 dB for P3 supplied. Each site measures an input that the sites before it have already moved,
  and the differences compound with depth as they did for supplied moments in Stage B (A5).
- **A shorter scope moves further from stock, whether causal or not.** S400 reads its whole block ahead and is still
  17.29 dB from stock on the six windows with more than one block (P3 8.90 dB). Breath groups, which include groups
  of 4 to 8 ticks (a punctuation token alone between two others), are worse: 32.02 dB. Forgetting old audio (RW400)
  costs 3.6 dB against R160. Lookahead helps little: RL4 -0.63 dB, RL80 (18 s of real reach) -4.66 dB against R160.
- The voice base as prior is close to P3 as prior (RV160 +0.49 dB against R160): once the stream's own sums dominate,
  the prior's quality matters little.

## Distance from stock is not quality

Every number here is a distance from the stock whole-utterance render. If Kokoro trained like StyleTTS2, on crops of
at most 5 s (`live-adain-groundwork-20261114.md`, task 3), whole-utterance moments are themselves outside what it
saw, and S400's scope is the closer one to training. Nothing here says a scoped render sounds worse than stock; it
says it sounds different from stock, by more than a reseed and more than P3. Every WAV is kept for listening
(`renders/<window>-<arm>.wav`, with `-exact`; Stage B's `-seed18`, `-A0` and `-P3` are in its receipt). No pass mark
was adopted.

## Observations

- Measured, causal moments are not a way to stay near stock. The nearer an arm's moments are to a fixed per-utterance
  set (more prior, pads in), the nearer its audio is to stock; the arms that let the stream speak most (R40, RW400)
  are furthest.
- Of the causal arms, a long prior and pads contributing is the least far (R640P, 17.76 dB), still well above P3.
  A heavier prior would approach P3 itself, which is a fixed base, not a measured one.
- For depth-first live AdaIN this leaves two directions, neither tested here: supply the moments (P3, or better
  plan-conditioned bases) and accept 10.8 dB from stock, or establish by listening whether a scoped render sounds
  wrong at all, which these measures cannot say.

## Limitations

- One voice; float32 host port, not the DSP; teacher durations, F0 and N. 8 windows.
- Generator sites only. The decoder's sites are untouched, and the cached x was decoded under whole-utterance
  moments, so the decoder's part of any live scope is not represented.
- Each window at its own voice row, as in Stage B.
- The derived reach is an upper bound (control 3).
- Breath groups use Stage B's split unchanged, including its 4- to 8-tick groups; a split that merges them was not run.
- The convergence probes are the moments at the end of ticks 40, 80, 160, 400 and 800 at every site, each against
  that window's exact whole-window moments.
- Scratch-script note: the one-off summary in `summary.log` printed three parse errors on rows whose SNR is infinite
  (S400 and G where they equal the exact render). Those rows are excluded from the means either way; no number changes.
  The added arms' render pass reran the 8 exact renders into `renders-added/`; all are byte-identical to `renders/`.
