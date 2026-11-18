# Brief for Opus: Stage C, AdaIN moments measured from the stream (2026-11-14)

**Status: a proposal written by Fable at Scott's request. It is not an instruction file and carries no authority until
Scott approves it. Untracked; Scott decides whether it is committed.** Where it differs from anything Scott says, Scott
is right. Kokoro-Hexagon `a4cb108`, branch `live-adain` (2 commits ahead of `origin/live-adain`).

Naming: "Stage C" here is the experiment below. The Stage C of `fable-opus-brief-live-adain-20261113.md` (the Student
emits the controls) is later work and is not this. That brief's Stage A (a host-fed coefficient stream) is on hold: if
moments come from the DSP's own stream, the host cannot supply them.

## What is known (read `docs/results/live-adain-stage-b-20261114.md` first)

- Moments composed from per-token banks are worse than one set per voice (29.73 against 34.07 dB). Refuted.
- A base fitted on eight features of the utterance's plan (P3) reaches 37.85 dB, and its audio is closer to stock than
  the voice base in 8 of 8 windows, but far from the second-seed yardstick (mel-cepstral distortion 10.83 dB, voice
  base 13.04 dB, yardstick 4.58 dB).
- Every time moments are supplied from outside, the stream drifts 4 to 13 dB further from them. An AdaIN site corrects
  itself only when it normalizes the input it actually receives.
- A 400-tick stretch's own moments are 19 dB from the whole window's, and a breath group's 14 dB. StyleTTS2 trained on
  crops of at most 5 s; Kokoro's own training scope is not published.

## The thing, before the code

- **A site's moments over any scope are a difference of two running sums.** Keep, per channel, the count, sum and sum
  of squares of the site's input up to each point in time. Every scope (the whole utterance, a stretch, a breath group,
  everything so far, the last few seconds) is one cumulative value minus another, optionally plus a prior.
- **A prior is rows that were never played.** Prior moments (mean m, variance v) with weight n rows add n to the count,
  n m to the sum and n (v + m squared) to the sum of squares. Weight is time: state it in ticks, so every site gives the
  prior the same duration whatever its row rate.
- **Causal means a row's moments use no input after it.** The network's convolutions already reach a bounded distance
  ahead; a causal arm adds nothing to that reach. Lookahead, where an arm has it, is stated in ticks.
- **Policy is separate from measurement.** One kernel measures the cumulative sums, one applies per-point moments, and
  the arm is plain arithmetic between them. No arm gets its own kernel.

**The counterexample to look for.** The running moments are wrong at the start of an utterance, where little has been
seen, and the error is in the first words a listener hears. If the causal arms lose, look at whether the loss is all in
the first seconds (a prior or weight problem) or spread evenly (the scope itself is wrong).

## Build (host port only, `tools/Invoke-KokoroPrecomputedDecoder.ps1`)

A point is one generator tick's rows at a site (10 or 60; the 128-channel sites' extra reflection row joins the first
point, as `Get-OfflineSiteTokenFrames` gives it to the first token).

1. **Measure.** A kernel beside `MeasureLevels` that returns, for each point and channel, the cumulative count, sum and
   sum of squares of the site's input through the end of that point, with a per-token flag for whether the token's rows
   contribute. Accumulate in `MeasureLevels`' order (each token's sum from zero, added to the running total when the
   token ends; a point inside a token reads total plus the partial token sum), so the final point equals
   `MeasureLevels`' totals bit for bit.
2. **Policy.** A class (not a hashtable) naming the scope and its numbers: `Whole`; `Block` (ticks per block);
   `Groups` (breath groups, split as Stage B's scope arm splits them); `Running` (prior weight in ticks, window in
   ticks or unbounded, lookahead in ticks, whether pads contribute). From the cumulative table and the prior it gives
   each point's mean and variance, rounded through float as `MeasureLevels` rounds them. A point with no rows and no
   prior is an error, not a guess.
3. **Apply.** A kernel beside `ApplyLevels` that normalizes each row with its point's moments, in the same float
   arithmetic as `ApplyLevels`.
4. **Wire.** A third level mode on `Invoke-OfflineGenerator` (the prior arrives as `-SuppliedLevels`). Each site
   measures its own actual input, which already carries the upstream sites' normalization under the same policy.
   Without the new mode, the port's output is unchanged.

The pinned lowering compiler's limits are in `live-adain-groundwork-20261114.md` (classes derive from `Object`,
CoreLib only, `System.`-qualified generic names, no type literals after `-as` or `-is`). Records are classes. Do not
assign a list from an `if` expression; it unrolls. `pwsh -File` passes `A,B` as one string.

## Controls, each with its prediction written before it runs

1. **Whole scope is the stock path.** `Whole`, no prior, every token contributing: PCM byte-identical to the Live exact
   render, on 3 windows.
2. **One bit.** One point's mean moved by one float unit at one site changes the PCM hash.
3. **Causality by truncation.** One window of at least 800 ticks, and the same window cut at a token boundary near
   400 ticks: same style vector, same prior, the long window's noise draws sliced (check the slice is what the short
   render uses). Under a causal arm the two PCMs are byte-identical up to the cut less the network's reach. Derive
   that reach in samples from the generator's kernels and state it before running. Under `Whole` the same comparison
   must differ from the first samples; without that the test shows nothing.
4. **No change elsewhere.** `Verify` as before (every check but `handoff`).

## Arms

The 8 held-out windows of Stage B, generator only, teacher x and F0, port seed 17. Priors come from
`build/live-adain-stage-b-20261114/stage-b-plan-render-moments.clixml` (P3 and P0 per site; P0 is the voice base).

| Arm | Scope | Prior | Question |
| --- | --- | --- | --- |
| S400 | 400-tick blocks, each row by its own block | none | Does a 5 s scope sound like stock at all? Not causal |
| G | breath groups | none | The scope a Student would plan by. Not causal |
| R40, R160, R640 | everything so far | P3 at 40, 160 and 640 ticks | How much prior the start needs |
| RV160 | everything so far | voice base at 160 ticks | What the plan adds to the prior |
| RW400 | the last 400 ticks | P3 at 160 ticks | Whether old audio should be forgotten |
| RL80 | everything so far plus 80 ticks ahead | P3 at 160 ticks | What one second of latency buys |

Pads do not contribute in the Running arms. Add an arm only if the residual asks for it, and label it as added.

## Judging

- `CompareAudio` against the exact seed-17 render, beside what exists: yardstick (log-spectral distance 1.43 dB,
  mel-cepstral distortion 4.58 dB), voice base (2.27, 13.04) and P3 (1.78, 10.83). The exact renders must be
  byte-identical to Stage B's; that is the control that the comparison is like for like.
- The same measures on the first 160 ticks of each render and on the rest, separately.
- Convergence: boundary SNR of each point's moments against the exact whole-window moments, as a mean over windows at
  40, 80, 160, 400 and 800 ticks.
- Keep every WAV, named by window and arm, for listening. Distance from stock is not quality: if the network trained on
  5 s crops, stock's whole-utterance moments are themselves outside what it saw. Say so in the record and do not turn
  a distance into a verdict. Adopt no pass mark.

**Refuted if** no causal arm has a lower mean mel-cepstral distortion than P3's 10.83 dB. Then the record says where
the loss sits (start or throughout) and what it follows.

## Evidence rules

- Write your own predictions for every arm and control, hash the file, and record the hash and time before the first
  render. Report each outcome against them, including the ones that miss.
- Say what each comparison compared and what its two sides share.
- A scratch script's bug that changes a number is reported in the record, with whether any score was seen before it.

## Done

- The port change committed on `live-adain` with `Verify`'s result.
- Receipt `build/live-adain-stage-c-<date>/`: predictions, scripts, CSVs, logs, WAVs, `manifest.csv` of SHA-256s.
  Stage B's scripts are in `build/live-adain-stage-b-20261114/scripts/` (the renderer, the audio comparison, the
  numeric kernels and the split); `build/` is not in git and exists only on this machine.
- Record `docs/results/live-adain-stage-c-<date>.md`, committed. Do not push; Scott decides.

## Not this work

- The DSP, the phone, Stage A, the decoder's sites (the cached x was decoded under whole-utterance moments; say so as
  a limitation), Student-produced durations, F0 or N.
- A listening page, a quality metric of your own, or a threshold.
- A second scheduler, JSON records, `[pscustomobject]` records in the port, or edits to any `AGENTS.md`.
- Any whole-utterance pass described as streaming. Each arm's record line says how far ahead it reads.
