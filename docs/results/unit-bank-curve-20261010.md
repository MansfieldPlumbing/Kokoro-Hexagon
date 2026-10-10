# Unit bank at scale: bank-size curve and where the distance comes from (Windows, stock PyTorch)

2026-10-10. Follows `unit-selection-smoke-20261010.md`. Pinned stock Kokoro `dfb907a`, voice af_heart.

Corpus: 44,137 Gutenberg sentences (80 local books) and 30,000 sentences from Markdown under `C:\Dev\.vendor`, all 5-18
words. Phonemized with the lowered CoreDriver DLL called directly (`Dev.MansfieldPlumbing.English.Driver.851C290E...`):
74,137 sentences in 9.8 s, 43,679 accepted. 30,458 rejected (7,112 distinct OOV words, led by inflections: turned,
returns, works). The rejection list is `build/unit-bank/phonemizer-rejections.json`. Held-out phonemizer errors seen:
"neat" -> nˈIt, "home" -> hjˈum.

Capture: stock front end only (ALBERT, predictor, text encoder; no decoder), 343-480 s per 1,000 sentences on the
laptop CPU, in 1,000-sentence chunks under `build/unit-bank/`. Stored: `t_en` int16 with per-chunk per-channel
scales, durations, F0 and N float16. int16 `t_en` is transparent: 92 dB tensor SNR, decoder output mel distance 0.001
against float, durations identical.

Selection: PowerShell reads the chunks directly, indexes units by (left, symbol, right), takes 40 candidates by ±3
context (weights 4/2/1), and runs Viterbi with the join cost learned from genuine joins in the first 1,000 sentences.
Nine plain held-out sentences that are not in the corpus. The unchanged stock decoder renders the result. Assembly
(gather and concatenate) takes 0.4 ms per sentence. Selection in interpreted PowerShell takes 0.6-1.6 s per sentence.

| Bank | Units | (L,sym,R) contexts | Mean log-mel DTW distance (floor 0.64) |
| --- | ---: | ---: | ---: |
| 100 sentences | 5,576 | 1,943 | 6.45 |
| 1,000 sentences | 55,152 | 4,600 | 5.74 |

Decomposition at 1,000 sentences, on the target's stock durations (evaluation only, uses target tensors):

| Selected tensors used | Distance |
| --- | ---: |
| `t_en` only (stock F0, N) | 1.91 |
| `t_en` + N | 3.33 |
| `t_en` + N + F0 | 5.06 |
| all, with selected durations | 5.74 |

Findings:

- Sampled `t_en` (the text encoder output, including its BiLSTM) is close to stock: 1.91 against a 0.64 floor.
  Per-phone acoustic content composes from donors.
- Most of the distance is prosody. F0 and N are sentence-level contours, and unit-by-unit selection does not plan
  them. N adds 1.4, F0 1.7, durations 0.7.
- The F0 part of this metric penalizes any intonation that differs from stock, natural or not, so 5.74 overstates
  the loss in intelligibility. Listening decides (WAVs and spectrograms in `build/unit-bank/eval/`).
- Next question: plan F0, N and durations at phrase level (select or compose a whole-phrase contour and warp it onto
  the selected units), and keep `t_en` unit selection as it is. The 10,000 and 43,679-sentence points are being
  captured.

Scripts (experiment, not yet entrypoint commands): `build/unit-bank/scripts/`.
