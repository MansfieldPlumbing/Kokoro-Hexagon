# Phonemizer

English text to Kokoro token IDs. Windows SAPI Zira's contextual pronunciation choices (for example noun/verb
`record`) are captured, lowered into a compact PSD1, and compiled with their selection logic into a CoreLib-only
assembly; no SMA at run time. Workflow: [ZIRA-DISTILLATION.md](ZIRA-DISTILLATION.md).

Developed in PSPerception and imported from GitHub `MansfieldPlumbing/PSPerception` at
`ab9f24ccedfede345187e07764b345f6d10e45d0`; each file's git blob id is checked against that commit:

| File here | Source path | Blob | Check |
| --- | --- | --- | --- |
| `phonemizer/Dev.MansfieldPlumbing.English.Phonemizer.ps1` | `phonemizer/Dev.MansfieldPlumbing.English.Phonemizer.ps1` | `45946de23bd062e075b3607112b75f954992c0aa` | verified |
| `phonemizer/corpora/english-pronunciation-challenges.txt` | `phonemizer/corpora/english-pronunciation-challenges.txt` | `fbfeb7d03fc4a936aab3f36800becc393ce4bf96` | verified |
| `phonemizer/corpora/record-context-smoke.txt` | `phonemizer/corpora/record-context-smoke.txt` | `0b0af5d958e98a03a52a4252bb65d2d778fea9f7` | verified |
| `phonemizer/ZIRA-DISTILLATION.md` | `docs/ZIRA-DISTILLATION.md` | `3c1a22252294fbae4b2a3091214a69105e6bb053` | verified |

Not imported: `phonemizer/GetSmaPhonemes.ps1` (the earlier SMA path, which depends on PSPerception's
`experiments/` and `src/`).

Reported by the PSPerception workflow (Windows; not yet measured on the phone): 73 utterances captured (332 word
events, 1,272 phone events); 1,292 symbols mapped to Kokoro IDs with none dropped, all 114 vocabulary IDs checked;
4 admitted choices, 3 retained rejections, 6 held-out checks; 26 fixtures and 11 teacher-backed token checks; warm
latency about 120 us per sentence (2 us for phone mapping), excluding startup. Misaki parity is a separate gate.

Follow-ups for this repository: the script's default paths still point at `%LOCALAPPDATA%\Build\PSPerception`
(generated files belong in this repository's ignored `build/`), and its PSLowering compiler input is pinned there.