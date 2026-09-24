# Kokoro-Hexagon implementation plan

This is the canonical near-term plan. Historical measurements belong in
`docs/receipts/`; this file contains only the current sequence of work.

## Objective

Deliver a lean, Xamarin-free Android speech appliance whose hot path keeps the
model and QNN contexts resident, streams speech through one native AAudio
output, and improves on the compiler-generated baseline only when a physical
device receipt proves the improvement.

## Proven foundation

- The FP16 QNN decoder produces valid speech on the Galaxy S23.
- Direct Hexagon instruction emission matches the LLVM oracle across the legal
  encoder matrix tested so far.
- A direct HMX W4A8 contraction has exact device readback. This proves the
  instruction and data layout used by that probe, not a quantized Kokoro path.
- Native AAudio output is valid at 24 kHz, mono, float, with zero observed
  underruns in both one-shot and reused-stream probes.
- Reusing one AAudio stream for consecutive chunks works. Context and input
  reuse across arbitrary text does not yet.

The corresponding receipts are the authority for numbers and scope.

## Current gate: persistent long-form speech

One process and one PowerShell runspace must synthesize a multi-chunk passage
without reloading model state between chunks, feed one persistent AAudio
stream, and finish without an underrun or discontinuity.

Work in this order:

1. Add a three-lane linguistic corpus: narrative continuity, clear technical
   narration, and metered lyrics. Keep source provenance and chunk boundaries
   machine-readable.
2. Accept deterministic phoneme fixtures as the front-end boundary. The
   TypeScript implementation is a reference oracle, not an APK dependency.
3. Cache QNN libraries, contexts, graphs, tensor metadata, buffers, and the
   AAudio stream for the lifetime of a speech session.
4. Queue chunks by observed stream state. Record synthesis, validation,
   submission, presentation, completion, underruns, and peak memory
   separately.
5. Play the complete passage through the physical phone speaker and preserve a
   receipt with artifact hashes and exact measurement scope.

Exit: one reproducible long-form run speaks all three lanes with persistent
state, bounded memory, zero observed underruns, and no Python or TypeScript in
the repeated device path.

## Next gate: inclusive kernel wins

After the persistent baseline is stable:

1. Integrate one real Kokoro block through the direct HVX/HMX substrate.
2. Compare inclusive latency against the matching compiler-generated QNN/LLVM
   block, including packing, copies, synchronization, and transport.
3. Admit FP16 packing and W4A8 candidates only through reference, device
   exactness or declared-error, audio-quality, memory, and speaker gates.
4. Promote only a repeatable whole-pipeline win. A faster isolated instruction
   is useful evidence, not a product speed claim.

The FastRPC/CDSP transport remains a measured platform boundary until a probe
shows a supported lower-level route. It is not treated as the application
doorway, and its one-time setup cost must not be charged to every phrase.

## Appliance gate

The downloadable demonstration remains under `src/appliance/`. It uses the
owned Pwsh NativeActivity/CoreCLR host, contains no Xamarin or application DEX,
maps packed weights without a second full-model copy, and reports cold and warm
time to first audio, sustained rate, peak resident memory, and transport versus
compute time.

## Change discipline

- Generated models, contexts, audio, logs, APKs, and device receipts stay in
  the adjacent build directory unless a small redacted receipt is deliberately
  curated into `docs/receipts/`.
- Every external input is hashed. Every graph passes the export gate. Every
  optimization is checked against its predecessor before device promotion.
- Capability statements require a physical-device receipt; audible completion
  requires actual speaker playback.
- Commit and push only coherent, verified hills. Keep unproven work labeled as
  such.

## Immediate deliverable

Land the structured long-form corpus, then implement the persistent context and
chunk scheduler against it. Do not expand the APK surface until that path is
measured and robust.
