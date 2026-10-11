# AdaIN control stream: chunked decoding with one-pass coherence

Decided 2026-10-10. This is the direction for chunked synthesis; later work extends it rather than replacing it with a
different mechanism. If an experiment shows a part of it does not work, report the measurement and keep the rest.

## Goal

Synthesize any length of speech in bounded decoder-frame chunks with the quality of one uninterrupted pass,
without overlapping published PCM and without waiting for the whole utterance before the first chunk plays.
Cut points may fall inside phonemes; words and word groups do not determine execution boundaries. Measure the
largest stage handoff, the state it carries and simultaneous live memory, then test a static frame size and
resident schedule, including a final partial chunk. The earlier 96-frame capacity is a test point, not a universal
memory guarantee. Arbitrary cut points do not require runtime replanning.

The immediate delivery gate is first a short phone-resident sentence using existing normalization, as ordered
by `handoff-20261010.md`. The bounded streaming path and learned coefficients follow that integration gate.

## Principle

The CPU front end (compiled phonemizer, unit bank, PowerShell-learned tables on CoreCLR, no neural network) already
drives Kokoro's decoder and generator: it selects `t_en` units and produces durations, F0 and N that speak held-out
sentences (`docs/handoff-20261010.md`). It also holds deterministic information the decoder never receives: the text,
word identity and class, stress, word groups, clause boundaries and punctuation, and the complete right-hand context
of the utterance, all known before the first chunk is synthesized.

The same front end gains one more output, a control stream r(t), beside `asr`, F0 and N:

    text -> (asr, F0, N, r(t))

r(t) keeps chunked execution coherent with the uninterrupted decoder. It is learned by the existing training machinery
(aligned observations, backoff keys in `tools/reference/unit-bank/Measure-ProsodyFeatures.ps1`, token targets, held-out
sentences), not by a new learner.

| Part | What it is |
| --- | --- |
| Representation | r(t), a one-dimensional temporal control stream: a scalar first (k = 1), with more channels only if held-out measurements require them |
| Actuation | Per AdaIN site, the DSP adds P_site * v(chunk) to the coefficients (`Km`) that the site computed from the chunk's own moments; P_site (channels x k) lives in `tables.bin` with the voice records; v(chunk) is r(t) aggregated for that chunk, in the job input |
| Teacher | Stock math on our front end's own assembled inputs and noise draws: uninterrupted pass against chunked execution, recording per chunk and per site the coefficient difference |
| Runtime | Deterministic PowerShell/CoreCLR over precomputed knowledge, lowered through PSLowering; no neural predictor, no reference decoder run at playback |

With k = 1 each site reads the same scalar through its own per-channel sensitivities: K_c = K0_c + a_c v and
M_c = M0_c + b_c v, where K0 and M0 are the coefficients the site computes from the chunk (or, in the end state, the
voice's base coefficients) and a_c, b_c are fitted offline from teacher pairs. PowerShell learns the temporal behavior;
the DSP spreads it across channels with fixed-point multiply-adds. The first test is whether the teacher's per-chunk
coefficient corrections lie close to one such scalar relationship per site, scored by decoder output SNR against the
one pass. Within a chunk v is constant (stock AdaIN holds coefficients constant over the normalized sequence);
modulating them per frame is time-varying conditioning, a separate extension measured on its own.

Two separate experiments, in this order: representation sufficiency (can one shared scalar per chunk, through fitted
per-site sensitivities, reproduce the reference corrections well enough, scored by decoder output against the one pass)
and then learnability (can the front end's features determine that scalar on held-out sentences). Training a
controller is pointless until the first passes.

The learning family is knowledge distillation into a deterministic acoustic program: stock Kokoro is the teacher,
`tools/reference/unit-bank/Measure-ProsodyFeatures.ps1` is the baseline learner (frequency-weighted backoff tables over
nine context keys, at least five observations per key), and the held-out split judges every feature. PSPerception
refinement (`tools/reference/unit-bank/Invoke-UnitRefine.ps1`) proposes features but is not the judge: its admitted
combination reached 55.4% held-out against 68.0% for R2, which came from the independent substitution evaluation
(`docs/results/substitution-refinement-20261010.md`). AdaIN targets are per-site coefficient vectors, not per-token
scalars, so the learner's targets and aggregation need extending, not just one more column. The teacher captures use
voice `af_heart`; learned values and coefficient targets carry their voice. The trained tables are held in memory by
the experiment and not yet persisted as a runtime bank (handoff Next item 3).

## What it is not

- Not a per-unit database of AdaIN moments (about 94 GB at int16 for the 2.43M-unit bank).
- Not a separate neural network or a new training architecture.
- Not a statistics lookup substituted when learning is hard: if r(t) cannot reproduce the corrections, the receipt
  says so with the numbers.
- Not dependent on PCA or another dimension reduction as a prerequisite; k is found by measurement.
- Not a change to `asr`, F0 or N.

## Constraints

- Within a chunk a site's coefficients are constant per channel: the stream evolves across the utterance and each
  chunk consumes its own aggregate.
- Corrections at deeper sites are measured on the corrected trajectory: correcting an earlier site changes the
  activations a later site sees. The training target is the one-pass coefficients minus the chunk's local
  coefficients computed on the corrected trajectory (`-Moments SuppliedExport`).
- The coefficient add (`vadd-w`) wraps: learned corrections are range-checked on the host before they are supplied.
- The affine equivalence is exact only for identical incoming activations. Conv edges and generator state can also
  differ between chunked and uninterrupted execution; normalization dominating the measured error is evidence, not
  proof, that it is the only error.
- No dependency on a later chunk finishing before an earlier one runs.
- Benchmarks of this path are labeled as the network-free Kokoro variant (AGENTS.md, "Model changes").

## Evidence and proof sequence

| Step | Status |
| --- | --- |
| Supplied whole-utterance moments reproduce the one pass exactly | done, bit-exact (`docs/results/decoder-supplied-moments-sm8550-20261010.md`) |
| Normalization is the decoder's chunking error | done: two chunks 12.21 dB against one pass with their own moments, 61.97 dB with supplied moments |
| 1. Zero correction reproduces ordinary chunked decoding bit for bit | done, bit-exact (`docs/results/decoder-coefficient-correction-sm8550-20261010.md`) |
| 2. Reference corrections reproduce the supplied-moments result | done, bit-exact, 61.97 dB stitched; the correction costs about 0.06 ms per chunk |
| 3. Learned r(t) on held-out sentences: how much of the 12.21-to-61.97 dB gap it closes | after end to end |
| 4. Runtime: the controller lowered through PSLowering, corrections supplied per chunk | after 3 |
| Generator sites take the same modes | next DSP change |
| 5. End state: the front end supplies each site's coefficients directly; the DSP computes no moments | DSP side done: `-Moments Direct` bit-exact, decoder chunk 13.4 -> 2.9 ms (`docs/results/decoder-direct-coefficients-sm8550-20261010.md`); the front end producing them is open |

## End state: coefficients from the front end

Trained on a large enough corpus and lowered to CoreCLR, the front end supplies each AdaIN site's coefficients (`Km`)
for the utterance, and the DSP loads them instead of accumulating moments. The learning target is then the one-pass
coefficients themselves, per utterance and site; they do not depend on where chunks are cut, so chunk boundaries drop
out of the learning problem. Corrections on the chunk's own coefficients (steps 1-3) come first: they keep the local
statistics as an anchor while the stream is imperfect. Each form is measured against the one pass on held-out
sentences, and the DSP time saved by skipping moments is measured per site (decoder and generator separately).

## Streaming shape

Each chunk is one dspqueue packet: its `asr` slice, F0 and N curves and v(chunk). Per-layer edge frames and the
harmonic source's phase and noise state carry from chunk to chunk on the DSP, so chunks do not overlap. The selector
and controller run ahead of the DSP; AAudio plays finished chunks. Time to first audio is the front end for the first
chunk plus one chunk's DSP time.

Frame chunks are the first temporal tiling method to test. Bind native-layout producer outputs directly to their
consumers, keep live activations resident and reuse storage after its last consumer instead of materializing
separate intermediate tensors where binding suffices. Carry sufficient conditioning and edge/source state;
measure the required carried objects rather than retaining whole-utterance activations by default. Additional
tiling dimensions remain deferred unless frame chunking cannot fit the working set.
Carry the necessary future context, and publish only each tile's new contiguous
PCM span. Job boundaries must not introduce pauses. Whole-utterance style selection, AdaIN control, harmonic phase
and randomness must remain consistent as execution granularity changes.

Extend the existing aligned linguistic stream's word/group features and breath-group code for prosody and context;
do not add an audio segmentation heuristic. Scott's example, "I can" | "eat a peach" | "for hours", describes useful
spoken groups, not mandatory DSP job sizes. Grammatical expectations can develop incrementally ("eat" opens an
object, "for" opens a complement) and persist across time tiles.

Benchmark progressively smaller frame chunks and shifted cut points against one uninterrupted pass.
Hold linguistic context, acoustic controls, utterance style and randomness fixed. Exact parity is the target for
deterministic operators; quantify approximation error separately. Report sample ownership and error near joins,
listening, peak memory, DSP time and first-audio latency. See the deferred shared
[graph tiling design](vtcm-aware-graph-tiling-design.md). These are acceptance targets, not demonstrated results.

## Order

Phone-resident integration first (`docs/handoff-20261010.md` Next items 2-4: generator runtime frames,
compiled selector/tables and fresh short-text `Speak` with all assets local), then state-carrying frame chunks
and the learned stream (item 5). Supplied decoder coefficients already cut chunk execution from about 13.4 to
2.9 ms with exact supplied-path parity; the generator modes and front-end coefficient production remain open.
