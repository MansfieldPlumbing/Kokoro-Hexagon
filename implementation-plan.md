# Kokoro-Hexagon implementation plan

This is the canonical execution plan. Measurements and historical detail belong
in `docs/receipts/`; this file defines the product boundary, ordered gates, and
the evidence required to advance them.

## Product

Kokoro-Hexagon is a portable, ahead-of-time-lowered speech model with two
backends:

```text
admitted text
  -> normalization, phonemes, stress and chunk state
  -> model controls and specialization selection
  -> Kokoro-Hexagon.dll
       -> Windows reference backend -> WASAPI
       -> Android appliance backend -> HTP/Hexagon -> AAudio
```

`model.ps1` is the auditable model and control source. The build parses and
lowers it ahead of time. `Kokoro-Hexagon.dll` is the portable typed model
surface: it carries the admitted text pipeline, graph identity, control schema,
specialization map, and integrity metadata. Fixed weights, QNN contexts, and
native/DSP libraries are hash-pinned release resources. They are not generated
or downloaded as executable code at runtime.

The ordinary user path must be smaller than the development path: obtain a
signed release bundle, load the assembly, select a backend, and stream text. A
source user must be able to reproduce the assembly with one documented build
command. Python is allowed only in host-side export work when weights or graph
shapes change; it is not an appliance dependency.

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

### Work

1. Define a versioned text contract covering Unicode normalization, numbers,
   abbreviations, punctuation, quotations, cue cards, language selection,
   speaker/voice turns, and explicit pronunciation overrides.
2. Pin three independent references:
   - the exact Kokoro source revision and vocabulary used by the model;
   - the existing pinned host phonemizer as the pronunciation oracle;
   - the supplied TypeScript parser as a second implementation reference,
     after source review rather than direct adoption.
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
   mismatch categories, not an opaque pass/fail total.
7. Persist the validated methods and their contract/version hashes into
   `Kokoro-Hexagon.dll`. Loading the DLL on Windows must be sufficient to
   normalize, phonemize, produce IDs, and plan chunks without Android, Python,
   Node, or a network connection.

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
Load(manifest) -> model
Plan(text, voice, controls, continuation) -> chunks
Open(backend) -> session
session.Write(chunk) -> timing and quality receipt
session.Complete()
```

### Work

1. Persist typed request, chunk, continuation, control, and receipt shapes in the
   assembly. Do not expose internal QNN tensor names as the stable user API.
2. Bind the pinned QuickPS WASAPI mechanism as the Windows audio sink. Preserve
   its COM ownership, buffer, format, and deterministic disposal contracts.
3. Provide a Windows reference execution mode for correctness and listening.
   It may be slower than Android, but it must consume the same plan and return
   the same control and artifact identities.
4. Add a minimal `Speak-Kokoro.ps1` driver that loads the assembly, selects a
   voice and backend, streams text, and prints a compact receipt.
5. Keep model load, text planning, synthesis, queuing, presentation, and drain
   timings separate.

### Exit gate

- A clean Windows process loads the release bundle, plans arbitrary admitted
  text, plays multiple chunks through WASAPI, and disposes all native resources.
- The same input plan is accepted without translation by the Android backend.
- Repeated calls reuse the model session; no per-chunk runspace or model reload
  is permitted.

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
4. Map weights and contexts without a second full-model copy. Record proportional
   set size and peak resident memory during cold load and long-form use.
5. Do not require Xamarin, application DEX, runtime C# compilation, or runtime
   native/DSP code emission.

Exit: the signed APK installs, accepts the typed model protocol, speaks a warm
stream, survives repeated sessions and cancellation, restores/cleans temporary
state, and reports its exact component hashes.

## Gate 7: release exemplar

Publish one reproducible release bundle suitable for Hugging Face and GitHub:

- `Kokoro-Hexagon.dll`;
- pinned model/data resources and target-specific native payloads;
- manifest with source revisions, licenses, sizes, and SHA-256 values;
- minimal Windows and Android/AOA drivers;
- one-command source build and verification instructions;
- counterbalanced performance and speaker receipts with narrow claim language;
- an SBOM and signed release artifacts.

The release page must distinguish the stock pinned Kokoro weights from any
future trained, FiLM-modified, or quantized checkpoint. A separate model identity
is created only when weights or architecture actually change.

## Work order

Do not run these tracks as competing prototypes. The order is:

1. Phoneme differential corpus and portable text pipeline.
2. Persist text/phoneme methods into the DLL and prove them on Windows.
3. Minimal DLL driver plus QuickPS WASAPI playback.
4. Feed those plans into the existing warm Android pipeline and obtain a
   long-form speaker receipt.
5. Generalize the successful HVX scheduler and lower the next expensive model
   blocks, using physical A/B gates after each promotion.
6. Reduce appliance/runtime payload and harden lifecycle behavior.
7. Package and publish the reproducible exemplar.

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
