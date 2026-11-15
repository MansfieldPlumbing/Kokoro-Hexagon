# Live AdaIN second pass: supplying what the first pass observed diverges for six passes; a quarter step toward it comes within 3.86 dB of stock (2026-11-15)

Branch `live-adain`, Kokoro-Hexagon `03938ff`. Host only; no port change, no phone, no DSP. Receipt:
`build/live-adain-second-pass-20261115/` (predictions, scripts, logs, per-render observed moments, CSVs, every WAV,
`manifest.csv` of SHA-256s).

**Two results.**

- A second pass that supplies, at every site, the moments the first pass observed is 23.69 dB mel-cepstral
  distortion from stock, against 9.88 dB for the first pass (P3 supplied everywhere). Repeating it gets worse until
  pass 5 and then recovers; pass 19 is the stock render byte for byte. Refuted as predicted.
- A second pass that moves P3 a quarter of the way toward what the first pass observed is 3.86 dB from stock, below
  P3 in 16 of 16 windows.

Both need a complete first pass over the utterance before any audio leaves. After this run Scott said that distance
from stock is not the target, that the number to chase is speed above 40 times real time, and that depth-first exists
so synthesis is not bound to sentences or utterances. These arms do not serve that; this record closes the line.

## Predictions

`PREDICTIONS-SECOND-PASS.md` was written before any second-pass render; SHA-256
`6C45A951086D42CFCF4620EFBDC32F4FB099C4273F0A2FC6D385CAC58EE07EB3`, recorded at 03:35 on 2026-11-15
(`predictions-hash.txt`). When I proposed the run to Scott I implied each pass would come closer to stock. Writing
the predictions I expected the plain second pass to fail, and said so there before rendering.

## Arms

The 16 held-out windows of the closed-loop and hybrid runs, generator only, teacher x and F0, port seed 17,
`af_heart`, P3 from the closed-loop run's `model-0.bin`. Pass 1 is that run's `heldout-P0`, whose observed moments
are reused. Every render is Supplied mode at all 48 sites and shares x, F0, durations, style and the seed-17 draws
with the exact render; arms differ only in the supplied moments.

- **I2 to I19**: pass n supplies what pass n-1 observed. I2 to I5 on 16 windows; I6 to I19 on the three shortest
  (378, 502, 556 ticks).
- **D125, D25, D50**: pass 2 supplies P3 moved toward what pass 1 observed by 1/8, 1/4, 1/2 (mean blended linearly,
  variance + 1e-5 geometrically). I2 is the same blend at weight 1.

## Controls

Depth is the number of AdaIN sites in the longest chain above a site: `noise_res` 0 to 5, stage-0 resblocks 6 to 11,
stage-1 resblocks 12 to 17. A site's observed moments depend only on the sites above it.

| Control | Predicted | Observed |
| --- | --- | --- |
| P3 supplied again, three shortest windows, against the closed-loop run | PCM SHA-256 equal, observed moments byte-identical | both, in 3 of 3 |
| Stage B's exact moments supplied, the same three | PCM byte-identical to the exact render | 3 of 3; all 48 sites observe exact moments |
| Sites observing bit-identical exact moments after pass n | exactly those of depth n-1 or less: 2n up to pass 6, then 12 + 3(n - 6), 48 at pass 18 | exactly those, in all 106 plain renders |
| The same in the damped arms | exactly the two depth-0 sites | exactly those, in all 48 renders |
| PCM of pass 18 and pass 19 against the exact render, three shortest windows | pass 18 differs, pass 19 byte-identical | pass 18 differs in 3 of 3, pass 19 identical in 3 of 3 |

The third control can fail: the script compares each site's identity with its depth and records any other site by
name; none was recorded.

## Results

`CompareAudio` against the exact render, mean over the 16 windows (`renders/second-pass-audio.csv`):

| Arm | Log-spectral distance | Mel-cepstral distortion | On Stage B's 8 | f0 RMSE | Voicing | Below P3 in | Observed against supplied | Observed against exact | Predicted mel-cepstral |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| P3 (pass 1) | 1.59 dB | 9.88 dB | 10.83 dB | 40.0 cents | 0.971 | | 33.71 dB | 36.22 dB | |
| D125 | 1.17 dB | 6.33 dB | 7.00 dB | 33.9 cents | 0.981 | 16 of 16 | 36.64 dB | 39.22 dB | 6.0 to 9.5, below P3 in at least 11: in range |
| D25 | 0.83 dB | 3.86 dB | 4.35 dB | 28.8 cents | 0.987 | 16 of 16 | 39.25 dB | 42.35 dB | 7 to 13: **below the range** |
| D50 | 1.20 dB | 7.95 dB | 8.61 dB | 8.5 cents | 0.985 | 16 of 16 | 35.91 dB | 39.58 dB | 12 to 25, above P3: **missed**, it is below P3 |
| I2 | 3.11 dB | 23.69 dB | 25.73 dB | 40.1 cents | 0.949 | 0 of 16 | 27.19 dB | 30.27 dB | 16 to 35, above P3 in at least 13: in range |
| I3 | 4.96 dB | 37.65 dB | 40.88 dB | 61.0 cents | 0.924 | 0 of 16 | 22.11 dB | 26.01 dB | above P3: yes |
| I4 | 6.31 dB | 47.60 dB | 50.70 dB | 65.7 cents | 0.917 | 0 of 16 | 18.56 dB | 23.26 dB | above P3: yes |
| I5 | 6.84 dB | 49.23 dB | 54.67 dB | 52.7 cents | 0.868 | 0 of 16 | 17.27 dB | 22.71 dB | above P3: yes |

I2 moments were predicted at 22 to 32 dB (observed against exact) and 18 to 30 dB (observed against supplied): both
in range. The predicted order, D125 at or below D25, was wrong: D25 is the best of the three in every window. The
reseed yardstick exists only on Stage B's 8 windows: 4.58 dB.

The plain iteration on the three shortest windows (P3 there: 14.98 dB), mean mel-cepstral distortion by pass:

| Pass | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dB | 36.16 | 55.43 | 69.22 | 73.37 | 58.73 | 53.77 | 40.63 | 30.17 | 27.97 | 19.13 | 13.09 | 6.51 | 2.62 | 0.77 | 0.16 | 0.02 | 0.00 | 0.00 |

The first pass with a mean below P3 on these windows is pass 12. I predicted pass 15 to 18 and none before 13:
missed by one pass, with low confidence stated. Every render was finite.

**The two claims.**

- "A second pass that supplies what the first pass observed comes closer to stock than P3": refuted, as predicted.
  I2 is above P3 in every window.
- "A second pass that moves P3 part of the way toward what the first pass observed comes closer to stock than P3":
  holds, at all three weights. I predicted it for D125 only.

## Observations

- **Why the full step fails.** A site that supplied a wrong gain in pass 1 observes exact moments and is corrected
  in pass 2, but every site below it is now told to expect the shifted stream, which no longer comes. Each applies
  the shift again with the opposite sign, so an error that passed once through k sites is applied k times. The
  site-count control shows the other half: the exact region grows by one depth per pass, and the iteration ends at
  pass 19 whatever happens below it.
- **A part step cancels instead.** At weight 1/4 the stream is nearer its own supplied moments (39.25 dB against
  33.71 dB in pass 1) and nearer stock (42.35 dB against 36.22 dB). The toy model in the predictions put the best
  weight near 1/8 by treating the two stages as one chain of twelve sites; the best of the three tried is 1/4, the
  toy value for one resblock of six.
- D25 on Stage B's 8 windows (4.35 dB) is at the reseed yardstick (4.58 dB) and close to the hybrid run's stage-1
  resblocks normalizing their own whole-utterance input (4.61 dB).
- D50 has the lowest f0 error (8.5 cents) though not the lowest spectral distance. Not examined.
- Distance from stock is not quality, and Scott has said it is not the target. Nobody has listened to these renders.
  Every WAV is kept in `renders/`, named by window and arm. No pass mark was adopted.

## Limitations

- One voice; float32 host port, not the DSP; teacher durations, F0 and N; generator sites only. 16 windows; passes 6
  to 19 on three.
- Three weights were tried, one blend rule, one pass of it. A second damped pass was not run.
- Every arm here costs a complete extra generator pass per utterance and holds all audio until the first pass ends.
  In an earlier message to Scott I said the generator runs about 40 times faster than real time. That figure is the
  DSP time of decoder and generator alone (37.4 times, `stock-end-to-end-sm8550-20261027.md`); text to PCM on the
  phone is 2.2 times (`text-to-wav-phone-sm8550-20261027.md`).
- Scratch-script notes: three render processes were started at once and one failed while loading the port, on a
  file move in the port's compiled-assembly cache; it was rerun alone and its first log is kept
  (`renders-a-first-attempt.log`). The scoring script first counted the three control windows twice, because its
  `-exact.wav` filter also matched the control WAV `C-Exact.wav`; it was fixed and rerun, and the first log is kept
  (`audio-first-attempt.log`). The figures above are from the rerun.
