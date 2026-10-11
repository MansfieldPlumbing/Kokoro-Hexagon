# Prosody substitution: what ALBERT and the predictor BiLSTMs carry (Windows, stock PyTorch)

2026-10-10. Pinned stock Kokoro `dfb907a`, checkpoint `496DBA11...`, voice af_heart, seed 17. Zira = Microsoft Zira
Desktop through System.Speech (phoneme events and PCM, 22,050 Hz). Sentences: hello world (65 frames, 1625 ms) and
benchmark passage 1 "The early morning sun cast long shadows across the empty street." (178 frames, 4450 ms). One
alignment frame is 25 ms (600 samples); F0 and N run at two values per frame.

Every case re-runs the stock decoder with one input replaced, with the same generator source noise draws as the stock
render. Metric: log-mel distance against the stock render (dB RMS over 80 mel bands, mean over frames; DTW-aligned when
the length changes) and PCM SNR where the length is unchanged. Outputs are in `build/zira-substitution-20261010/`
(WAV per case, `results.json`). Nobody has listened to them yet.

| Case | hello mel / SNR | bench1 mel / SNR |
| --- | ---: | ---: |
| Different source noise draws only (floor) | 0.67 / 18.9 dB | 0.70 / 19.8 dB |
| d_en + white noise at 40 dB | 0.14 / 29.8 | 0.51 / 13.5 |
| d_en + white noise at 30 dB | 0.22 / 20.9 | 0.77 / 5.1 |
| d_en + white noise at 20 dB | 0.47 / 11.6 | 1.02 / 0.5 |
| N constant (mean) | 19.29 | 9.64 |
| N zero | 18.77 | 9.68 |
| N smoothed (9 frames) | 1.81 | 1.68 |
| F0 flat inside stock voicing | 3.16 | 3.81 |
| Zira F0 contour on stock durations | 3.21 | 4.59 |
| Zira F0, stock register (log mean/std) | 3.35 | 4.91 |
| Zira durations, Kokoro F0/N on that alignment | 5.28 (DTW) | 5.80 (DTW) |
| Bypass: Zira durations + Zira F0 + N constant | 9.54 (DTW) | 8.32 (DTW) |
| Bypass: Zira durations + Zira F0 + N from Zira loudness | 5.20 (DTW) | 7.20 (DTW) |
| Zira's own voice against stock (other speaker) | 8.29 (DTW) | 11.14 (DTW) |

Findings:

- Zira timebase: phoneme `Duration` values sum to the PCM length (1650 vs 1649.3 ms; 4490 vs 4488.7 ms).
  `AudioPosition` does not; use cumulative durations.
- PCM SNR across different source noise draws is about 19 dB. Stage PCM SNR figures are only comparable with the
  same noise draws, as our receipts use.
- `d_en`: white noise at 20 dB leaves every duration unchanged. At 30 dB `d_en`, the mel distance is at or below the
  noise-draw floor. White noise is not quantization error, so treat this as a sensitivity estimate.
- N is essential. A constant or zero N wrecks the output. A loudness-derived N only partly recovers it.
- Zira's F0 contour scores no better than a flat contour by this metric. Zira's phone set is coarser than misaki's
  (40 of 44 bench1 phones match exactly; hello's ə and oʊ come out as ɛ and o).
- Full bypass (no ALBERT, no predictor) is roughly as far from stock as a different speaker. Zira metadata does not
  replace the duration, F0 and N branches. N, which the predictor computes from ALBERT's context, is what is missing.

Not established: listening, held-out sentences beyond these two, and quantization-shaped (not white) d_en error.
