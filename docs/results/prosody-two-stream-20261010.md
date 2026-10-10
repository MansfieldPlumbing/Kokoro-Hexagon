# Two-stream prosody: linguistic features predict per-token N, F0 and duration (Windows, stock PyTorch)

2026-10-10. Follows `unit-bank-curve-20261010.md` and `substitution-refinement-20261010.md`.

## What N is, and where the prosody error sits

Full-bank selection, nine held-out sentences, stock durations, sampled `t_en`:

| Mean distance (floor 0.64) | Stock N | Sampled N |
| --- | ---: | ---: |
| Stock F0 | 1.17 | 2.70 |
| Sampled F0 | 3.38 | 4.32 |

The effects are not additive (2.21 + 1.53 > 3.15).

- Stock N correlates with the log energy of stock's own output at the same 12.5 ms rate: mean r = 0.988, minimum
  0.984. N is effectively the output log-energy envelope, consistent with StyleTTS2's energy target.
- Sampled-N error is not concentrated at joins (0.67 near non-genuine joins, 0.83 elsewhere). Smoothing N across
  joins made it worse (2.81).
- Negative result: shifting unit N and log F0 by a sentence-position curve made things worse (4.32 to 4.72 / 4.36),
  because silence dominates the position curve's end bins.
- Phoneme-mean N (8-point shape per triphone with backoff, 556k units from 10,000 sentences) matches sampled-unit N:
  2.76 vs 2.70 with stock F0, 4.31 vs 4.32 with sampled F0.

Ceiling (evaluation only): phoneme-mean N and log F0 plus stock's residual, compressed. Columns are N only / F0 only
/ both:

| Residual form | N | F0 | Both |
| --- | ---: | ---: | ---: |
| None | 2.76 | 3.81 | 4.69 |
| Exact | 1.17 | 1.68 | 1.68 |
| One value per token | 1.90 | 2.08 | 2.64 |
| Peak-hold envelope midpoint (instant attack, 120 ms release) | 2.18 | 3.37 | 3.97 |
| 200 ms moving average | 2.19 | 2.97 | 3.64 |
| One value per word | 2.57 | 3.50 | 4.24 |

Two values per token (an N level and a log-F0 level) carry most of the sentence-level contour. The exact-residual F0
column stays at 1.68, not 1.17, because voicing taken from the selected units disagrees with stock.

## Linguistic stream x acoustic stream

Linguistic stream: the driver's `Tokens` aligned to Kokoro phoneme positions (43,679 of 43,679 aligned), Moby word
classes from `capabilities.txt` (including prepositions, conjunctions and adverbs), a function-word list,
function-after-content word groups, and punctuation distance. Acoustic stream: per-token stock N mean, voiced log-F0
mean and duration from the captured tensors (2,429,833 tokens). Learner: nested backoff tables in one PowerShell
process (minimum count 5). Trained on sentences 0-19,999 and scored on 40,000-43,678.

| Features (each row adds to the one above) | N RMSE | log-F0 RMSE | Duration RMSE (frames) |
| --- | ---: | ---: | ---: |
| Phone | 2.443 | 0.3105 (538 cents) | 1.825 |
| + L1, R1 | 1.413 | 0.2826 | 0.944 |
| + R2 | 1.179 | 0.2595 | 0.886 |
| + stress | 1.179 | 0.2595 | 0.886 |
| + word class | 1.167 | 0.2586 | 0.876 |
| + position in word | 1.167 | 0.2586 | 0.876 |
| + punctuation distance and type | 1.135 | 0.2482 | 0.869 |
| + group position, words to end | 1.131 | 0.2472 | 0.866 |
| + sentence position | 1.127 | 0.2438 (422 cents) | 0.868 |

Stress marks and spaces are tokens in the phoneme context, so the stress and position-in-word features add nothing
beyond it. Durations and N are mostly phonetic. F0 is mostly unexplained by any static per-token feature.

Rendered (nine held-out sentences, sampled `t_en`; N = phoneme-mean shape shifted to the predicted token mean; F0 =
predicted token level on the units' voicing):

| Prediction | Stock durations | Predicted durations |
| --- | ---: | ---: |
| Phone | 5.63 | 6.93 |
| + L1, R1, R2 | 4.53 | 5.14 |
| All features | 4.06 | 4.68 |

Listening (one listener, h0 "I can eat a peach for hours." and h5 "The children laughed at the funny little dog.",
all-features prediction with predicted durations, against stock): "sounds different, but not worse". The distance
to stock counts a different but natural intonation as error, so it overstates the quality loss of this path.

Independent recognition: the four WAVs (stock and table-driven, h0 and h5) were played through a speaker into
ChatGPT's voice input, with no reference text. It transcribed 30 of 30 words correctly, for both versions of both
sentences. The scope is narrow: two sentences, one recognizer, and a language model that favors plausible English.
A pitch track of the PCM shows the table-driven F0 as a staircase of per-token levels, with isolated spikes (about
380 Hz and 320 Hz) on short voiced tokens and a higher sentence start than stock (about 300 vs 210-240 Hz). Stock's
own spikes in that plot are octave errors in the pitch estimate.

With predicted durations this is the whole front end with no learned network at playback. At 4.68 it beats the
unit-sampled prosody path (4.90 at the full bank) but is far from the 2.64 per-token ceiling. Next: state (previous
token's values), a lookahead window, and per-token slope, as a damped command-response controller (Fujisaki /
target approximation), scored against the same ceiling.

Scripts: `build/unit-bank/scripts/` (`token_targets.py`, `Measure-ProsodyFeatures.ps1`). WAVs:
`build/unit-bank/eval/h*-predicted-all.wav`.
