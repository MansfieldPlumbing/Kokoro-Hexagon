# Unit-selection smoke test: Kokoro's own front-end tensors as a sample bank (Windows, stock PyTorch)

2026-10-10. Pinned stock Kokoro `dfb907a`, checkpoint `496DBA11...`, voice af_heart. Held-out target: "I can eat a peach
for hours." (`I kæn ˈit ə pˈiʧ fəɹ ˈWɹz.`, our phonemizer, 28 tokens with BOS/EOS). The target's stock tensors were
captured separately and used only for the assembly control and the final scores.

Bank: 12 donor sentences rendered by stock Kokoro. None contains the target sentence. Content words differ ("ours"
not "hours", "speech" and "beach" not "peach"); function words overlap. Each unit is one input token: its `t_en`
column (512), stock duration in frames, and its F0 and N half-frames (two per frame). 297 units, 3 to 82 candidates per
target token (22.6 on average).

Playback path: `asr` = assembled `t_en` x the alignment built from the assembled durations (stock rule), with
assembled F0 and N, through the unchanged stock decoder. The voice row is fixed at `pack[len(target) - 1]`. ALBERT,
the predictor (all five BiLSTMs) and the text encoder (the sixth) are not run.

Selection (PowerShell, `foreach` and Viterbi over the bank):

- arbitrary: a random unit with the right symbol.
- context: the unit whose donor neighbours best match the target's.
- learned: context cost plus a join cost fitted on the bank's 285 genuine joins (Gaussian log-F0 and N steps at the
  boundary, zero for a donor's own next unit).

| Case | Log-mel DTW distance to target stock | Length | Donor runs |
| --- | ---: | ---: | ---: |
| Assembly control (target's own units) | exact (max abs PCM difference 0.0) | 2050 ms | |
| Different source noise draws only (floor) | 0.58 | 2050 ms | |
| arbitrary | 8.46 | 1800 ms | 27 |
| context | 5.24 | 2200 ms | 16 |
| learned (Viterbi) | 5.18 | 2075 ms | 9 |

For scale: the Zira-metadata substitutions (`prosody-substitution-zira-20261010.md`) scored 5.2 to 9.5 on other
sentences, and a different speaker 8.3 to 11.1.

Spectrograms (`build/unit-selection-20261010/spectrograms.png`): arbitrary is broken by gaps at most joins. Context has
gaps between words. Learned is continuous within words and follows stock's shape on "hours", with a different pitch
contour in "I can eat a". The learned path takes whole donor words where the bank has them ("I can" from "I can tell
you a secret.", "peach" from "speech", "hours" from "ours.").

Cost: the interpreted PowerShell selection took 1.24 s (28 tokens, O(T x C^2) cmdlet calls). It has not been
compiled. A unit is 2 KB of float32 `t_en` plus its F0/N values. The decoder took 1.75 s on the CPU.

Not established: listening (WAVs in `build/unit-selection-20261010/`), more than one target, a bank larger than 12
sentences, and coverage of unseen diphones. The learned join cost barely beat the context-only choice (5.18 vs 5.24)
with 285 training joins. The remaining distance is consistent with the donor `t_en` columns carrying their donor
context (the text encoder's BiLSTM) and with the prosody of donor words not fitting the target sentence's phrasing.
These are the assumptions a larger bank must test.
