# Roadmap

The machine-wide rules in `C:\Dev\AGENTS.md` and this repository's `AGENTS.md` apply.
This file records the current campaign: what is built where, in what order, and how
each step is judged. Results go in `docs/results/`.

## Scoreboard

End-to-end real-time factor and time to first audio on SM8550 and SM8635, measured
warm and cold with the same text. The reference bar is the best other Kokoro build:
306 ms warm request-to-first-audio and generator RTF 0.2644 (QNN HTP, SM8650).

## Tracks

| Track | Where | Work | Gate |
| --- | --- | --- | --- |
| 1. Model on the DSP (main line; nothing below may block it) | this repository | VTCM layout per SoC, per-stage SNR trace, rest of the generator, decoder, predictors and ALBERT, then speech on both phones from precomputed phonemes; host-side timing breakdown | bit-exact against the V73 simulator, stage SNR against stock PyTorch captures, phone runs with artifact hashes |
| 2. PSPerception | github.com/MansfieldPlumbing/PSPerception | counterexample-guided percept refinement: provenance-graph store, keep/revert loop, ordered gates, behavioral receipts, compiled output through PSLowering | its own `tests/Verify.ps1` |
| 3. Text front end | this repository | typed spans (Money, Time, Cardinal, ...), reversible projection, SMA parse and non-executing bind, breath-group planner; consumes PSPerception's compiled output by pinned commit | phoneme parity with misaki (lexicon mode) and accuracy on human labels |
| 4. Short bursts and first audio | this repository, PyTorch on Windows | Campaign 1 measurements below | listening plus measured gap closure |

## Track 1: VTCM

Measured with an emitted probe (`docs/results/vtcm-capacity-20261007.md`):
SM8550 grants 8 MiB, SM8635 grants 4 MiB, for every application ID tried.
4 MiB is the design floor. The job queries VTCM at setup and picks its layout:

- general path: time tiles streamed through VTCM with DMA ping-pong, sized from the
  queried VTCM; AdaIN moments accumulated in the producing conv's epilogue, applied
  in a fused AdaIN + Snake + residual pass;
- fast path: when a breath group fits, the whole group stays resident (HMX output is
  the next conv's input, skip connections rotate pointers).

A short first breath group fits entirely on both phones, so the first job takes the
fast path. SM8635's 4 MiB is the platform value (ExecuTorch's Qualcomm SoC table lists
SM8635 and SM7675 as V73 with 4 MB; SM8550, SM8650, SM8750 and SM8850 have 8 MB).
Planner contract: the runtime query is authoritative; at 8 MiB or more use the
large-resident path where liveness permits; at 4 MiB the tiled path is required and the
resident path applies only to groups that fit. Whether one V73 binary runs unchanged on
V75 and later is a separate claim that needs its own phone receipts.

Generator 60x liveness (stock `AdaINResBlock1.forward` and the three-resblock mean,
`istftnet.py` at `dfb907a0`; 128 channels, u8, 998,528 B per tensor at 7,801 frames,
conv weights up to 180 KB at K=11). Three tensors must be resident: the residual
stream, the conv input and the conv output (a conv cannot overwrite its own input
because it reads neighboring frames). The stage input and the three-way mean can stay
in DDR: the input is re-read once per resblock and the mean is accumulated by DMA after
each resblock, about 8 MB of DDR traffic per group against 79 MB today. Three resident
tensors need about 3.2 MB, so 7,801-frame groups stay resident on SM8635 with about
1 MB spare (limit about 9,900 frames); SM8550 can keep four tensors resident (limit
about 15,600 frames). Longer groups take the tiled path.

## Campaign 1 (Windows characterization)

One corpus: WikipediaHomographData at `8f008f021e88f8b71118a27ae655f1f3121162bc`
(Apache-2.0). Voices `af_heart`, `am_michael`. Phonemes from misaki `fba12365` in
lexicon mode (`fallback` set to a callable returning nothing, because a falsy fallback
loads BART), run offline in an isolated Python 3.11 environment built from misaki's
`uv.lock`.

| | Question | Method |
| --- | --- | --- |
| E1 | Does refinement beat ordinary learning, and does SMA add information? | Variants on the dataset's own 90/10 split: A most-frequent; B Gorman-style per-word linear classifier; C PSPerception with B's features; D PSPerception with SMA features only; E PSPerception with both; F misaki with spaCy; G a perceptron port. Human labels are the truth. Primary score: macro accuracy across homographs with a paired bootstrap over homographs. C vs B tests PSPerception; E vs C tests SMA. Lives in PSPerception. |
| E2 | Why do short chunks sound worse? | Render a phrase alone and inside its sentence; swap in AdaIN statistics, durations and pitch, or the style row one at a time; report the fraction of the gap each closes. |
| E3 | Is there only a small number of ways context shapes the rendering? | ALBERT context reach versus right-hand context; per AdaIN site, principal components for 99% of per-channel statistics and how well cheap-stage outputs predict them. |
| E4 | Where can the first burst start? | Boundary, lookahead and VTCM fit, learned by PSPerception once track 1 speaks. |

Automated branches are fixed before the run and recorded in its receipt; they choose
what to measure next and never adopt a change.

## Track 3 status (2026-10-07, scratch lab, not yet in a repository)

Measured on WikipediaHomographData eval (1,615 sentences, 162 homographs, macro accuracy):
most frequent 84.1%; per-word decision lists over neighboring words 91.5%; the same plus
SMA tree features of the projected sentence 91.4% (no gain); misaki lexicon mode with spaCy
89.2% (provisional). The word-context rules match misaki without a tagger; the difference is
not significant. A reversible projection lets SMA parse 99% of held-out English sentences.
Next for the front end: distil misaki's choices over public-domain text for parity on all 671
heteronyms, then correct misaki where human labels (with GPT as calibrated reviewer citing
dictionary sources) show it is wrong. Experiments may use any corpus; shipped tables derive
only from MIT or Apache sources.

## Team decisions not yet taken

- Predicted or shrunk AdaIN statistics for short bursts (departs from stock equations).
- Breath-group boundaries other than stock punctuation.
- U+2019 to U+02BC as the only allowed character change before SMA parses text.
- Moving any front-end scorer to Hexagon (current plan: CoreLib IL on the CPU).

## Standing rules for this campaign

- Stock weights are never pruned or restructured; spare budget buys accuracy
  (split-precision HMX passes, residual weight planes, metadata).
- User text is parsed and bound, never executed. A runspace that resolves commands for
  binding starts from a minimal `InitialSessionState` with module auto-loading off.
- No regular expressions and no JSON boundary in the text front end; data crosses as
  live objects, and the phone never parses JSON.
- Each claim needs a run on the named phone with the same artifact; SM8550 and SM8635
  results stay separate.
