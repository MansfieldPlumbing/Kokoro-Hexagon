# Substitution refinement: right-hand context predicts t_en substitution effects (Windows, stock PyTorch)

2026-10-10. Follows `unit-bank-curve-20261010.md`. Terminology: counterexample-driven representation refinement
(PSPerception), not formal CEGIS/CEGAR.

## SubstitutionTrials

A resident stock-decoder evaluator (one Python process over a pipe) renders each trial. The donor sentence (bank
sentences 1000+) is rendered from its own bank tensors with one token's `t_en` column replaced by a unit with the same
(left, symbol, right) from bank sentences 0-999. Durations, F0, N, alignment, style row and noise draws stay the
donor's. The `SubstitutionEffect` is `AcousticDistortion`: log-mel RMS dB over that token's STFT frames ±2, against the
donor's own render. 1,140 trials from 298 donor sentences, 1-15 dB (median 1.86).

Split by donor sentence (`s mod 3 = 0` held out): 780 training, 360 held-out trials. The candidate units come from a
bank shared by both sides, so this tests new substitution contexts from a familiar bank, not unseen units. Trials from
one donor are dependent. Labels: `ActualDelta` = 1 when distortion is below the threshold. The run computed the
threshold over all trials (1.860, which leaks); the table below uses the training-only median (1.884).

Features (do the donor and replacement contexts agree?): L2, R2, L3, R3 (symbols two and three either side), L2c, R2c
(their classes), Stress, WordPos, PhraseEnd. The agreement features were computed with case-insensitive `-eq` (see
the defects below), which merges A/a, I/i, O/o, W/w and Y/y.

| Guard (agreeing features) | Held-out accuracy | Mean distortion, accepted | Mean distortion, rejected |
| --- | ---: | ---: | ---: |
| Phone only (baseline) | 53.7% (188/350) | 1.97 | 2.25 |
| R2 | 68.0% (232/341) | 1.66 | 2.42 |
| R2 + R3 | 66.6% (213/320) | 1.58 | 2.46 |
| PSPerception's choice: L2 + L2c + L3 + PhraseEnd | 55.4% (168/303) | 1.95 | 2.25 |

On held-out trials, distortion averages 1.48 when R2 agrees and 2.50 when it does not (n = 139 / 221). The symbol two
to the right predicts the conditional substitution effect; the left context barely does. This is consistent with
anticipatory coarticulation in the text encoder's `t_en`.

`Invoke-PerceptRefine` (C:\Dev\PSPerception at `ab9f24c`, initial `Features` empty with the phone as `Action`) admitted
L2, L2c, L3 and PhraseEnd. These reduce training contradictions by splitting keys, but generalize no better than the
phone alone. Defects for PSPerception:

1. Admission ranks by training contradictions. It needs a held-out or cross-validated prediction criterion.
2. `Refine.ps1:460` reads `SpecimenName`, which these records lack. It logged errors and continued.

## Selection with the finding (1,000-sentence bank, nine held-out sentences)

`TargetCost` weights per offset 1..3, left / right: symmetric 4,2,1 / 4,2,1; right-weighted 4,1,0.5 / 4,8,2.
Case-sensitive symbol matching. Mean log-mel DTW distance to stock (floor 0.64):

| Selection | Full | `t_en` only | `t_en` + N | `t_en` + N + F0 | "I can eat a peach for hours." |
| --- | ---: | ---: | ---: | ---: | ---: |
| Symmetric | 5.74 | 1.88 | 3.32 | 5.08 | 5.36 |
| Right-weighted | 5.50 | 1.64 | 2.98 | 4.76 | 4.95 |

The right-weighted cost helps every decomposition and each held-out measure.

## Lowered

`TargetCost` is a typed method in `UnitKernels`, lowered with the pinned PSLowering (`1afabe05`, now PwshCompiler)
into `build/unit-bank/kernels/Dev.MansfieldPlumbing.Kokoro.UnitKernels3.dll` (SHA-256 `9DC0F6035E08F3B6...`). It
agrees exactly with the interpreted cost over 20,000 random (target, donor) positions (0 mismatches). The first
attempt had 74 mismatches. Interpreted PowerShell `-ne` on `[char]` ignores case, while the lowered code compared
ordinally. The phoneme alphabet is case-significant, so the source now uses `-cne`; the earlier interpreted
selection carried the defect.

The pinned compiler also differs from PowerShell for `[char]` `-ne` (ordinal vs case-insensitive), a parity gap to
report to PwshCompiler. Selection still calls the cost from PowerShell; the whole selector is not yet lowered.

Scripts: `build/unit-bank/scripts/` (`Invoke-UnitRefine.ps1`, `eval_server.py`, `mine.ps1`, `UnitKernels.ps1`).
Observations: `build/unit-bank/refine-observations.json`.
