# Kokoro-Hexagon roadmap

This is the single implementation roadmap. A checked item has a named test or
receipt; it does not imply that the whole synthesis path works. Historical
measurements remain in `docs/receipts/` and do not define production dependencies.

## Product boundary

The product is a model-less Android appliance and a separately versioned,
weight-bearing managed model DLL. The final DLL must contain the admitted
phoneme and text path, tensor catalog, graph, control contract, and lowered hot
paths—not merely a compressed checkpoint. PowerShell/System.Management.Automation
parses and lowers the authored sources at build time. The phone executes the
admitted managed and directly emitted Hexagon code and plays PCM through a
resident audio stream. A Windows controller can use the same model protocol.

The base release is model-less and must remain smaller than 40 MiB. It obtains
one or more model DLLs after installation or accepts the same artifacts over
AOA for offline provisioning. Downloaded code and data must be verified
against a signed release manifest before loading. Ordinary inference does not
compile code or fetch unverified components.

No QNN library, QNN ABI, QNN context, QNN compiler, ONNX Runtime, Python,
PyTorch, or LLVM component is a production build or execution dependency.
Existing material under `src/export/`, `src/runspace/Qnn.*`, historical device
jobs, and pinned compiler outputs remains isolated oracle/reference evidence.
The pinned stock Kokoro checkpoint is a host-side source input only; it is not
read by the released app. Independent assemblers and model frameworks may
compare results, but cannot supply release artifacts.

`New-KokoroDecoderGraph.ps1` is currently only a parsed two-node decoder
contract with precomputed acoustic inputs. Its name describes its present
scope; it is not the complete Kokoro model. The full authored synthesis graph
and its directly emitted backend remain to be built.

## Verified checkpoints

- [x] Pin the stock Kokoro checkpoint, config, voices, and source revision in
  `lib/manifest.json`.
- [x] Read the pinned checkpoint without importing PyTorch; stream tensor
  payloads through a bounded buffer, including tensors with storage offsets.
  `src/runspace/Torch.Checkpoint.psm1` and the weight-assembly tests cover this.
- [x] Validate all 114 pinned phoneme mappings, the 510-phoneme limit, boundary
  IDs, and the length-selected `af_heart` voice row. A separately emitted
  `Kokoro.Phonemes.dll` passes a fresh Windows-process load test.
- [x] Extract all 548 contiguous FP32 tensors into a managed resource assembly
  and verify every embedded hash in a fresh Windows process. The FP32 DLL is
  327,285,248 bytes. This is a payload validation artifact, not a synthesizer.
- [x] Emit and verify an FP16 payload candidate from the same tensors. Its DLL
  is 163,758,080 bytes. An 80,064-value sampled comparison gives mean absolute
  weight error 1.19e-5; no acoustic parity is claimed.
- [x] Preserve the two-node parsed graph identity in the existing managed host
  assembly. See `docs/receipts/model-assembly-windows-20260924.md`; this is
  graph identity, not end-to-end execution.
- [x] Demonstrate one directly emitted V73 HVX specialization on physical
  SM8550 and SM8635 devices. See `docs/receipts/r0sub0-cross-soc-20260924.md`.
  This does not establish a complete decoder or general SoC portability.
- [x] Reject a breath-group cap that would cut through a phoneme run.
  `tools/Test-SplitBreathGroups.ps1` covers the provisional planner; its
  frames-per-character estimate is not a duration predictor.
- [x] Extract the generic C ABI delegate factory from QNN-named code.
  `Native.Binding.psm1` caches validated Cdecl signatures; AAudio and the
  direct FastRPC probes consume it. `tools/Test-NativeBinding.ps1` parses it
  and executes a native call in a clean process.
- [x] Remove the managed Android descriptor/reflection dependency from the
  direct FastRPC ioctl probe. It now reaches libc through `Native.Binding`.
- [ ] Establish the permitted production FastRPC device edge. Direct libc
  `open` of `/dev/adsprpc-smd` returned `-1` from both current app sandboxes;
  do not infer the cause without a source-matched SELinux/driver trace. See
  `docs/receipts/direct-fastrpc-native-open-20260925.md`.
- [x] Implement signed, transactional model admission for private app storage.
  `Model.Store.psm1` validates manifest signature and compatibility, streams
  through bounded hashing, inspects managed metadata without loading code,
  uses a content-addressed store, and atomically promotes `active.json`.
  `tools/Test-ModelStore.ps1` covers install, activation, and tamper rejection.

## Next: live synthesis, before quantization

- [ ] Author the full stock computation from admitted phoneme IDs and the
  selected voice row through ALBERT, text encoder, duration, F0/N, harmonic
  source, decoder, iSTFT, and PCM. Replace the opaque prepared-input boundary
  in `New-KokoroDecoderGraph.ps1` with auditable stages. Keep source/checkpoint
  identity and tensor shapes attached to every stage.
- [ ] Lower a complete FP32 path without QNN, Python, or LLVM in the build or
  device execution graph. Prove each promoted block against the pinned oracle
  and preserve a same-input/same-weight baseline before changing precision.
- [x] Run the QNN-independent AAudio binding on both physical devices. Each
  device accepted 24 kHz mono float PCM and drained all 6,000 frames; one
  reported one startup xrun. See
  `docs/receipts/native-binding-audio-smoke-20260925.md`.
- [ ] Keep one resident AAudio stream with bounded writes, reuse, cancellation,
  and teardown on the product path. Do not use historical QNN speech as a
  product driver.
- [ ] On both attached ASICs, run direct phoneme input through the same model
  DLL to audible PCM. Record per-stage hashes, cold/warm latency, underruns,
  output duration, and a listening result. A reference recording or prepared
  acoustic-input fixture does not satisfy this gate.

The first audible gate accepts admitted phonemes, not arbitrary text. It is
blocked today by the absent full computation and QNN-free execution path, not
by device discovery. Do not label a payload-only DLL as a live model.

## Text and utterance planning

- [ ] Re-author the admitted English text-to-phoneme behavior in PowerShell
  and lower deterministic scanners/tries/tables into the model DLL. Use pinned
  Kokoro/Misaki and `MisakiSharp` only as differential oracles. Preserve source
  spans, explicit pronunciation overrides, speaker turns, and cue cards;
  never evaluate user text as PowerShell.
- [ ] Admit a typed `SynthesizePhonemes` primitive and then a text adapter.
  Reject unknown code points, unsupported languages, malformed cue cards,
  excessive input, and unbounded continuation state.
- [ ] Segment at legal token/phoneme boundaries using predicted duration and
  the 510-phoneme model limit. Kokoro's AdaIN normalizes over the utterance,
  so a cut changes synthesis statistics. Treat a breath boundary as a short
  pause, not a synthesized inhale. Select pause length and target utterance
  duration from speaker tests; the current frames-per-character estimate is
  not an admission criterion.
- [ ] Stream narrative, technical, and metered passages on both devices with
  bounded look-ahead and no per-chunk model reload. Measure inter-chunk gaps,
  real-time factor, peak memory, and completion/drain state.

## Precision and backend promotion

- [ ] Establish FP32 acoustic parity and then test the existing FP16 weight
  candidate through the complete audio path. Do not infer audio quality from
  payload hashes or sampled weight error.
- [ ] Calibrate activations from the admitted utterance corpus, then test INT8
  or W8A8 at operator and block boundaries. Record scale, layout, saturation,
  per-layer error, speech quality, and inclusive latency/memory.
- [ ] Test W4A8 only for eligible blocks, with direct Hexagon instruction and
  packing verification, per-layer differential gates, and physical-device
  speaker receipts. Identify mixed-precision blocks honestly; do not call a
  mixed graph wholly W4A8.
- [ ] Generalize the proved HVX scheduler, liveness, register allocation,
  tiling, tails, and legality checks across the graph. Keep emitted DSP ELF
  identity tied to graph, weight, schedule, and target hashes.

## Appliance, facade, and release

- [x] Build, sign, and install the model-less NativeActivity/CoreCLR/SMA APK on
  both physical devices. The 40,967,549-byte signed artifact contains no DEX,
  `libmonodroid`, or `libxamarin-app`, excludes R2R images, and remained live
  after launch on both devices. See
  `docs/receipts/model-less-appliance-20260925.md`.
- [ ] Complete the owned Android bindings and load only a compatible model DLL
  admitted by the private model store. The running base appliance does not yet
  establish a device-proven Kokoro integration.
- [ ] Wire `Model.Store.psm1` to `ANativeActivity.internalDataPath`, the HTTPS
  updater, and the offline AOA install operation. Re-run interrupted-download,
  rollback, incompatible-ABI, expiry, and multi-model activation tests on the
  packaged appliance.
- [ ] Expose a small typed session contract for model load, phoneme/text
  requests, chunked PCM, cancellation, receipts, and disposal. Keep AOA and
  local Android transport separate from synthesis semantics. Windows WASAPI
  and Android AAudio are distinct audio sinks.
- [ ] After the speech path reaches the facade boundary, stop for integration
  review before expanding to multiple Activities, Surface, or a chat demo.
  The language-model demo is not a Kokoro synthesis prerequisite.
- [ ] Publish a reproducible manifest, SBOM, signed APK, verified model DLLs,
  source-build instructions, size measurements, and cross-ASIC receipts.
  The default release is model-less; bundle a smallest viable quantized model
  only if its measured size and quality justify it.

## Change discipline

Only reviewed source, tests, manifests, and compact receipts enter Git. Keep
DLLs, APKs, checkpoints, QNN contexts, audio, and raw device logs in the
adjacent Build directory. A checked roadmap item requires its named test or
receipt; a live speech claim requires PCM heard from a physical speaker.
Production build reachability must be checked for forbidden reference
dependencies. Commit and push coherent, tested checkpoints.
