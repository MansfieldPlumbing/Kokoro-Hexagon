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

The Student's source is `student/Invoke-Student.ps1`, reached through
`Invoke-KokoroDevelopment.ps1 Student`. Extend that owner.

This document describes two designs. v1 is current work. v2 follows v1 and is
not current work. The Student is being rebuilt; these names are unrelated to
earlier StudentV2 work.

## v1: the Student at the generator boundary

### Boundary

The Student replaces everything in Kokoro up to and including the decoder and
supplies the frozen generator's inputs, `Generator.forward(x, s, f0)` in
upstream `kokoro/istftnet.py`:

| Input | Shape | Rate |
| --- | --- | --- |
| `x` | 512 channels | one vector per generator tick (300 samples at 24 kHz, 80 per second) |
| `f0` | 1 value | one per tick; zero is unvoiced |
| `s` | 128 values | per utterance: `ref_s[:, :128]`, the voice-pack row selected by phoneme count (`pipeline.py`: `pack[len(ps)-1]`) |

Kokoro components the Student replaces: PL-BERT and `bert_encoder`, the
duration predictor, the F0 and N predictor (`F0Ntrain`), the text encoder, the
alignment, and the decoder (`encode`, four `decode` blocks, `F0_conv`,
`N_conv`, `asr_res`). N fed only the decoder and is not produced.

Paths into the generator that matter for accuracy:

- `f0` bypasses the decoder. Inside the generator it builds the harmonic and
  noise source, whose STFT is added at every upsampling stage (`noise_convs`,
  `noise_res`). Errors in `f0` reach every stage.
- `s` drives AdaIN in every generator resblock and source block.
- Token identity reaches the generator only through `x`.

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

### Voices

The Student learns several voices and switches between them. Storage differs
from Kokoro, where each voice is 510 rows of 256 values used through the
predictors and decoder on every utterance:

- Percepts are shared across voices and trained on all voices' teacher output.
- Each voice is a record:
  - the generator style rows (`ref_s[:, :128]`), or a smaller representation if
    they vary smoothly with phoneme count;
  - a transform of `x` across all 512 channels (per-channel scale and bias plus a
    residual), since the decoder imposed the voice on `x` largely through AdaIN;
  - prosody style (timing and pitch behavior), which replaces the role of
    `ref_s[:, 128:]` in the removed predictors.
- Switching voices replaces the record. Blending records is possible.

Measure before building: the fraction of the difference in `x` between voices
explained by a per-channel scale and bias, and how smoothly each voice's
`s` rows vary with phoneme count.

### Teachers are adapters

The Student's core is teacher-neutral: typed layers, closures, pronunciation,
and prosody behaviours in physical units (durations in seconds, pitch in hertz,
energy, emphasis). Nothing in the core refers to a teacher's frames, token IDs
or channels. Each teacher has an adapter that converts its evidence into those
units and binds the Student's neutral output to its renderer's input (for
Kokoro: `x`, `f0` and the style row). Only the renderer binding is
teacher-specific and is retrained per teacher. Evidence records which teacher
produced it, so evidence from several teachers for the same typed objects
coexists. A later teacher (for example Chatterbox Turbo) is added as a lowered
port and an adapter, specified from its source at a pinned commit, without
changing the core.

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
  `AdaIN1d`). Until residency is reached, the generator runs layer by layer
  over spans with weights loaded once per span. The current `Speak` limit of
  96 decoder frames (2.4 s) is a test point, not a design limit.

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

AdaIN `fc` layers (2,377,728 parameters) do not run on the DSP; the front end
computes each AdaIN site's scale and bias from `s`. Weight-norm gains and
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
   weights) depends only on `f0` and the voice, never on `x`, so it runs off
   the DSP: the CPU front end or the Student supplies `x_source` for both
   stages (about 1.6 MB per second of audio). The remaining 13,356,288 weights
   take 6.68 MB at 4 bits with one scale per output channel, within the
   budget (about 4.1 bits per weight on average).
   Stage 0 and `ups.0` hold 13.7 million of the weights and run at the lower
   rate; stage 1 holds 3.2 million and carries most of the work and accuracy
   loss, so precision is assigned per layer from measured sensitivity.
2. Fuse each convolution's epilogue while the data is in HVX registers or HMX
   accumulators: bias, Lock, residual add, the resblock average and
   `x + x_source`. Lock replaces Snake: displacement from an operating point
   set through the AdaIN scale and bias, reflection at the shape's turning
   points, a clamp and a bounded multiply-add correction, with no per-value
   sine. Registers hold element-wise steps;
   VTCM holds data between convolutions, which need neighboring positions and
   all channels.
3. Keep the residual stream and all phase state resident in VTCM at full
   precision (int32 fixed point or fp32), including the Lock operating points. Hypothesis to test: stage 1 loses most accuracy today
   (10x half alone 58.56 dB, 60x half plus tail 42.71 dB, whole generator
   42.05 dB), and full-precision residual and phase state recovers part of it.
4. Harmonic phase is an integer pointer into a one-period sine table (a ring
   in VTCM when the source runs on Hexagon, about 8 KB for 4,096 fp16 entries;
   the same table in memory when it runs on the CPU). Advancing by frequency
   is an integer add and wraps exactly, so precision does not decay with
   utterance length, unlike Kokoro's `cumsum` phase in `SineGen`. Harmonic k
   reads at k times the pointer, so harmonics stay locked. Linear
   interpolation between entries keeps the error near 130 dB. The comparison
   reference uses the same exact phase, labeled as a difference from stock.
5. Compute the harmonic source from `f0` (off the DSP, item 1) using
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
   every generator input it provides: `x`, `f0`, `x_source` once the source
   branch runs off the DSP, the scale and bias of each AdaIN site (a
   per-channel correction at every normalization point), the Lock operating
   points and phase state, and the noise seed.

Error budget: generator PCM above 50 dB against stock overall. Measured
separately, with the Student fed stock decoder output, the generator
implementation would need about 55 dB. Trained against the on-device
generator, the Student cancels part of the implementation error, so the
quantization target is set by the end-to-end result, not by the generator
alone. Every change above is kept only if end-to-end PCM SNR does not drop.

## v2: long-horizon control and generator replacement

Not current work. The generator's weight size is re-evaluated once v1 is
complete.

- Long-horizon control: a low-rate control layer emits sparse events over long
  spans (phonetic targets, timing, pitch movement, emphasis); percepts expand
  them into the boundary values. Each event is the 96-bit state of an XInput
  dual-analog controller (16 button bits, two 8-bit triggers, four 16-bit stick
  axes). A person can drive it from a physical controller as a manual check
  that every required sound is reachable through the controls.
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
  note's phase is an integer pointer into a one-period sine table in VTCM,
  stepped by its pitch including per-note pitch bend; harmonics read at
  integer multiples of the same pointer and stay locked.
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
  alignment and mixing come from superposition on the loop.
- Input: a 16-bit token of phonetic features from our phonemizer.
- Evaluation: Kokoro's self-distance across random seeds (Kokoro draws random
  harmonic start phases and noise on every run), measured at the audio output.
- Output at 48 kHz. Kokoro's 24 kHz output covers 0 to 12 kHz; the band above
  is checked against published speech acoustics.
