# Live AdaIN listening: Scott hears held levels as the same as stock; the only difference he reports is volume, on two passage-bound arms (2026-11-15)

Branch `live-adain`, Kokoro-Hexagon `9955845`. One listener, two passages, existing host renders. Clips:
`build/listen-20261115/` (`index.html` with ten players, and the ten 16-bit WAVs).

**Result.** Scott played the ten clips and reported, first: "all of these sound exactly the same to me". Then:
"volume is lower on these", pasting the labels of the phone-type clips and the plan (P3) clips. He reported no
difference for held levels or for the running measure. Held levels, the cheapest arm and one with no dependency on
the passage, are therefore acceptable to the one judge this project has. No pass mark was adopted by anyone else.

## What was played

Two held-out windows of Stage B (`0EF936E1DE6E`, passage A, 11.97 s; `0730765847E8`, passage B, 6.28 s), voice
`af_heart`, generator only, teacher x and F0, port seed 17. Each clip is an existing float32 render converted to
16-bit PCM; no render was made for this record. The clips were labelled, not blind.

| Label on the page | Render | Source of the generator's levels | Mel-cepstral distortion from stock, mean of Stage B's 8 windows | RMS level against stock, passage A | Passage B | Scott |
| --- | --- | --- | ---: | ---: | ---: | --- |
| Stock Kokoro | `-exact` | each site's own whole-passage moments | 0 | 0 | 0 | |
| Held levels (voice base) | Stage B `-A0` | one fixed set per voice, the training mean | 13.04 dB | +0.60 dB | -0.91 dB | the same |
| Running, by ear (R640P) | Stage C `-R640P` | running measure of what has played, 640-tick prior | 17.76 dB | +0.34 dB | 0.00 dB | the same |
| Levels composed from phone types | Stage B `-A2` | per-type contributions summed over the passage | 25.15 dB | -0.59 dB | -2.99 dB | lower volume |
| Levels from the passage plan (P3) | Stage B `-P3` | regression on eight passage totals | 10.83 dB | +0.27 dB | -0.03 dB | lower volume |

RMS level is over the whole 16-bit clip, measured after Scott's report. The loudest half of each clip's 400 ms
blocks gives the same differences within 0.1 dB.

## What follows

- **Held levels are enough for this listener.** With levels held, each AdaIN site is a fixed scale and offset per
  channel. Nothing is measured, nothing depends on a passage, and nothing on the DSP waits for a statistic.
- **Volume is what he hears.** The phone-type clips measure quieter, 3 dB on passage B, which agrees with him. The
  plan clips measure within 0.3 dB of stock, which does not; whether he hears something RMS misses, or the pasted
  label came along with its neighbour, was not settled. The held clip on passage B is 0.9 dB quieter and he did not
  remark on it.
- **Spectral distance from stock tracked nothing he reported.** Renders 10.83 to 17.76 dB from stock by mel-cepstral
  distortion were the same to him. The Stage B, Stage C, closed-loop, hybrid and second-pass records answer how to
  approach stock; by this result that question did not need answering.

## Limitations

- One listener, one sitting, two passages, one voice. Labelled clips, not a forced-choice test.
- Laptop speakers. Later the same day, of the precision clips, Scott said he was listening on laptop speakers, that
  "about the same" there is not an endorsement over the reference, and that the reference may still be better
  (`generator-precision-listening-20261115.md`). Read "the same" here with that limit: it says held levels are not
  worse in a way laptop speakers reveal.
- Host float32 renders at 24 kHz, converted to 16-bit, played through a browser page. Not the phone, not the int8
  DSP path, not the phone's voice-base table (A0 is the host training mean of the same kind).
- Teacher durations, F0 and x. Nothing here says how a Student's own x would sound.
