# Kokoro-Hexagon implementation plan

This is the canonical execution plan. Measurements and historical detail belong
in `docs/receipts/`; this file defines the product boundary, ordered gates, and
the evidence required to advance them.

## Product

Kokoro-Hexagon is a portable, PowerShell-lowered speech model delivered as a
literal weight-bearing managed assembly, with platform-specific execution and
audio backends:

```text
admitted text
  -> normalization, phonemes, stress and chunk state
  -> model controls and specialization selection
  -> Kokoro-Hexagon.dll
       -> Windows reference backend -> WASAPI
       -> Android appliance backend -> HTP/Hexagon -> AAudio
       -> Windows controller -> resident Android compute backend -> WASAPI or AAudio
```

`model.ps1` is the auditable model and control source. PowerShell parses,
validates, and lowers it before release. Each `Kokoro-Hexagon.dll` variant
contains its own serialized, indexed weight blob, admitted text pipeline,
typed streaming API, graph identity, control schema, specialization map, and
integrity metadata. The pinned checkpoint is converted once into a safe,
versioned tensor source pack; routine PowerShell builds consume that pack, not
the checkpoint serializer. PowerShell emits both the managed model assembly and
our target-specific DSP ELF binaries. Independent assemblers and existing graph
runtimes may verify or temporarily execute blocks that have not passed direct
lowering; they are not the production emitter. The phone's required system
runtime remains a platform dependency. No executable payload is fetched or
generated during ordinary inference.

The ordinary user path is turnkey: with PowerShell 7, obtain a verified release,
load one model DLL, select a compute backend and audio sink, and stream text.
The Windows reference backend must eventually make this possible without a
phone; the Windows-controlled phone is the primary accelerated demonstration.
The APK is a minimal resident backend. A source user must be able to reproduce
a variant with one documented `setup-kokoro.ps1` command. The script reuses the
proven `C:\Dev\pwsh\setup.ps1` facade and write-plan discipline where
applicable, but exposes only Kokoro's required steps. Routine source builds and
the appliance require PowerShell 7, pinned inputs, and the declared platform
runtime; they do not require a separate model compiler. The release contains
ordinary managed IL and PowerShell-emitted DSP payloads. Developer JIT is an
opt-in source-build/test workflow over that IL, not a separate runtime artifact
format.

The model variants are separate artifacts, not one process-resident collection:
FP32 is the numerical reference; FP16 and INT8 are admitted only after
per-layer, speech-quality, memory, and end-to-end timing gates. Each variant
has its own embedded weight hash and release identity. Load one variant at a
time on a memory-constrained device.

### Build methodology

The maintainer first admits a pinned tensor source pack against the original
checkpoint and independent numerical/audio references. That conversion is a
separate, recorded provenance step, not a requirement for a release user or a
routine source rebuild. Thereafter `setup-kokoro.ps1` uses PowerShell 7 and
pinned source data to validate the model AST, specialize and lower its graph,
pack the selected weights into the managed assembly, emit required DSP ELF
code, and run differential gates. The documented clean build must not require
a model framework or separate language toolchain. Validated text processing,
control, scheduling, and kernel dispatch move into the assembly rather than
remaining interpreted work on the speech hot path.

## Permanent ratchets

These results are already established and must not regress silently:

1. **Portable managed identity.** The source build emits a 15,360-byte
   `Kokoro-Hexagon.dll` that loads in Windows PowerShell before Android setup.
   Its persisted graph hash matches an independent lowering of `model.ps1`.
   Receipt: `docs/receipts/model-assembly-windows-20260924.md`.
2. **Model-aware V73 code generation.** The lowered R0Sub0 elementwise graph
   uses an eight-lane, 30-register HVX schedule. In counterbalanced physical
   runs it was bit-exact with the pinned gold and LLVM outputs and measured
   2.213x to 2.256x the LLVM implementation's DSP-tick performance for this
   kernel. Receipt: `docs/receipts/r0sub0-lowered-vs-llvm-20260924.md`.
3. **Audio sinks.** Persistent Android AAudio playback at 24 kHz mono float has
   completed consecutive chunks without an observed underrun in its recorded
   scope. QuickPS contains a pinned direct WASAPI binding for the Windows
   reference backend.
4. **DSP substrates.** Direct HVX emission is checked byte-for-byte by the
   pinned Qualcomm assembler oracle. HMX W4A8 instruction and layout probes have
   exact device readback; they do not yet constitute a quantized Kokoro model.
5. **Warm graph execution.** Capacity-specific QNN contexts and a bounded audio
   queue can remain resident across prepared phrase fixtures. Arbitrary text is
   not yet connected to that warm path.

Every performance change must keep output/quality gates, independent encoder
verification, and the applicable physical-device ratchet. Beating one LLVM
kernel is a compiler result for that specialization, not a claim about LLVM in
general or complete speech synthesis.

## Gate 1: text and phoneme admission

This is the current gate. The DLL currently begins at acoustic tensors; it is
not yet a complete text-to-speech model surface.

SMA is the parser and compiler front end for authored PowerShell pronunciation
rules, not a pronunciation oracle for arbitrary prose. The speech input is
tokenized as data. Only a bounded, validated rule AST may be lowered into the
DLL; user text is never parsed or executed as PowerShell. Reuse JS2PS's
separation of syntax admission from semantic conformance, ChangeModel's
measured mismatch/held-out representation tests, and Pwsh's persisted managed
assembly emission patterns. Each borrowed pattern needs a Kokoro-specific gate.

### Work

1. Define a versioned text contract covering Unicode normalization, numbers,
   abbreviations, punctuation, quotations, cue cards, language selection,
   speaker/voice turns, and explicit pronunciation overrides.
2. Pin three independent references:
   - the exact Kokoro source revision and vocabulary used by the model;
   - the existing pinned host phonemizer as the pronunciation oracle;
   - the supplied TypeScript parser as a second implementation reference,
     after source review rather than direct adoption.
   Use the pinned Kokoro vocabulary to test emitted IDs, not SMA parse success
   as a proxy for pronunciation correctness.
3. Build a machine-readable differential corpus from:
   - narrative excerpts for continuity and dialogue;
   - technical prose for numbers, symbols, abbreviations, and code-adjacent
     language;
   - lyrics for meter, contractions, repetition, and line boundaries.
   Source text remains outside generated artifacts unless its inclusion is
   explicitly intended and licensed.
4. Implement the admitted normalizer and phoneme/ID pipeline in portable
   managed logic. Preserve source spans and distinguish authored text, spoken
   text, phonemes, model IDs, and nonverbal cue cards.
5. Carry bounded continuation state between chunks: unfinished punctuation,
   quotation/dialogue state, speaker/voice, pronunciation override scope, and
   boundary strength. A cut may not occur inside a normalized token or phoneme.
6. Differentially test every corpus case. Store expected outputs and compact
   mismatch categories, not an opaque pass/fail total. Add held-out heteronym,
   morphology, and chunk-boundary pairs before admitting a new context feature.
7. Persist the validated methods and their contract/version hashes into
   `Kokoro-Hexagon.dll`. Loading the DLL on Windows must be sufficient to
   normalize, phonemize, produce IDs, and plan chunks without Android, a model
   framework, or a network connection.

### Exit gate

- All admitted corpus cases match the pinned oracle or carry an explicit,
  reviewed model-specific exception.
- Re-running a chunked passage produces the same normalized text and phoneme ID
  stream as an unchunked pass, except for declared boundary events.
- Invalid Unicode, excessive input, unknown cue cards, and unsupported language
  fail closed with bounded allocation.
- A Windows test loads only the release assembly and its declared data resources
  and reproduces the corpus hashes.

## Gate 2: portable streaming API and Windows proof

Define one small public surface; platform details stay behind backend bindings.
The target shape is conceptually:

```text
Load(dll, variant) -> model
Plan(text, voice, controls, continuation) -> chunks
Open(computeBackend, audioSink) -> session
session.Write(chunk) -> timing and quality receipt
session.Complete()
```

### Work

1. Persist typed request, chunk, continuation, control, and receipt shapes in the
   assembly. Do not expose internal graph tensor names as the stable user API.
2. Pack the pinned tensor source into a deterministic blob with explicit
   tensor names, shapes, dtypes, offsets, alignment, and hashes. Embed that blob
   in the variant DLL; verify every range and hash before use. Measure assembly
   load, blob access, and peak memory so the embedding does not silently create
   a second full-weight copy. The released path never opens the source checkpoint.
3. Keep compute and audio selection independent: Windows reference or resident
   phone compute; WASAPI, AAudio, or caller-owned PCM output. Unsupported
   combinations fail explicitly. The transport is an adapter, not model logic.
4. Bind the pinned QuickPS WASAPI mechanism as the Windows audio sink. Preserve
   its COM ownership, buffer, format, and deterministic disposal contracts.
5. Provide a Windows reference execution mode for correctness and listening.
   It may be slower than Android, but it must consume the same plan and return
   the same control and artifact identities.
6. Add a minimal `Speak-Kokoro.ps1` driver that loads the assembly, selects a
   variant, voice, compute backend, and audio sink, streams text, and prints a
   compact receipt.
7. Keep model load, text planning, synthesis, queuing, presentation, and drain
   timings separate.

### Exit gate

- A clean Windows process loads the release bundle, plans arbitrary admitted
  text, plays multiple chunks through WASAPI, and disposes all native resources.
- The same input plan is accepted without translation by the Android backend.
- Repeated calls reuse the model session; no per-chunk runspace or model reload
  is permitted.
- The source checkpoint is absent from the runtime environment. The embedded
  blob matches its build manifest and loads within a measured memory budget.

## Gate 3: real long-form Android stream

Replace prepared phrase fixtures with output from the admitted text path while
keeping contexts, buffers, and audio resident.

### Work

1. Select capacity buckets from planned phoneme/duration demand. Do not allocate
   every bucket or the full passage at once.
2. Keep QNN libraries, contexts, tensor metadata, voice tables, reusable arenas,
   and one AAudio stream resident for the session.
3. Use a bounded producer/consumer pipeline. While AAudio presents chunk `n`,
   prepare chunk `n+1`; retain at most the configured look-ahead so long text
   cannot accumulate PCM in unified memory.
4. Carry acoustic boundary state where the model supports it. Measure crossfade
   or overlap only as an explicit candidate; do not conceal discontinuity with
   unmeasured post-processing.
5. Exercise narrative, technical, and metered passages, including speaker
   changes and cue cards.

### Exit gate

- One physical-phone session speaks each long-form lane without reloading the
  runspace, model, contexts, or audio stream.
- The receipt records cold and warm time to first audio, per-chunk readiness,
  inter-chunk audible gap, sustained real-time factor, underruns, peak resident
  memory, managed memory, and completion/drain state.
- The phone speaker audibly plays valid PCM; automated tensor success alone is
  insufficient.

## Gate 4: control discovery and lowering

The public controls must be derived from causal probes, not names that merely
sound plausible.

Current internal boundaries are `asr`, `F0_curve`, `N`, `style`, `gb`, `har8`,
`mask`, `mask8`, and `capacity`. They are not independent public knobs:

- `style` and the precomputed AdaIN `gb` table are coupled.
- `F0_curve` and the harmonic source represented by `har8` are coupled.
- masks, valid duration, bucket capacity, and output length are coupled.
- `N` is an internal predicted contour until a controlled probe establishes a
  stable perceptual interpretation.

### Work

1. Establish a neutral baseline phrase and voice, then vary one coherent control
   family at a time.
2. Record tensor deltas, audio hashes, duration, F0 statistics, loudness, quality
   against the reference path, and a human listening note.
3. Admit only controls that are monotonic or otherwise repeatable over multiple
   phrases and both pinned voices.
4. Convert stable controls into explicit `model.ps1` inputs. Bake fixed choices
   into specialization constants when they improve code generation and do not
   need to vary per chunk.
5. Lower speaker tables and frequent control combinations once their hashes and
   behavior are stable.

### Exit gate

A versioned public control schema maps every admitted control to traced model
inputs, legal ranges, coupling rules, and physical receipts. The same request
has equivalent semantics on Windows and Android.

## Gate 5: systematic Hexagon lowering

Generalize the R0Sub0 result from a successful specialization into a compiler
path used across the model.

### Work

1. Extract reusable DAG liveness, register allocation, lane-count selection,
   scheduling, tail handling, and legality checks from the R0Sub0 backend.
2. Make schedule selection deterministic from graph, shape, target, and control
   constants. Include the schedule identity in artifact hashes.
3. Lower elementwise/fusion islands to HVX and convolution/matrix tiles to the
   appropriate HVX/HMX path. Use all available registers when liveness and ABI
   constraints justify it; register occupancy is a resource, not a goal by
   itself.
4. Pass real dynamic voice/style parameters through the optimized path without
   reverting to tensor materialization between fusible operations.
5. Evaluate packed FP16 and then int8/W4A8 at operator and block boundaries.
   Quantized promotion requires declared error bounds, audio-quality gates, and
   an end-to-end latency/memory win. Hardware instruction support alone is not
   admission.
6. Cache build artifacts by source graph, weight, target, schedule, and tool
   hashes. Runtime compilation or downloaded executable code is not the product
   mechanism.

### Exit gate

- Each promoted block matches its previous fp32/declared-error reference on the
  physical device.
- Inclusive measurements include packing, copies, synchronization, and
  transport.
- The complete generator improves warm synthesis and/or memory without
  regressing speech quality or the established R0Sub0 ratchet.

## Gate 6: appliance and transport

The Android appliance is a resident backend for the model DLL, not the model's
identity and not the user's scripting environment.

1. Keep the NativeActivity/CoreCLR host minimal and typed. Remove recovery UI
   and unused managed assemblies only after the streaming path is stable.
2. Replace host-script staging with signed, fixed release resources and a typed
   local request pipe. AOA can expose the same protocol to a Windows controller.
3. Treat FastRPC as the measured supported CDSP boundary unless pinned source,
   specification, or a documented probe proves a safe lower route. Keep its
   setup out of per-chunk timing by maintaining a resident session.
4. Read embedded weights without a second full-model copy. Record proportional
   set size and peak resident memory during cold load and long-form use. Any
   temporary prepared context remains separately measured until its graph is
   replaced by a validated PowerShell-emitted DSP implementation.
5. Keep the appliance a fixed native host with a typed managed entry point;
   do not compile managed or DSP code during ordinary inference.

Exit: the signed APK installs, accepts the typed model protocol, speaks a warm
stream, survives repeated sessions and cancellation, restores/cleans temporary
state, and reports its exact component hashes.

## Gate 7: release exemplar

Publish reproducible, separately selectable model variants suitable for Hugging
Face and GitHub:

- one weight-bearing `Kokoro-Hexagon.dll` per admitted precision;
- PowerShell-emitted DSP ELF payloads for the admitted Android specializations;
- manifest with source revisions, licenses, sizes, and SHA-256 values;
- minimal Windows and Android/AOA drivers;
- PowerShell 7 quick start and one-command source build/verification instructions;
- counterbalanced performance and speaker receipts with narrow claim language;
- an SBOM and signed release artifacts.

The release page must distinguish the stock pinned Kokoro weights from any
future trained, FiLM-modified, or quantized checkpoint. A separate model identity
is created only when weights or architecture actually change.

### Developer source/JIT path

`setup-kokoro.ps1` is the single documented entry point for source users. It
reuses the existing PowerShell setup facade's pinned-input, preview/write-plan,
and resumable-step patterns, while retaining only steps required by this model.
The documented developer command must validate `model.ps1` and the pinned
tensor source pack, lower the selected graph and weight precision through
PowerShell, emit ordinary managed IL and target DSP ELF, run independent
numerical and corpus checks, and
either test that IL under the installed PowerShell 7 runtime or persist the
same release-shaped DLL. Developer JIT does not alter model semantics or bypass
admission gates. The default user command does none of this build work.

Exit: a clean PowerShell 7 user can invoke a verified variant with a short
documented command; a developer can rebuild it with one setup command and
reproduce its graph, weight, and corpus identities. The source-run and
prebuilt-assembly paths return equivalent outputs on the same backend.

## Work order

Do not run these tracks as competing prototypes. The order is:

1. Phoneme differential corpus and portable text pipeline.
2. Persist text/phoneme methods into the DLL and prove them on Windows.
3. Embed and validate one weight variant; measure DLL load and memory on both
   platforms before multiplying variants.
4. Minimal DLL driver plus QuickPS WASAPI playback.
5. Feed those plans into the existing warm Android pipeline and obtain a
   long-form speaker receipt.
6. Generalize the successful HVX scheduler and lower the next expensive model
   blocks, using physical A/B gates after each promotion.
7. Reduce appliance/runtime payload and harden lifecycle behavior.
8. Prove the Windows-controlled phone path with framed requests and inclusive
   transport, compute, and audio timing; do not claim remote general compute
   before that round trip exists.
9. Package and publish the reproducible variants and source-build instructions.

## Change discipline

- Generated models, contexts, DLLs, audio, logs, APKs, and raw device receipts
  remain in the adjacent Build directory. Only compact reviewed receipts enter
  `docs/receipts/`.
- Every external input is pinned and hashed. Every graph passes the export gate.
  Every optimization is checked against its predecessor before promotion.
- Capability claims require an applicable device or platform receipt. Audible
  completion requires actual speaker playback.
- No runtime eval of input, runtime compiler dependency, silent network fetch,
  or unbounded text/audio queue enters the product path.
- Commit and push coherent hills only after their tests and evidence gates pass.

## Immediate deliverable

Build the phoneme differential corpus and a portable PowerShell/managed text
pipeline whose normalized text, phonemes, model IDs, source spans, and chunk
continuation state can be persisted into and reproduced from
`Kokoro-Hexagon.dll` on Windows. This is the only active product gate until its
admission tests pass.
