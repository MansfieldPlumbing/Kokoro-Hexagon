# Information tasks for Codex: live AdaIN conditioning (2026-11-13)

**Status: a proposal written by Fable at Scott's request, for Scott to assign or change. Not an instruction file.
Untracked.** Kokoro-Hexagon `679224d`. These gather facts for the brief beside this file
(`fable-opus-brief-live-adain-20261113.md`). They are not design work.

For every task: say what was read or run and what was only inferred. Outputs go under the ignored `build/` directory
as CSV with a short Markdown note, plus SHA-256s. No tracked file changes except where a task says so, and then on a
branch that is not merged. No changes to PSC or to any `AGENTS.md`.

## 1. Table of every AdaIN site

Read-only. One row per site, decoder and generator (48 generator sites, 9,216 channels).

| Column | From |
| --- | --- |
| Site name, width | the site lists in `src/jobs/Kokoro.DecoderRun16.ps1` and the generator layout |
| Rows per tick | the site's rate against the 80-per-second tick clock |
| Delay | rows or tiles between a text position and the row this site processes for it, in the depth-first schedule (`Layout.Workspace` in `src/jobs/Kokoro.Generator60x16Run.ps1`; the decoder's `-Delayed` layout) |
| Where coefficients are loaded | file, function and line of the load of K/M (and S) |
| Where they are computed | host (`ConvertTo-KokoroGeneratorStageCoefficients`, `ConvertTo-KokoroDecoderCoefficients`) or DSP (`New-KokoroAdaInConstantCoefficientsLoopSteps`) |
| How often they can change today | per job, per span or per tile, as the code stands |

Mark any delay that was inferred and not read from the layout.

## 2. Per-occurrence moment contributions from the host port

Needs a source change (the audit's KH-22: the AdaIN observation callback in `Invoke-KokoroDevelopment.ps1` passes no
clock). Do it on a branch; do not merge.

For each cached `af_heart` syllabus window, each AdaIN site and each phone occurrence: the row count, the sum and the
sum of squares of every channel of the site's input, with the occurrence's identity (window, token index, phone, its
ticks). Rows are assigned to occurrences from the teacher's durations and the site's rate and delay (task 1).

**Control, required before the data is used:** for each utterance and site, the contributions summed over all
occurrences reproduce the moments of the existing export (`Constants`, checked by `New-KokoroDecoderConstantsTables`)
to float32 rounding. Report the largest difference. Then change one occurrence's boundary by one row and confirm the
comparison notices.

State the size of the result and where it is stored. It does not go in Git.

## 3. What scope the network was trained on

External reading; cite each source by URL and commit.

- The clip length the decoder and generator saw in training (StyleTTS2's `max_len` and Kokoro's own training
  configuration if it is published).
- How `AdaIN1d` is defined in the pinned source (`dfb907a02bba8152ca444717ca5d78747ccb4bec`, `istftnet.py`): the
  `InstanceNorm1d` arguments, and whether any running statistics exist in the checkpoint.
- Whether anyone has published a streaming or causal instance-norm replacement for StyleTTS2 or Kokoro, and what it
  cost in quality. Report the claim and its evidence separately.

## 4. Does the style vector move with length?

Read-only, numeric. A voice pack holds one style row per phoneme count. For `af_heart` and two other voices: across
rows, the variation of each site's `1 + gamma` (in dB) and `beta` (in std units), as mean and maximum per site. If the
rows barely differ, style is static per voice and only the moments need a stream.

## 5. From task 2's data: how much scope matters

Only once task 2's control passes. For each utterance: the exact moments of each breath group
(`breath-groups-20260923.md`) against the whole utterance's, per site, as the across-channel RMS of the gain difference
in dB and of the mean difference in std units. No fitting; this is arithmetic on the task 2 sums.
