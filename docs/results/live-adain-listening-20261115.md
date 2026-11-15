# Live AdaIN listening: Scott hears no difference between stock and any supplied-level render (2026-11-15)

Branch `live-adain`, Kokoro-Hexagon `9955845`. One listener, two passages, existing host renders. Clips:
`build/listen-20261115/` (`index.html` with ten players, and the ten 16-bit WAVs).

**Result.** Scott played the ten clips and reported: "all of these sound exactly the same to me". Held levels, the
cheapest arm and the only one with no dependency on the passage, are therefore acceptable to the one judge this
project has. No pass mark was adopted by anyone else.

## What was played

Two held-out windows of Stage B (`0EF936E1DE6E`, 11.97 s, and `0730765847E8`, 6.28 s), voice `af_heart`, generator
only, teacher x and F0, port seed 17. Each clip is an existing float32 render converted to 16-bit PCM; no render was
made for this record. The clips were labelled, not blind.

| Label on the page | Render | Source of the generator's levels | Mel-cepstral distortion from stock, mean of Stage B's 8 windows |
| --- | --- | --- | ---: |
| Stock Kokoro | `-exact` | each site's own whole-passage moments | 0 |
| Held levels (voice base) | Stage B `-A0` | one fixed set per voice, the training mean | 13.04 dB |
| Running, by ear (R640P) | Stage C `-R640P` | running measure of what has played, 640-tick prior | 17.76 dB |
| Levels composed from phone types | Stage B `-A2` | per-type contributions summed over the passage | 25.15 dB (and 1.97 LU quieter) |
| Levels from the passage plan (P3) | Stage B `-P3` | regression on eight passage totals | 10.83 dB |

The clips are different signals: on the first passage their peaks are 0.559, 0.655, 0.518, 0.495 and 0.629.

## What follows

- **The measures used all week do not track this listener.** Renders 10.83 to 25.15 dB from stock by mel-cepstral
  distortion, one of them 2 LU quieter, were reported as the same as stock. Distance from stock ranked arms that the
  judge cannot tell apart.
- **Held levels are enough.** With levels held, each AdaIN site is a fixed scale and offset per channel. Nothing is
  measured, nothing depends on a passage, and nothing on the DSP waits for a statistic.
- The Stage B, Stage C, closed-loop, hybrid and second-pass records answer how to approach stock. By this result
  that question did not need answering.

## Limitations

- One listener, one sitting, two passages, one voice. Labelled clips: a listener who knows the labels is more likely
  to report a difference than to miss one, so "the same" is not weakened by the labels, but it was not a forced-choice
  test.
- Host float32 renders at 24 kHz, converted to 16-bit, played through a browser page. Not the phone, not the int8
  DSP path, not the phone's voice-base table (A0 is the host training mean of the same kind).
- Teacher durations, F0 and x. Nothing here says how a Student's own x would sound.
