# Brief for Opus: live AdaIN conditioning for the depth-first generator (2026-11-13)

**Status: a proposal written by Fable at Scott's request. It is not an instruction file and carries no authority until
Scott approves it. Untracked; Scott decides whether it is committed.** Where it differs from anything Scott says, Scott
is right. Kokoro-Hexagon `679224d`.

## Why this, and why now

Three separate problems meet at AdaIN:

- **Streaming.** Stock Kokoro normalizes every AdaIN site with moments over the whole utterance. The depth-first
  generator cannot wait for an utterance. Today it loads one fixed set of coefficients per job (the voice base).
- **Quality.** The voice base keeps the loudness contour and loses the spectrum: log-spectral distance 8.81 dB against
  3.33 dB between two seeds of the same render (`stock-end-to-end-sm8550-20261027.md`). With an x far from the
  teacher's, constants from another stream remove the output level (`student-stage1-audition-sm8550-20261025.md`).
- **The Student's job.** Scott's direction (audit, "Owner clarification: live AdaIN conditioning as learned
  automation"): the Student provides the conditioning live, from the relationship between typed text objects and the
  old normalization, as levels that hold over a passage while execution continues by tile.

HMX is not the lever. One extra HMX pass over a generator stage cost 1.9 ms of an 86 ms stage
(`generator60x-plane-cost-sm8550-20261007.md`); the stock front end takes 2,528 ms for a sentence the DSP renders in
88 ms, 92% of it in ALBERT and the predictor's LSTMs (`frontend-host-stages-20261027.md`). A Student that emits
durations, F0, N and the conditioning removes that 92%.

## The thing, before the code

- **Style and moments are different things.** A site computes `(1 + gamma) * (x - mean) / std + beta`. Gamma and beta
  come from the voice's style vector. The mean and std are a measurement of the signal at that site.
- **The moments are sums over time.** Over any set of rows, mean = (sum of x) / n and variance = (sum of x squared) / n
  less the mean squared. So a scope's moments are exactly the sums of what each phone occurrence inside it contributes:
  a row count, a sum and a sum of squares per channel.
- **Text runs ahead of audio.** The Student knows the coming phones and their durations before the generator renders
  them. If it knows what each typed object contributes, it can add up a scope's levels before any audio exists. No
  audio prepass, no utterance collected.
- **A scope is a control, not an execution boundary.** A level holds over a passage (an automation clip). The decoder,
  generator and tail keep running by tile dependencies and never see where the passage starts or ends.

**The counterexample to look for.** A deep site's input depends on the coefficients upstream, which depend on the
scope's totals. A phone's contribution measured in one utterance may not hold in another. The records point both ways:
per-channel std moves only 0.33 to 0.96 dB RMS between streams (`generator-normalization-sm8550-20261026.md`), but a
base plus 47 components reached only 30.2 dB on held-out segments (`generator-adain-representation-sm8550-20261020.md`).
Stage B below is the experiment that can refute the idea. Do not build Stage C on it until Stage B has run.

## Stage A: the conditioning stream reaches each site at its position (DSP, no learning)

Today the decoder's Direct mode loads each site's K/M once from `Layout.Input.KmDeltas + site.KmOffset`
(`src/jobs/Kokoro.DecoderRun16.ps1`), and the generator appends one fixed K/M/S set
(`Add-KokoroGeneratorHostCoefficients`, `ConvertTo-KokoroGeneratorStageCoefficients`). Both apply it for every tile.

**Build:** each site's coefficients as a stream indexed by tile on the text clock, applied at that site's own delay in
the depth-first schedule. The delays are already known to the layout (`Layout.Workspace` in
`src/jobs/Kokoro.Generator60x16Run.ps1`: producers, consumers, tile ranges, halos). Use that knowledge; do not write a
second scheduler. A change carries its position, the site it belongs to and how long it holds.

**Evidence, each with its prediction written before the run:**

1. *Control.* A stream that never changes gives the same PCM bytes as today's job.
2. *Equivalence.* The layer reference is given the same time-indexed coefficients. A stream that steps part-way through
   gives byte-identical PCM on the depth-first job and the layer reference.
3. *One-bit control.* Moving the step by one tile at one site changes the PCM hash. Without this the equivalence shows
   nothing.
4. *Position.* Two teacher stretches rendered as one stream, each under its own exported constants with the step at the
   joint, against each rendered alone: equal away from the joint, and the rows that differ are bounded by the
   convolutions' reach. State the bound before running.

**Done:** all four on the phone, as a `Run -Case`, with a record in `docs/results`. The same for the decoder.

## Stage B: do per-phone contributions add up to a scope's moments? (host only)

Data: per site, per phone occurrence, the row count, sum and sum of squares of each channel, from the host port of
stock Kokoro over the cached `af_heart` syllabus windows (Codex task 2 supplies it). Hold out by word-token block as
stage 1 did.

**Arms:**

1. *Harness check.* An utterance's own contributions summed give its exported moments. This is true by arithmetic; it
   checks the capture, and is not evidence for the idea.
2. *Bank by phone type.* A held-out utterance's moments composed from the training mean contribution of each phone
   type, times its tick count.
3. *Bank by type in context.* The same with the stage 1 context keys.
4. *Durations.* Arms 2 and 3 with the teacher's tick counts, then with the Student's.
5. *The fixed point.* Render a held-out stretch under the composed constants, export its actual moments, and report
   whether they moved toward the composed values or away.
6. *Scope.* From the teacher's data alone: how far the exact moments of a breath group are from those of its whole
   utterance. This says how much the choice of scope matters.

**Report against what is already measured**, not against a pass mark (the audit adopts none): boundary SNR beside the
voice base's 21.60 dB and the 47-component fit's 30.21 dB; rendered audio by `CompareAudio` beside the seed-to-seed
yardstick (log-spectral distance 1.80 dB, mel-cepstral distortion 5.80 dB) and the voice base (5.49 dB, 38.28 dB).
Waveform SNR does not separate normalization variants; do not use it alone.

**Refuted if** arms 2 and 3 land no closer than the voice base, or arm 5 moves away. Then the contributions depend on
something the keys do not carry, and the record says what the residual follows (f0, N, position in the scope).

## Stage C: the Student emits the controls (only after A and B)

- Durations, F0, N and the conditioning stream from unseen text, through the actual path: text, typed objects,
  controls, renderer. Stage 1's type means and the unit bank are scaffolding to search from, not the capability.
- The Student's prediction is written before the stock result is consulted, then compared: output quality by spectrum,
  timing, and the front-end work avoided.
- The stock text encoder stays for now (6% of the front end). Producing x directly reached 3.9 dB in stage 1 and is not
  the first step.

## Not this work

- Pronunciation, composition, phonics and morphology judges. The phonemizer already speaks every word.
- Relabelling the voice base, a replayed table or per-category constants as the learned capability.
- Any pass over a whole utterance presented as streaming. Say where future context is still needed.
- A new framework, a second scheduler, JSON records, `[pscustomobject]` records, or edits to any `AGENTS.md`.
- Acceptance thresholds. Scott sets them.
