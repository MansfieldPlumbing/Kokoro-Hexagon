# Student

Follow [the repository rules](../AGENTS.md). This file is the authority for
Student and generator work. Records under
`../Pwsh-Development/docs/kokoro-hexagon`, including the earlier Student
contract, are historical evidence and results, not constraints.

## Mission

Kokoro text-to-speech for arbitrary text on Android, with on-device performance
as the primary measured objective: our phonemizer on CoreCLR, the Student, and
Kokoro's frozen generator on Hexagon. The Student learns from training text,
retains what it has learned as stored percepts, and generalizes to unseen text.

The Student is a procedural learning system, not a neural network or
machine-learning model: it learns through rules, types and extended types
(ETS members bound to typed objects). PowerShell is used as a live object
system in the manner of Smalltalk or Lisp, with the full .NET runtime behind
it, not as a shell.

The design objective is amortization: every cost is paid once, at the coarsest
rate that allows it, and reused at the audio rate. Per device: the generator's
weights, resident once and shared by every voice. Per voice: the voice record
and each AdaIN site's sensitivities. Per typed object: its learned behaviour,
shared by every occurrence. Per control event: the expansion into generator
inputs. Per tick: only what cannot be computed earlier. Earlier work
recomputed per utterance or per sample what a Student can learn once
(whole-utterance AdaIN moments, per-unit storage, the source branch); the
items below move that work out of the audio-rate path.

### This is not stock Kokoro

At run time only Kokoro's frozen generator weights and voice records are used. Kokoro is
the teacher for local sound, not the design. Do not reason about this system
as if it were stock Kokoro with faster kernels.

| Stock Kokoro (upstream `pipeline.py`, `model.py`) | This system |
| --- | --- |
| Input is a string: `KModel.forward(phonemes: str, ref_s)` | No strings. Text enters as typed token occurrences with global identity (book, paragraph, token index, source offset) |
| The pipeline splits text with regular expressions and chunks it at punctuation into pieces of at most 510 phonemes | No sentences, spans or windows. The system is object-based, not token-based: typed objects (occurrences, percepts, closures, the controller, voices) hold state and act on messages; tokens are only how text enters. Context is carried state, at any distance |
| PL-BERT, predictor and decoder run over the whole chunk | The Student replaces everything up to and including the decoder |
| AdaIN normalizes with moments over the whole utterance | AdaIN normalization is the Student's controller stream: the Student holds a dual-analog controller, and conditioning is held controller state |
| Audio is returned per chunk, after the chunk is complete | The generator runs continuously on its cadence with resident weights; audio starts at the first controller state and has no utterance boundary |

The 510-phoneme window appears in this project only as the scope of the
evidence Kokoro can supply as a teacher (see Teacher data).

The Student's source is `student/Invoke-Student.ps1`, reached through
`Invoke-KokoroDevelopment.ps1 Student`. Extend that owner.

This document describes two designs. v1 is current work. v2 follows v1 and is
not current work. The Student is being rebuilt; these names are unrelated to
earlier StudentV2 work.

## v1: the Student at the generator boundary

### Boundary

The Student replaces everything in Kokoro up to and including the decoder and
drives the frozen generator. Stock Kokoro calls it as
`Generator.forward(x, s, f0)` in upstream `kokoro/istftnet.py`; here `s` is
not used, and AdaIN conditioning comes from the Student's controller stream:

| Input | Shape | Rate |
| --- | --- | --- |
| `x` | 512 channels | one vector per generator tick (300 samples at 24 kHz, 80 per second) |
| `f0` | 1 value | one per tick; zero is unvoiced |
| `s` | 128 values | stock only, not used here: per utterance, `ref_s[:, :128]`, the voice-pack row selected by phoneme count (`pipeline.py`: `pack[len(ps)-1]`) |

Kokoro components the Student replaces: PL-BERT and `bert_encoder`, the
duration predictor, the F0 and N predictor (`F0Ntrain`), the text encoder, the
alignment, and the decoder (`encode`, four `decode` blocks, `F0_conv`,
`N_conv`, `asr_res`). N fed only the decoder and is not produced.

Paths into the generator that matter for accuracy:

- `f0` bypasses the decoder. Inside the generator it builds the harmonic and
  noise source, whose STFT is added at every upsampling stage (`noise_convs`,
  `noise_res`). Errors in `f0` reach every stage.
- In stock Kokoro `s` drives AdaIN in every generator resblock and source
  block; here the controller stream does.
- Token identity reaches the generator only through `x`.

### Output streams

The Student emits two streams, produced incrementally from the text so audio
can start before the utterance is complete:

- Control stream: sparse events, each a 96-bit record in the shape of an
  XInput dual-analog controller state (16 button bits, two 8-bit triggers,
  four 16-bit stick axes), timestamped on the generator tick clock. Buttons
  carry discrete state (phrase and closure boundaries, voicing, emphasis
  on or off); triggers and sticks carry continuous controls (prominence,
  pitch movement, rate, voice-quality controls). A person can drive the same
  record from a physical controller, which checks that every required sound
  is reachable through the controls. Which control carries which quantity
  is decided by measurement, not fixed here. On the wire to the DSP each
  update is one 96-bit snapshot of that record: all six analog values and
  the buttons at fixed offsets, read without parsing (12 bytes, against 48
  bytes for six separate 64-bit MIDI 2.0 controller messages). MIDI 2.0
  Universal MIDI Packet messages (per-note events, velocity, per-note pitch
  bend and per-note controllers, with timestamps) are the interchange and
  inspection format, converted losslessly for the mapped controls and
  specified from the MIDI 2.0 specification before encoding; v2 uses them
  for per-note polyphony.
- The Student does not depend on the target. Its streams bind to a renderer
  per target (the Hexagon generator, a host emulator of it, later others);
  training against a quantized generator (stage 5) is a refinement of one
  binding.
- The stream format is extensible without revision. A layout is declared
  once when the stream opens: the number of records, each record's type
  (the controller record above; other device types later) and the quantity
  each control carries. Every update is then that many records at fixed
  offsets. A further controller (two records, 192 bits per update, or more)
  changes the declaration, not the format.
- Tiles are the DSP's execution granularity only. The Student emits a
  continuous stream on the tick clock and never sees tile boundaries;
  supplied coefficients do not depend on where tiles are cut. Its one
  obligation is to run ahead of playback by at least one tile plus the
  generator's convolution lookahead.
- Generator stream: per tick, `x` (512 channels) and `f0`; and the
  coefficients of every AdaIN site, expanded from the control stream. The
  source is produced on the DSP from the VTCM phase loop and seeded noise
  counters (see Generator implementation), so `x_source` is never
  transferred.

AdaIN coefficients. The generator has 48 AdaIN sites: `resblocks.0-5` and
`noise_res.0-1`, two per dilation, 24 sites at 256 channels and 24 at 128
(consistent with the 2,377,728 `fc` parameters). Folding InstanceNorm into
AdaIN, each site applies a per-channel scale and bias, 18,432 values in all.
Twelve of the sites are in `noise_res`, the source branch, and 36 in
`resblocks` (13,824 values: 6,912 scales and 6,912 biases); all run on the
DSP.
The stock model computes them from `s` and from moments over the whole
utterance, which forces whole-utterance execution. The Student supplies them
instead:

    coefficients(site, t) = base(voice, site) + P(voice, site) * v(t)

Supplying every AdaIN site's coefficients is a requirement on the Student's
design from stage 1, not a later optimization. Whole-utterance normalization
is what forces the generator to hold or recompute a whole utterance's
activations and to accumulate moments before any audio can be produced. With
supplied coefficients the generator runs depth-first in time tiles, and its
working memory is only the per-layer context buffers, which fit in the VTCM
that remains after the resident weights (see Generator implementation, item
1). Any Student design that cannot supply the coefficients is rejected.

`v(t)` is the control stream's continuous state (k values, at most the six
continuous controls of one record); `base` and `P` (channels by k) are per
voice and stay resident with the generator; the DSP expands them with
multiply-adds. With k = 1 a single stick axis carries `v(t)`: one 16-bit value
per update moves all 18,432 coefficients, each through its own sensitivity, in
place of about 36 KB of fp16 coefficients per update. Further axes and
triggers are added only if the representation measurement requires them.
Measured on the stock decoder, supplied whole-utterance
moments reproduce the one-pass output bit for bit, chunks with their own
moments reach 12.21 dB against one pass and 61.97 dB with supplied moments,
and supplying coefficients directly cut a decoder chunk from about 13.4 to
2.9 ms (`decoder-supplied-moments-sm8550-20261010.md`,
`decoder-direct-coefficients-sm8550-20261010.md`). The generator sites have
not been measured. Order:

1. Teacher capture: the coefficients each generator site applies, recorded
   by the lowered teacher as evidence for the controller state that
   reproduces them. Supplying them back must reproduce the teacher's PCM
   exactly. The window is only the teacher's evidence scope; no moments over
   a span are carried into the Student.
2. Representation: the smallest k for which fitted `base` and `P` reproduce
   the captured coefficients, scored by generator PCM SNR against the teacher.
3. Learnability: the Student's control stream predicts `v(t)` on held-out
   text, scored the same way.

### Prosody rules as candidate types

`../Pwsh-Development/# English Prosody Rulebook.txt` lists 80 rules of
American English phrasing, timing, pitch, focus, lists, questions and
quotation, each with a confidence rating. They are candidate closure types and
expected directions of effect, not targets: each becomes a typed object or a
closure type whose behaviour is learned from teacher evidence and kept only
where held-out evidence supports it. Their effects map to the control stream
(boundaries and closures to buttons, prominence to triggers, pitch and timing
movement to sticks).

Impart the rulebook's structural knowledge as reusable behaviours with explicit
activation conditions, state effects, pending expectations and completion.
Resolve their interactions using the rulebook's precedence and confidence
distinctions. Accent, boundary pitch and boundary timing remain distinct
decisions; overlapping rules describing one boundary produce one coordinated
action. Teacher evidence calibrates the realization and supports contextual
exceptions; acoustic similarity alone does not establish a semantic or
structural correction.

### Normalization transfer from the front end

The existing compiled PC front end supplies text normalization and
pronunciation knowledge. Extend its owning phonemizer and the Student's
existing token interface to retain typed values, the selected normalization
operation, relevant context dependencies, unresolved alternatives and the
source identities of emitted words and phones. Preserve correspondence when
one source occurrence expands into several spoken objects.

Bind reusable operations and state transitions to typed objects through ETS.
Reuse admitted compiled operations directly where they already implement the
required behaviour. Report this as reuse of authored knowledge; claims of
learned generalization require evaluation on held-out values, occurrences or
contexts with stored output lookup excluded. Select each next normalization
family from coverage and unresolved cases in the actual corpus.

Context is carried state: interpretation alternatives, open closures and
controller state survive subsequent inputs. A behaviour consumes a typed
occurrence and the current state, produces decisions and control actions,
and updates that state. Controller events change held state; sensitivity,
acceleration and response modes determine its evolution over elapsed time.
Extend the existing types and graph; lower hot operations into typed managed
calls while keeping ETS members available for composition and inspection.

### Typed learning

The Student never sees raw sentences. Sentences are not the unit of learning
or of evaluation, and no special or hand-picked sentences are used.

- Learning is organized as typed objects, one type per semantic layer (phone,
  syllable, word, phrase and so on). Each type carries ETS-bound behaviours
  (members and bindings added with `Update-TypeData`), such as timing, pitch,
  loudness and the stretch of `x` it produces, learned from every occurrence
  of that type in the teacher evidence.
- Teacher evidence is grouped by type, never by sentence: each occurrence
  contributes its aligned stretch of `x` and `f0` to its type.
- Interpretation is incremental, through closures: each word is a closure over
  what it still awaits; the next word applies it, extends it or opens a new
  one. Prosody reads the open-closure state (an unapplied expectation means a
  continuing contour; a satisfied one makes closure available; terminal
  punctuation closes it).
- Closures are not limited to the teacher's window. Stock Kokoro sees at most
  510 phonemes; an open closure (an enumeration, a quotation or parenthesis,
  a contrast, a counter-example section, an unresolved heteronym, a name and
  its pronunciation) carries typed state across any distance. Its behaviour
  is learned from teacher windows that contain both ends and applied at any
  span, so prosody and pronunciation can use context the teacher never sees.
- Each closure type also learns its lifetime: how far it usually stays open
  and which boundaries end it (paragraph, section, heading). An expectation
  never satisfied within that lifetime is closed by the Student with the
  type's learned default resolution (contour reset, more probable heteronym
  reading, quotation ended at the paragraph) and marked as closed by expiry,
  so its frequency and correctness are measured. An expired closure keeps
  its references: when a later token matches it, it reopens and binds. If
  the affected tokens have not been spoken yet, their resolution is revised;
  if they have, later mentions use the corrected resolution and the reopening
  is recorded as evidence against that type's lifetime or default.
- No data structure caps the horizon. Every token has a global identity
  (book, paragraph, token index, source offset); windows and sentences are
  references to token ranges, not copies of text; closures reference their
  opening and closing tokens by identity, at any distance. This holds before
  long-horizon behaviours are implemented.
- Emphasis is a typed member of a word: author italics from the source text
  now, contrast and focus closures later.
- Expectations are induced by type from the whole corpus. A specific word gets
  its own entry only when held-out evidence supports the split.
- Held-out evidence is held out by type occurrence.

### Percepts

A percept is a typed object's stored behaviour: a reusable program that
produces its stretch of `x` and `f0` in context. Kokoro token IDs are kept as
one of its fields and may be removed later. Percepts store how to produce
values, not recordings of them. No unit bank is stored; units are generated on
demand.

### Percept graph

Percepts are linked by typed edges, so the Student is a sparse typed graph:

- Nodes are percepts: phone, syllable, word, phrase, closure type, voice.
- Edge types: sequence (one percept followed by another), containment
  (phone in syllable in word), closure binding (opening and closing tokens
  at any distance) and voice (a percept under a voice).
- A node's output in context is its own program plus the contributions of
  its active incoming edges. A sequence edge produces the transition between
  two percepts (coarticulation); a closure edge produces the timing and pitch
  of a continuing contour.
- Learning fits node programs first, then each edge type to the remaining
  error. An edge is added only where held-out evidence supports it.
- Only edges active in the current context are evaluated, so producing
  output stays sparse and runs ahead of the DSP on the CPU.
- An edge's contribution is a stretch of `x` (512 channels), stored as a
  low-rank program, never as a dense matrix, so the graph does not rebuild
  the weight problem the Student removes.
- Every node and edge has a type and is listed by the tool's description of
  itself; nothing in the graph is opaque.

### Consolidation

A consolidation pass runs between training stages and whenever evidence
accumulates. Each change is kept only if held-out PCM SNR holds:

- Merge types whose learned behaviours have converged (one percept, several
  keys).
- Split a type where held-out evidence shows two behaviours (a heteronym, a
  function word stressed and unstressed).
- Prune nodes and edges that are unused or not supported by held-out
  evidence.
- Lay out storage by use: percepts and edges used together are stored
  together; frequently used ones are compiled to lowered code and kept
  resident (hot-path compilation), so speed follows use.

Consolidation bounds the Student's size as the corpus grows and lowers the
cost of producing output.

### Voices

There is one shared corpus of typed content, interpretation and relationships.
Each voice contributes realization evidence attached to the same occurrence
identities with its provenance. Voice differences alter how shared behaviour
is performed; normalization and linguistic structure are shared. Matched
observations retain each voice's actual durations, with phone correspondence
used to compare local trajectories. Adding a voice extends its record and
evidence rather than generating another corpus.

The first voice is `af_heart`: all teacher evidence is rendered with it until
the Student meets its goals on held-out text with that voice. The second voice
is then added to measure how much of each percept is shared.

The Student learns several voices and switches between them. Storage differs
from Kokoro, where each voice is 510 rows of 256 values used through the
predictors and decoder on every utterance:

- Percepts are shared across voices and trained on all voices' teacher output.
- Each voice is a record:
  - each AdaIN site's `base` and `P`: how the voice responds to the
    controller, in place of the generator style rows (`ref_s[:, :128]`)
    and the `fc` layers, with no dependence on phoneme count;
  - a transform of `x` across all 512 channels (per-channel scale and bias plus a
    residual), since the decoder imposed the voice on `x` largely through AdaIN;
  - prosody style (timing and pitch behavior), which replaces the role of
    `ref_s[:, 128:]` in the removed predictors.
- Switching voices replaces the record. Blending records is possible.

Measure before building: the fraction of the difference in `x` between voices
explained by a per-channel scale and bias.

### Teachers are adapters

The Student's core is teacher-neutral: typed layers, closures, pronunciation,
and prosody behaviours in physical units (durations in seconds, pitch in hertz,
energy, emphasis). Nothing in the core refers to a teacher's frames, token IDs
or channels. Each teacher has an adapter that converts its evidence into those
units and binds the Student's neutral output to its renderer's input (for
Kokoro: `x`, `f0` and the controller's expansion into each AdaIN site). Only the renderer binding is
teacher-specific and is retrained per teacher. Evidence records which teacher
produced it, so evidence from several teachers for the same typed objects
coexists. A later teacher (for example Chatterbox Turbo) is added as a lowered
port and an adapter, specified from its source at a pinned commit, without
changing the core.

The core stays open to what later teachers add, by extension, not by
redesign: new token kinds (for example non-verbal events such as laughter
or breaths) are new typed objects; new continuous expressive controls are new
control-stream axes or records; a voice estimated from reference audio is a
voice record produced by listening mode. Each later teacher is specified from
its own source at a pinned commit before its adapter is built.

### Teacher data

Teacher data comes from our own port of stock Kokoro in lowered PowerShell,
compiled through PSLowering and run on the host CPU (CoreCLR). It does not run
on Hexagon. Its purpose is that this project never needs Python again.

- The decoder and generator are ported in `tools/Invoke-KokoroPrecomputedDecoder.ps1`
  and reproduce stock PCM at 80 dB or better with matched draws.
- ALBERT, `bert_encoder`, the duration and F0/N predictors and the text
  encoder are ported the same way and checked against stored stock outputs.
  Until they are, teacher evidence comes from the stock outputs stored in
  `build/unit-bank` (text-encoder output, durations, F0 and N). Once they are,
  `StockCapture` is retired.
- Training and evaluation use arbitrary content only: no curated, named or
  hand-picked sentences or captures, in training, evaluation or checks.
- The teacher's input unit is a window of continuous text, never a sentence.
  Stock Kokoro's PL-BERT attends across its whole input (up to 510 phonemes),
  so prosody depends on neighbouring sentences. Windows run through the
  source text in order across sentence and paragraph boundaries, overlap so
  that each typed occurrence's evidence is taken where it has context on both
  sides, and vary in length over 1 to 510 phonemes so that every voice-pack
  row (`pack[len(phonemes) - 1]`) is exercised. Zira receives the same spans.
- The window bounds only the evidence stock Kokoro can supply; it does not
  bound the Student. Long-horizon behaviour learns from sources without that
  limit: Zira's timing, pauses and emphasis over whole paragraphs and
  sections; the text's own structure (sections, headings, lists, quotations,
  counter-example sections); and measured context sensitivity, obtained by
  rendering the same span inside windows with different preceding context
  and carrying the measured effect beyond 510 phonemes. Kokoro remains the
  reference for local sound (`x` and voice).
- The 510-phoneme window is Kokoro's limitation (upstream `pipeline.py`
  rejects longer phoneme strings), not the Student's. It is a pragmatic scope
  for learning from Kokoro. Chatterbox, the next target, is not bound by
  Kokoro's limit, so nothing in the Student's types, closures or runtime is
  scoped to it.
- Text source: the full text of the Project Gutenberg books in
  `build/grammar-corpus/raw`, read in order, not the extracted example lists.
  Sections headed "IMPROPRIETIES FOR CORRECTION." and "FALSE SYNTAX ..." run
  to the next heading; occurrences from them carry a counter-example flag.
  Acoustic behaviours learn from them normally; phrasing and closure
  behaviours use them as negative evidence.
- The corpus is typed tokens from a lowered tokenizer (no regular
  expressions): words, numbers, ordinals, punctuation, quotation marks,
  symbols and transcriber notes, with source spans. Project Gutenberg markup
  becomes token flags (emphasis from `_..._`, editorial insertion from
  `[...]`), never deletions. Numbers, dates, times and currency become typed
  values through .NET conversions, and their spoken forms come from the value.
- Zira (Windows speech API, `Microsoft Zira Desktop`) reads the whole text,
  including sentences our phonemizer rejects. Every word token carries both
  pronunciations as typed members, joined by source span: ours and Zira's
  (mapped to Kokoro symbols, with her word timing). Our phonemizer's
  pronunciation is used wherever it has one (it carries stress marks). Where
  Zira's differs, hers stays on the token as a counter-example. Systematic
  differences between her symbols and Kokoro's are learned from the spans both
  pronounce, not written by hand (for example her `o`, which aligns with
  Kokoro's `O`). These correspondences
  are applied to Zira's pronunciations of words our phonemizer does not know.
  Zira's events carry no stress, so those words get primary stress before the
  first vowel until stress is learned. Context-dependent differences (Kokoro's
  flap `ɾ` for Zira's `t` and `d` between vowels) need correspondences
  conditioned on neighbouring symbols. Windows are token ranges, assembled
  from the tokens' resolved phonemes and passed to the teacher as phonemes;
  for sentences our phonemizer accepts whole, the assembled phonemes equal
  its output.
- Teacher evidence passes validity gates before the Student learns from it:
  complete, aligned with Zira by source span, and agreeing with the resolved
  pronunciation. Where the resolved pronunciation differs from what stock
  Kokoro's front end would produce, the teacher is run on the resolved
  phonemes, so the Student learns Kokoro's sound for the corrected
  pronunciation. Zira's word and phone events
  (timing, emphasis, source character spans) supply the typed linguistic
  structure; Kokoro supplies the acoustics.
- The teacher decodes each stored utterance with its own voice row,
  `pack[len(phonemes) - 1]`, as the stock captures did, then splits the result
  into typed occurrences. Utterances stay inside the teacher; the Student
  receives only typed evidence.

### Training and evaluation

- The Student matches the decoder's `x` and the predictor's F0 for the same
  text. A change is kept only if held-out end-to-end PCM SNR does not drop; a
  separate untouched test split gives the final score. Held-out PCM SNR below
  40 dB is a failure.
- End-to-end goal: generator PCM above 50 dB SNR against stock Kokoro for the
  same text, voice and source draws, on held-out text. Errors from the Student
  and from the generator's on-device implementation add in power, so both must
  clear 50 dB with margin. The generator alone measured 42.05 dB on SM8550 from
  captured decoder output (`generator-whole-sm8550-20261008.md`).
- Measure how error in `x` and `f0` propagates to PCM by adding noise of known
  level to the stock decoder output and running the generator; this converts
  boundary dB into output dB.
- Learning stays separable where the boundary allows it: prosody (durations
  and `f0`), voice, and phonetic content of `x`, each corrected against its own
  error.
- Throughput: seconds of speech trained per second of wall-clock time.
- Utterances have arbitrary length. With the generator's weights resident
  (see Generator implementation), each time tile runs through every layer in
  turn and audio is produced from the first tiles onward; each convolution
  carries its left context from one tile to the next. The Student supplies
  each AdaIN site's scale and bias, which removes the generator's only
  whole-utterance dependency (`nn.InstanceNorm1d` over the full time axis in
  `AdaIN1d`). The current `Speak` limit of
  96 decoder frames (2.4 s) is a test point, not a design limit.

### Training stages

The Student is trained in stages. Each stage has a gate on held-out text; the
next stage starts only when the gate passes, and every earlier gate remains a
regression check, so a change that improves a later stage and breaks an
earlier one is rejected. Gate thresholds are set by measurement when each stage
is reached.

| Stage | Learns | Evidence | Gate |
| --- | --- | --- | --- |
| 1. Sound inventory | Phone percepts; `af_heart`'s voice record and AdaIN `base` | Short windows | Each phone's stretch of `x`, and the generator PCM it produces |
| 2. Words | Word percepts; sequence edges | Short windows | Held-out words assembled from percepts |
| 3. Phrases | Containment edges; phrase closures; duration and `f0` contours | Medium windows | Held-out phrases |
| 4. Long-range context | Closures at any distance, across paragraphs and sections, with lifetimes, expiry and reopening; prosody-rulebook candidate types; counter-examples | Windows up to 510 phonemes and long-horizon sources | Held-out paragraphs; closure expiry and reopening rates |
| 5. Consolidation | Merge, split, prune and lay out; training against the on-device generator | All earlier evidence | Same SNR with fewer percepts and lower production cost |
| 6. Extension | A second voice, further teachers, listening mode | New teacher adapters | Each new gate passes without an earlier gate regressing |

Plasticity is scheduled: early stages admit new types and edges readily;
later stages require more held-out support for a change, so learned behaviour
stays stable. Consolidation runs between stages. Reliance on the teacher
narrows as stages advance: stages 1 to 3 learn local sound from Kokoro, stage 4
carries context beyond the teacher's window, and stage 6 corrects the teacher
where other evidence shows it wrong.

### Amortization

Each cost is paid at the earliest point that allows it:

| Paid | Work | Removed from the audio-rate path |
| --- | --- | --- |
| Build | Weights quantized, Snake α and quantization scales folded, laid out in VTCM tiles; DSP kernels emitted with fused epilogues; noise constants generated; lexicon and learned pronunciations compiled into the phonemizer; host code precompiled | Weight conversion, per-value Snake work, lexicon search, startup compilation |
| Application start | FastRPC session and queue opened once; resident weights loaded into VTCM once | Session setup and weight streaming per utterance |
| Voice selected | The voice record and each AdaIN site's `base` and `P` | AdaIN `fc` layers and whole-utterance moments |
| Text arrives | Phonemizer and Student run ahead on the CPU, pipelined with the DSP | Waiting for whole sentences or utterances |
| Control event | The DSP expands control state into coefficients | Host traffic per tick |
| Tick | Generator convolutions only, depth-first in VTCM | |

Across utterances, frequently used percepts keep their produced output keyed
by type and context, and the DSP's phase and noise counters persist. Time to
first audio is the first token's controller state plus one generator tile.

Development is amortized the same way, so the training loop stays fast:
teacher evidence is computed once, filed by type and cached by phoneme
content; Zira captures are cached by text; the propagation measurement lets
most experiments be scored from boundary error without running the
generator; a host emulator of the quantized generator, bit-exact with the
DSP, lets the Student train against device behaviour without the phone; and
every baseline (emission hashes, SNRs, timings) is kept as a record.

### Generator implementation on Hexagon

Kokoro's generator is kept. The work is to run it more accurately and with less
memory traffic. Quantities below are computed from the pinned checkpoint's
generator tensors and the generator's rates (input 80 per second; stage 0 at
256 channels and 800 per second; stage 1 at 128 channels and 4,800 per second;
24 kHz output); none is a phone measurement.

| Part | Conv parameters | Work per second of audio |
| --- | ---: | ---: |
| `ups.0` (transposed, 512 to 256) | 2,621,440 | 0.21 GMAC |
| Stage 0: `resblocks.0-2`, `noise_res.0`, `noise_convs.0` | 11,077,632 | 8.86 GMAC |
| `ups.1` (transposed, 256 to 128) | 393,216 | 0.31 GMAC |
| Stage 1: `resblocks.3-5`, `noise_res.1`, `noise_convs.1`, `conv_post` | 3,168,256 | 15.21 GMAC |
| Total | 17,260,553 | 24.6 GMAC |

AdaIN `fc` layers (2,377,728 parameters) do not run; each AdaIN site's scale
and bias is expanded from the Student's controller state. Weight-norm gains and
biases are folded into the stored weights.

Memory traffic:

- Weights for one full pass: 34.5 MB at 16 bits (int16, fp16 or two int8
  planes), 17.3 MB at 8 bits, about 9.7 MB at 4 bits with one scale per 32
  weights. At the measured 37 to 55 GB/s DDR-to-VTCM DMA
  (`dma-copy-sm8550-sm8635-20261007.md`) one 16-bit pass takes 0.63 to 0.93 ms.
- Activations, when each layer runs over a whole span: one 16-bit tensor is
  0.41 MB per second of audio in stage 0 and 1.23 MB in stage 1. Writing and
  re-reading every convolution's output costs about 80 MB per second of audio,
  roughly 60 MB of it in stage 1. For utterances longer than about one second
  this exceeds the weight traffic.
- Activation traffic disappears when a tile runs through consecutive layers
  while staying in VTCM (depth-first execution), which requires those layers'
  weights to be resident.
- With the weights resident and the source on the VTCM loop, memory traffic
  is basically zero: PCM is drained by DMA to AAudio.

Plan:

1. Goal: all generator weights resident in VTCM, no weight streaming, and the
   whole generator run depth-first so activations stay in VTCM. Budget: 8 MiB
   of VTCM less about 1.5 MB of per-layer context buffers for depth-first tiles
   leaves about 6.9 MB, or about 3.2 bits per weight on average across
   17,260,553 weights. Generator accuracy at 4 bits has not been measured; the
   4-bit results in `decoder-weight-bits.md` are for the stock decoder, which
   the Student replaces, and do not predict the generator. Residency depends
   on the measurement below: the lowest average bits per weight that holds
   generator PCM at 55 dB, using items 3, 4, 6 and 8.
   The source branch (`noise_convs`, `noise_res`, `m_source`; 3,904,265
   weights) depends only on `f0` and the voice, never on `x`. It runs on the
   DSP from the VTCM phase loop and seeded noise counters (items 4 and 5), so
   `x_source` is never transferred; its weights count against the residency
   budget.
   Stage 0 and `ups.0` hold 13.7 million of the weights and run at the lower
   rate; stage 1 holds 3.2 million and carries most of the work and accuracy
   loss, so precision is assigned per layer from measured sensitivity.
2. Fuse each convolution's epilogue while the data is in HVX registers or HMX
   accumulators: bias, Lock, residual add, the resblock average and
   `x + x_source`. Lock replaces Snake: displacement from an operating point
   set through the AdaIN scale and bias, reflection at the shape's turning
   points, a clamp and a bounded multiply-add correction, with no per-value
   sine. The Student makes this easier: Snake is `z + sin²(αz)/α` with one α
   per channel, and every Snake reads an AdaIN output whose coefficients the
   Student supplies. Folding α into that site's scale and bias and 1/α into
   the next convolution's input-channel weights is exact and leaves one
   parameter-free function, `y + sin²(y)`, for every channel of every site.
   No sine table is needed: with the generator weights resident in VTCM,
   phase locks to the generator's fixed cadence (5, 6, 10 and 300), and the
   Student supplies a stateful stream in place of AdaIN, so no sine has to be
   computed. Registers hold element-wise steps;
   VTCM holds data between convolutions, which need neighboring positions and
   all channels.
3. Keep the residual stream and all phase state resident in VTCM at full
   precision (int32 fixed point or fp32), including the Lock operating points. Hypothesis to test: stage 1 loses most accuracy today
   (10x half alone 58.56 dB, 60x half plus tail 42.71 dB, whole generator
   42.05 dB), and full-precision residual and phase state recovers part of it.
4. Harmonic phase is an integer position locked to the generator's cadence,
   not a pointer into a sine table. Advancing by frequency
   is an integer add and wraps exactly, so precision does not decay with
   utterance length, unlike Kokoro's `cumsum` phase in `SineGen`. Harmonic k
   advances at k times the same position, so harmonics stay locked. The comparison
   reference uses the same exact phase, labeled as a difference from stock.
5. Generate the source's noise on the DSP ourselves, not through Kokoro's
   sampling, using
   counter-based random numbers (for example Philox): every draw is a function
   of a seed and a position, so tiles, spans and the offline reference produce
   identical noise. The hardware random number generator
   supplies one seed per utterance, and the seed is logged so any utterance
   can be reproduced and checked against stock. Gaussian values come from
   integer operations (sums of uniforms or a polynomial inverse CDF), not trig
   lookups; the offline reference uses the same transform.
6. Quantize with error-compensating rounding calibrated on generator
   activations, per-output-channel scales, bias correction, and per-layer
   precision chosen by measured sensitivity, including precisions below 4
   bits. At each activation requantization point, carry the rounding error
   and subtract it from the next position's value before rounding (first-order
   error feedback, one running value per channel in VTCM); keep it only in
   layers where whole-generator PCM SNR rises. Measure how much of each
   quantized run's PCM error is per-harmonic phase drift that exact phase
   (items 3 and 4) removes; that share sets how far weights can drop.
7. Keep the existing polyphase form of the transposed convolutions so no
   multiplies are spent on inserted zeros.
8. The Student learns against the on-device generator (its quantized weights
   and resident state), not against the stock generator, so what it supplies
   can compensate for the generator's implementation error. Its levers are
   every generator input it provides: `x`, `f0`, the scale and bias of each AdaIN site (a
   per-channel correction at every normalization point), the Lock operating
   points and phase state, and the noise seed.

How the Student eases residency, each kept only if end-to-end PCM SNR holds:

- Per-output-channel quantization scales cost nothing at run time: each
  scale folds exactly into the next AdaIN site's coefficients, which the
  Student supplies.
- Trained against the quantized generator (item 8), the Student compensates
  part of the quantization error through every input it supplies, so lower
  precisions become usable.
- Channels whose contribution the Student's coefficients can carry are
  candidates for removal, measured per channel and per site.
- One resident weight set serves every voice; a voice is its record and its
  AdaIN `base` and `P`.

Error budget: generator PCM above 50 dB against stock overall. Measured
separately, with the Student fed stock decoder output, the generator
implementation would need about 55 dB. Trained against the on-device
generator, the Student cancels part of the implementation error, so the
quantization target is set by the end-to-end result, not by the generator
alone. Every change above is kept only if end-to-end PCM SNR does not drop.

## v2: long-horizon control and generator replacement

Not current work. The generator's weight size is re-evaluated once v1 is
complete. When v1 holds its results and the generator can be dismantled, the
v1 Student becomes the v2 Student; it is not rebuilt.

- Long-horizon control: v1's control stream (Output streams) extended over
  long spans (phonetic targets, timing, pitch movement, emphasis). v1's work
  carries over unchanged: the control stream drives the v2 instrument as it
  drives the generator's AdaIN sites, the per-voice records and sensitivities
  carry over, and the VTCM phase loop serves both the generator and the
  instrument.
- Listening mode: the Student also maps audio back to the same symbolic event
  stream it plays, not to stored units: phone onsets and offsets, pitch as a
  continuous pitch-bend control, emphasis as velocity, and the other controls
  as controller changes. Speaking turns events into audio; listening turns
  audio into events. Teacher renders are labelled audio (Kokoro's per-token
  durations, Zira's per-phone timing), so listening trains on the same
  evidence. Uses: resolving pronunciation disagreements by what was actually
  spoken, and checking the Student's own output against the events it
  intended.
- The event stream is the MIDI 2.0 Universal MIDI Packet format with
  speech-specific extensions: phones as per-note events, F0 as per-note
  pitch bend, emphasis as velocity, other controls as per-note controllers.
  It is not specific to speech, so the same Student may later produce a
  procedural first pass for music tracks.
- The instrument is Hexagon-resident and takes the event stream as input:
  the DSP decodes Universal MIDI Packets into per-channel and per-note state
  held in VTCM (phase, resonances, envelopes, loop state). Events update that
  state; between events the instrument runs without host traffic. Each
  note's phase is an integer position on the VTCM loop, stepped by its pitch
  including per-note pitch bend; harmonics advance at integer multiples of
  the same position and stay locked.
- The instrument simulates air in three dimensions: pressure and particle
  velocity on sparse voxels covering only the air volume, with a
  low-dispersion scheme so coarse voxels stay accurate, plus steady flow.
  Vocal folds and lips are moving walls driven by the pressure and flow
  interaction; tubes, mouth, bore and bell are the shape of the confined air;
  fricatives and breath are turbulence where flow accelerates through a
  constriction; radiation is air leaving the opening. Each source (speech,
  brass, other voices) is a build: geometry, dimensions and excitation
  settings, calibrated once against acoustics. The voxel model's accuracy is
  checked against the resonances of known three-dimensional shapes before
  use. A one-dimensional tube model (plane waves with side branches) is kept
  as the calibration baseline and as the fallback where the GPU is not
  available.
- Processor split, to be measured on the phone (power and latency) before it
  is adopted. Work coupled at the simulation step stays on one processor;
  only boundaries cross between processors, at block rate (a few hundred
  exchanges per second):
  - GPU (Vulkan compute, SPIR-V emitted by PowerShell; fragment-shader
    ping-pong as a fallback): the air, as sparse three-dimensional voxels
    where needed, and the radiated output at the lips.
  - Hexagon: MIDI 2.0 event decoding, articulator dynamics and geometry,
    the Student's learned parts on HMX, and the vibrating source (folds or
    lips) at full rate.
  - Hexagon sends the GPU the instrument's boundary (geometry and the
    source flow of the last block); the GPU returns the air's reflection
    function at the source boundary for the current geometry, from which the
    source computes its boundary pressure locally (exact for linear air;
    turbulence at the source stays with the source).
  - Offline fluid simulation (lattice Boltzmann) calibrates the source and
    turbulence models; it does not run in real time.
- Generator replacement: a fixed acoustic instrument with no learned values
  (excitation, resonances on the resident loop, built-in stop, fricative and
  nasal techniques, prosody-driven timing), played by the Student. Phase
  alignment and mixing come from superposition on the loop. Replacement is
  incremental: Kokoro's generator stays resident and keeps producing speech
  while its parts are replaced one at a time, starting with the source branch
  (already on the VTCM loop and seeded noise in v1). Each replaced part is driven by the same
  control stream, and a replacement is kept only if end-to-end quality holds
  against the resident generator. The goal is natural human voice produced
  procedurally, with no learned generator weights.
- Knowledge transfer from simulation: the physical instrument is also a
  teacher. The Student learns reusable control programs from its responses,
  including excitation, resonance, transitions and their dependence on
  context. Consolidation may replace repeated simulation work with a cheaper
  typed program where measured acoustic fidelity and responses to controls
  hold. Percepts retain how to produce an effect, rather than recordings of
  the effect. The physical model remains available for calibration and for
  behaviours the learned programs do not yet reproduce. This is a proposed
  transfer mechanism, not a measured replacement: compare the original and
  replacement under the same controls, including transitions and contexts
  excluded from fitting, and measure production cost before adopting it.
  Learned behaviour belongs to the Student; the physical instrument retains
  its explicit acoustic equations and has no learned generator weights.
- Playback binding: keep the percept's intent, the mechanism producing sound
  and the playback device's response distinct. Phone and computer speakers
  are renderer bindings with measured transducer responses; their calibration
  does not change the percept's meaning. Evaluate transferred behaviour both
  at the generated audio boundary and through the intended playback device.
  A faithful simulated source may be replaced by another mechanism that
  preserves its acoustic effect and control response within that device's
  reproducible range. Simulation does not remove the physical speaker's
  bandwidth, output-level or spatial limits.
- Input: a 16-bit token of phonetic features from our phonemizer.
- Evaluation: Kokoro's self-distance across random seeds (Kokoro draws random
  harmonic start phases and noise on every run), measured at the audio output.
- Output at 48 kHz. Kokoro's 24 kHz output covers 0 to 12 kHz; the band above
  is checked against published speech acoustics.
