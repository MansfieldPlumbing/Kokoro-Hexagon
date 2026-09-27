# Kokoro-Hexagon roadmap

This is the single implementation roadmap. A checked item has a named test or
receipt; it does not imply that the whole synthesis path works. Historical
measurements remain in `docs/receipts/` and do not define production dependencies.

`setup-kokoro.ps1` is an unofficial, separately maintained fork of Pwsh's
`setup.ps1`; it independently builds the Kokoro base APK. Pwsh does not lower
Kokoro models. Kokoro-specific PowerShell source owns the model DLL and direct
backend, so model and host releases remain separate decisions.
The active `C:\Dev\Pwsh` checkout is outside this roadmap and must never
receive Kokoro files or be used as a build, cache, or output location.

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
- [ ] Reconcile the owner's earlier S23 queue-test failure with the currently
  stored passing echo receipt. The archived scripts are different revisions
  across devices; the exact earlier failing script and stage are unlocated.
  Do not conflate the queue result with the checked-in R0Sub0 benchmark:
  that benchmark measured a 2.286–2.302x DSP-tick improvement over LLVM on
  SM8635 while both kernels were invoked through FastRPC. See
  `docs/receipts/transport-evidence-ledger-20260926.md`.
- [x] Reproduce the historical approximately 0.1 ms Razr+ diagnostic echo
  from its pinned source/build recipe, then run the identical fresh worker
  on S23. Warm queue medians were 120.364 µs and 283.907 µs respectively;
  both completed 64 ordered packets. Archived worker binaries still fail at
  packet zero and differ in digest from the fresh build. This is a diagnostic
  result, not product transport or speech. See
  `docs/receipts/dspqueue-live-reproduction-20260926.md`.
- [x] Retain the authored diagnostic DSP echo source and pinned reference
  build recipe in `tools/reference/dspqueue-echo/`, isolated from the
  PowerShell-emitted product closure. The local build writes only under
  git-ignored `build/`.
- [ ] Determine why the S23 response-read interval is longer with the same
  fresh worker. Establish the queue signaling mode and controlled latency
  breakdown before attributing the gap to kernel, firmware, or hypervisor.
  A source-defined capability probe now reports signaling-performance level
  1000 on both devices; this does not identify the actual driver-signaling
  branch or explain the response-read split. See
  `docs/receipts/dspqueue-capability-comparison-20260926.md`.
- [x] Recover the historical DSPQueue diagnostic scripts and receipts from
  both installed diagnostic apps without rerunning them. Both current echo
  receipts pass, but the scripts differ, use `libcdsprpc.so`, and are not
  product artifacts. The Razr+ queue median is 1.94x faster than its own
  synchronous-invoke baseline; the current S23 receipt also passes. See
  `docs/receipts/recovered-dspqueue-diagnostics-20260926.md`.
- [x] Implement a layout-only PowerShell emitter for the pinned public
  DSPQueue arena header, 256-byte-aligned offsets, and message-only packet
  bytes. The executable `tools/Test-DspQueueLayout.ps1` checks emitted
  fields, v2 flags, packet bytes, and invalid-input rejection. This is a
  host-side layout gate only: it allocates no shared device memory and does
  not dispatch a DSP worker.
- [ ] Evaluate a persistent shared-memory DSPQueue-style dispatch path as a
  QNN-independent candidate. The pinned public source defines queue layout,
  FastRPC bootstrap, and signaling alternatives; the recovered diagnostics
  prove library-mediated queue echo on both devices but not Queue Monitor
  support or the product path. Identify the exact signal mode, then validate
  the same owned worker and queue protocol on both devices before promotion. See
  `docs/receipts/dspqueue-upstream-audit-20260926.md`.
- [x] Record a same-session read-only RPC-node inventory on both devices.
  The queried node names and access metadata match; candidate external
  kernel revisions do not match the installed kernel bases. This is an
  inventory gate only, not a queue or app-access test. See
  `docs/receipts/cross-device-cdsp-inventory-20260926.md`.
- [ ] Establish the lowest source-defined CDSP communication path available
  to the intended app on each device; FastRPC is one candidate, not a required
  architecture. Keep QNN and vendor userspace RPC libraries out of the product.
  The current direct-FastRPC raw-open probe targets an ADSP-named node and
  returned `EACCES` in both app sandboxes; it did not test a CDSP session or
  the separately reported bypass route. Trace routing, permissions, memory
  sharing, invocation, and teardown to device-matched source before promoting
  a transport. Do not bypass the app sandbox or infer an ABI from binaries.
  See `docs/receipts/direct-fastrpc-native-open-20260925.md`.
- [x] Implement signed, transactional model admission for private app storage.
  `Model.Store.psm1` validates manifest signature and compatibility, streams
  through bounded hashing, inspects managed metadata without loading code,
  uses a content-addressed store, and atomically promotes `active.json`.
  `tools/Test-ModelStore.ps1` covers install, activation, and tamper rejection.

## Next: live synthesis, before quantization

- [x] Re-author the stock default generator-head inverse STFT as a bounded
  PowerShell FP32 PCM stage. `src/models/ConvertTo-KokoroPcm.ps1` implements
  one-sided inverse DFT, periodic Hann overlap-add, centered crop, and
  squared-window normalization. `tools/Test-KokoroPcm.ps1` gates the envelope,
  padded frames, output length, and non-finite input. This is an isolated
  scalar stage, not live speech or the optimized Hexagon path.
- [x] Establish the full-span AdaIN normalization contract before the emitted
  affine subgraph. `src/models/ConvertTo-KokoroAdaIn.ps1` and
  `tools/Test-KokoroAdaIn.ps1` gate population variance, epsilon, the optional
  instance-normalization affine, and the style affine. The pinned checkpoint
  has no AdaIN norm weight/bias tensors, so stock execution uses initialized
  identity values for that inner affine. Surrounding
  convolutions, graph wiring, and emitted normalization remain open; this
  scalar stage is not a speech or performance claim.
- [x] Connect the style vector to that AdaIN reference stage through the stock
  linear gamma/beta projection. `ConvertTo-KokoroAdaInStyle.ps1` and
  `tools/Test-KokoroAdaInStyle.ps1` gate row-major weight layout, the
  `1 + gamma` gain, beta shift, and composition with normalization. The actual
  checkpoint tensors were checked for one generator block by
  `tools/Test-KokoroAdaInCheckpoint.ps1`; the emitted execution path and full
  graph wiring remain to be connected.
- [x] Keep AdaIN-specific entry points explicitly named so a later model DLL
  can replace this operator family without inheriting generic `Affine` or
  `Normalize` semantics. The emitted helper is
  `New-KokoroAdaInAffineSteps`; `tools/Test-KokoroAdaInOperatorNames.ps1`
  gates the reference and emitted names. The historical file/kernel labels
  remain for existing probe artifacts, not a model-neutral product API.
- [x] Re-author the AdaIN residual block's weight-normalized Conv1D primitive
  with source-defined channel layout, per-output-channel weight norm,
  dilation, and same-length zero padding. `Invoke-KokoroAdaInConv1d.ps1` and
  `tools/Test-KokoroAdaInConv1d.ps1` cover an analytic case; the pinned
  checkpoint gate covers one block's real weights and impulse response.
  This bounded scalar reference is not the emitted fast path; a full numerical
  oracle comparison remains open.
- [x] Compose one complete three-pass AdaIN residual block from named style
  projection, full-time normalization, Snake1D, weight-normalized Conv1D,
  and residual addition. `Invoke-KokoroAdaInResBlock1.ps1` and
  `tools/Test-KokoroAdaInResBlock1.ps1` gate a deterministic reference case;
  `tools/Test-KokoroAdaInCheckpoint.ps1` validates every parameter shape for
  the pinned `generator.resblocks.3` block. No stock numerical parity or
  direct Hexagon execution is claimed for the composed block yet.
- [x] Before lowering the composed block, compare its PowerShell FP32 output
  with a QNN reference run on the same pinned checkpoint weights, style,
  input, valid-frame mask, and block shape. Gate valid-frame error and SNR;
  record precision and mask differences rather than demanding bit identity.
  The existing S23 `r0` diagnostic fixture is 128 channels by 7,681 frames,
  beyond the bounded scalar runner. A pinned-checkpoint, 128-channel,
  64-frame, zero-style, all-valid-mask fixture passed the physical S23 QNN
  differential at 52.99 dB SNR and 0.0601 maximum absolute error. The first
  dilated convolution passed at 53.86 dB SNR. This admits block lowering
  against that tested shape, not a general full-model or all-length claim.
  The historical 62.10 dB `r0` receipt compares QNN's own emitted graph to
  its reference, not this PowerShell block. Do not start direct lowering from
  that receipt alone. The same all-valid-mask differential at 8 and 16 frames
  failed at 0.20 and 2.88 dB SNR. Stagewise traces localized the short-shape
  divergence to the first dilation-3 convolution; the prior stages agreed
  above 52 dB. Keep those lengths as a separate QNN-reference discrepancy,
  not a precision-tolerance adjustment or a claim about product behavior; see
  `docs/receipts/r0-powershell-qnn-differential-20260926.md`.
- [x] Represent the stock duration-to-frame alignment as a bounded index map
  instead of allocating its dense one-hot matrix. `New-KokoroDurationMap.ps1`
  and `Expand-KokoroAlignedFeatures.ps1` gate duration reduction, ties-to-even
  rounding, minimum one-frame clamp, and channel-first gather in
  `tools/Test-KokoroDurationMap.ps1`. A numerical oracle comparison near
  duration half-integers and integration with the predictor remain open.
- [ ] Execute and numerically verify the full stock computation from admitted phoneme IDs and the
  selected voice row through ALBERT, text encoder, duration, F0/N, harmonic
  source, decoder, iSTFT, and PCM. The bounded stage coordinator is authored,
  but its full stock-weight forward has not passed. Replace the opaque
  prepared-input boundary in `New-KokoroDecoderGraph.ps1` with auditable stages.
  Keep source/checkpoint identity and tensor shapes attached to every stage.
- [x] Re-author ALBERT's embedding sum, layer normalization, 128-to-768
  projection, shared multi-head attention, `gelu_new` feed-forward, residual
  normalization, and repeated-layer control as bounded PowerShell FP32
  references. The stock checkpoint shape gates and a stock-weight one-layer
  execution pass; the 12-layer stock output still needs an independent
  numerical differential. The post-ALBERT `bert_encoder` 768-to-512 linear
  primitive is also gated. See `docs/receipts/albert-fp32-reference-20260926.md`.
- [ ] Complete independent stock numerical differentials across ALBERT,
  decoder, and waveform synthesis. Do not start further Hexagon lowering
  to substitute for unverified model computation.
- [x] Add bounded PowerShell FP32 references for the shared one-layer
  bidirectional LSTM gate equations and reverse-direction layout, plus the
  stock 512-to-50 duration projection connected to the existing frame map.
  Analytic and pinned-checkpoint tests pass. This does not close the duration
  branch by itself. See `docs/receipts/lstm-duration-fp32-reference-20260926.md`.
- [x] Compose the three stock style-conditioned duration-encoder LSTM/AdaLayerNorm
  pairs, predictor LSTM, duration projection, and aligned predictor features
  as a bounded PowerShell FP32 branch. A stock-weight two-token shape/finite
  gate passes from supplied 512-channel token features. The ALBERT-to-duration
  connection and independent numerical oracle comparison are still open;
  this is not phoneme-to-PCM or speech. See
  `docs/receipts/duration-branch-fp32-reference-20260926.md`.
- [x] Re-author the stock text encoder as a bounded PowerShell FP32 reference:
  token embedding, three weight-normalized Conv1D / channel LayerNorm /
  LeakyReLU blocks, and bidirectional LSTM. Analytic and pinned-checkpoint
  two-token gates pass. `Invoke-KokoroWeightNormConv1d.ps1` provides a
  model-neutral primitive verified against the existing AdaIN-specific
  reference. Full-length numerical parity and the text-to-aligned-ASR
  integration remain open; see
  `docs/receipts/text-encoder-fp32-reference-20260926.md`.
- [x] Compose the stock F0/N shared LSTM, both three-block AdaIN heads,
  transposed-convolution middle upsample, channel-changing shortcut, and
  one-channel projections as a bounded PowerShell FP32 reference. Analytic
  upsample/shortcut tests and a pinned-checkpoint two-frame shape/finite gate
  pass. The duration-to-F0/N connection and numerical parity remain open;
  this is not yet PCM. See
  `docs/receipts/f0n-branch-fp32-reference-20260926.md`.
- [x] Connect admitted token IDs and a 256-element voice row through ALBERT,
  its 768-to-512 projection, duration prediction/alignment, text encoder,
  and F0/N heads. The style halves and common frame map are explicit. A
  stock-checkpoint three-token, high-speed shape/finite gate passes with
  one ALBERT repeat and one layer of each configurable encoder; each component
  also has its own gate. This does not establish 12-repeat/full-layer
  numerical parity, normal-speed execution, decoder output, or PCM. See
  `docs/receipts/acoustic-branches-fp32-reference-20260926.md`.
- [x] Author the decoder prelude and core as bounded PowerShell FP32
  references: F0/N stride-two convolution, aligned text residual, encode
  AdaIN block, three same-rate decode blocks, and the final upsample block.
  Analytic layout/shortcut gates and pinned-checkpoint two-frame shape/finite
  gates pass. This produces 512-channel generator features, not PCM; the
  learned generator remains to be composed. See
  `docs/receipts/decoder-core-fp32-reference-20260926.md`.
- [x] Re-author the configured generator's stochastic harmonic source and
  20-point, hop-5 centered Hann STFT/iSTFT as bounded PowerShell FP32
  references. Analytic phase/voicing and spectral gates, stock source-weight
  shape/finite gates, a controlled-source round trip above 90 dB SNR, and
  the connected 22-channel source-spectrum prelude gate pass. Stock-weight
  learned-generator numerical comparison remains before a speech claim.
  See `docs/receipts/generator-source-stft-fp32-reference-20260926.md`.
- [x] Preserve the existing bounded PowerShell AdaIN/Snake residual block
  and add both weight-normalized transposed-convolution upsamplers and both
  ordinary noise convolutions. The existing residual analytic gate and new
  analytic/pinned-checkpoint upsampler and noise-convolution gates pass. A
  stock-weight numerical gate for the full composition remains. See
  `docs/receipts/generator-learned-primitives-fp32-reference-20260926.md`.
- [x] Compose the two-stage learned generator topology as a bounded PowerShell
  reference from supplied decoder features, F0, style, and parameter vectors
  through the harmonic source, reflection padding, six residual branches,
  post projection, and PCM. The synthetic zero/nonzero and connected
  source-to-PCM shape gates pass. The digest-verified checkpoint's 303
  generator tensors pass exact shape, dtype, stride, and finite-value checks.
  A stock-weight numerical differential and connected phoneme-to-PCM run
  remain open. See
  `docs/receipts/generator-composition-fp32-reference-20260927.md`.
- [x] Admit the pinned checkpoint's acoustic, decoder, and generator weight
  families through reusable PowerShell readers: 171, 72, and 303 tensors
  respectively. The remaining two checkpoint tensors are ALBERT pooler
  weights excluded by the stock `last_hidden_state` return path. A bounded
  phoneme-to-PCM coordinator now connects the
  authored stages with the full stock layer counts. The reader gates pass;
  only its AST and rejection guards are gated, not a full forward. See
  `docs/receipts/model-weight-admission-20260927.md`.
- [x] Read the pinned `af_heart` voice pack as a top-level tensor and select
  row `phoneme_count - 1` as specified by the stock pipeline. The one-phoneme
  row and out-of-bounds rejection gate pass. This is an input contract, not
  audible synthesis.
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
- [ ] Use the existing QNN speech path only as a differential oracle for the
  same admitted phonemes, voice row, speed, and checkpoint. Compare duration,
  aligned PCM, acoustic-stage tensors where available, and listening results.
  Record its FP16/prepared-context and inverse-STFT differences explicitly;
  do not copy its contexts, libraries, or outputs into the product path or
  infer stock parity from an audible QNN phrase alone.

The first audible gate accepts admitted phonemes, not arbitrary text. It is
blocked today by the absent full computation and QNN-free execution path, not
by device discovery. Do not label a payload-only DLL as a live model.

### Immediate demo: quoted text to the phone speaker over ADB

ADB is a development transport for this gate, not an APK dependency or the
release protocol. Keep USB debugging available during development; do not add
an unnecessary debugging-off condition to this loop. A passing demo begins
with a single Windows PowerShell command such as:

```powershell
pwsh -File .\tools\Invoke-KokoroSpeech.ps1 -Text "Hello from Kokoro." -Voice af_heart
```

`Invoke-KokoroSpeech.ps1` is a target interface, not a working script today.
The command must take the quoted phrase as data, select the intended phone
explicitly when more than one is attached, and return a structured receipt
only after generated PCM has drained through that phone's AAudio speaker.
It must not play a recording, tone, prepared QNN context, or precomputed
acoustic fixture. The path must use the verified stock model DLL and owned
PowerShell-to-Hexagon execution described above.

- [ ] Complete and differentially gate stock phoneme-to-PCM computation,
  including all missing graph stages, weight use, direct emitted backend,
  transport, and resident AAudio. A passing isolated kernel or payload test
  cannot close this item.
- [ ] Complete the stock text-to-phoneme adapter below so an ordinary quoted
  sentence reaches the phoneme gate without a host-side Python/ONNX/QNN step.
- [ ] Package the signed-model trust anchor and `Model.Store.psm1` in the
  independent NativeActivity APK; admit and load the same weight-bearing DLL
  from private storage after restart. Keep the R2R-free and Mono-free gates.
- [ ] Add a development-only, typed request ingress to that APK and a Windows
  `tools/Invoke-KokoroSpeech.ps1` facade. Use ADB to select the device,
  deliver the bounded text request, start or contact the appliance, and
  retrieve a receipt. Verify the exact ingress on the independent APK;
  do not assume the historical debug host's `run-as` access is available.
  Keep authored device scripts in this repository, not only on phones.
- [ ] On each target separately, run a fresh quoted sentence from the one
  Windows command to audible phone-speaker PCM. Record model/APK/ELF hashes,
  admitted text and voice identity, per-stage checks, sample count, AAudio
  drain/underruns, and cold/warm timing. The owner must hear the generated
  sentence. Do not mark this gate complete from an ADB receipt alone.

## Text and utterance planning

- [x] Audit sherpa-onnx's pinned Kokoro callback/playback path as a
  scheduling reference. It invokes the callback only after each complete
  sentence/token-limited model run, not from within one running model. Keep
  its ONNX/runtime/frontend implementation out of the product. Do not copy
  the example's unbounded playback queue or per-callback allocations. See
  `docs/receipts/sherpa-onnx-kokoro-streaming-audit-20260926.md`.
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
  bounded look-ahead and no per-chunk model reload. Keep a resident AAudio
  stream and a capacity-bounded PCM handoff between synthesis and playback;
  no allocation, conversion, logging, or wait belongs in an audio callback.
  Measure inter-chunk gaps, real-time factor, peak memory, queue occupancy,
  underruns, and completion/drain state. A completed-segment callback must
  not be reported as intra-model streaming.
- [ ] Compare exact full-utterance scheduling against legal-boundary segment
  scheduling on the same inputs. Stock `AdaIN1d` uses `InstanceNorm1d` without
  running statistics, so each channel's mean and variance depend on its full
  input time axis even in inference (Kokoro `istftnet.py:20-31`; PyTorch
  `instancenorm.py`, pinned source revisions in the PCM stage). Test tiled
  reductions and fused normalization/affine within each block, but do not
  substitute online or per-chunk statistics and call them stock-equivalent.
  Record time-to-first-audio, total latency, quality, and peak memory before
  choosing the faster production schedule.
- [ ] Once a complete speech path exists, compare a short first legal
  prosodic segment followed by duration-sized steady segments against uniform
  segmentation. Select boundaries from admitted tokens and measured/predicted
  duration, not fixed word or syllable counts. A segment cut changes AdaIN
  statistics and may change prosody; record listening results, first-audio
  latency, inter-segment gaps, total synthesis time, underruns, and memory on
  each device. Keep the model resident and the audio queue bounded. The
  historical 768-frame AAudio capacity is not a 500-ms hardware buffer.
- [ ] Evaluate startup scheduling only behind source-defined and physical
  gates: a reversible direct-path DSP/DDR performance vote, user-PD VTCM
  allocation and legal transfer/preload, and persistent AAudio operation.
  Measure cold/warm first-audio latency, clocks if observable, energy,
  thermals, and sustained throughput against a no-vote/no-preload baseline.
  Do not import QNN power APIs, assume an 8-MiB user allocation, require
  MMAP/exclusive audio, or claim DSP-to-AAudio zero-copy without a verified
  transport and buffer-ownership contract. No sub-25-ms target is established.

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
  both physical devices. This is a historical packaging and launch checkpoint:
  the 40,967,549-byte signed artifact contains no DEX, `libmonodroid`, or
  `libxamarin-app` and remained live after launch on both
  devices. It predates the current `status`-only dispatch and does not prove
  that the current source builds or speaks. See
  `docs/receipts/model-less-appliance-20260925.md`.
- [x] A prior `status`-only, model-less NativeActivity/CoreCLR/SMA rebuild was
  signed under 40 MiB, inspected for forbidden payloads, and launched on both
  devices. This is a historical packaging gate, not proof of the newly renamed
  managed namespace or speech; see
  `docs/receipts/model-less-appliance-rebuild-20260925.md`.
- [x] Rebuild the model-less APK from the `Dev.MansfieldPlumbing.Kokoro` source
  after the external Build directory was cleared. The signed artifact is under
  40 MiB; package inspection found no
  DEX, Mono/Xamarin libraries, or bundled model, and that exact APK installed
  and launched on both physical devices. This is not speech evidence. See
  `docs/receipts/model-less-appliance-kokoro-namespace-20260925.md`.
- [ ] Re-emit every selected ReadyToRun runtime image as a verified IL-only
  image before store emission. A direct PE-header audit of the existing
  96-assembly archive found 62 R2R images, including CoreLib; prior inventory
  messages classified them but did not exclude them. Selection and store
  emission now fail closed until this transformation and an artifact-level
  zero-R2R gate pass. See `docs/receipts/r2r-payload-audit-20260926.md`.
- [x] Expose the native-supplied private app root through the independently
  emitted managed host and verify its existence after install and launch on
  both devices. Strengthen `Model.Store.psm1` so an active model load
  revalidates the signed manifest, compatibility, payload length, hash, and
  managed identity. The store load gate passes on Windows; the APK does not
  yet package or invoke it. See `docs/receipts/private-model-root-20260925.md`.
- [ ] Finish the R2R-free and Mono-free appliance integration: load a verified,
  compatible weight-bearing model DLL from private app storage; connect its
  admitted phoneme/text path and full stock Kokoro graph to direct Hexagon
  execution and resident AAudio output. First validate speech through the
  ADB-driven development facade above; later validate the same typed model
  requests through the Windows AOA/WASAPI controller. A launch or test tone
  is not a speech validation result.
- [ ] Complete the owned Android bindings and load only a compatible model DLL
  admitted by the private model store. The running base appliance does not yet
  establish a device-proven Kokoro integration.
- [ ] Wire `Model.Store.psm1` to `ANativeActivity.internalDataPath`, the HTTPS
  updater, and the offline AOA install operation. Re-run interrupted-download,
  rollback, incompatible-ABI, expiry, and multi-model activation tests on the
  packaged appliance. A verified update replaces the active pointer, then
  requires an appliance process restart before loading; no in-process hot-swap.
- [ ] Pin a dedicated model-signing public key in the appliance, embed the
  validated PowerShell store source, and invoke its `LoadActive` gate from the
  managed startup before accepting any model request. Test a signed model DLL
  and unsigned/tampered rejection on both devices. The current base APK has
  neither the trust anchor nor an admitted model DLL.
- [ ] Expose a small typed session contract for model load, phoneme/text
  requests, chunked PCM, cancellation, receipts, and disposal. Keep AOA and
  local Android transport separate from synthesis semantics. Windows WASAPI
  and Android AAudio are distinct audio sinks.

### Later demo: Windows PowerShell ↔ Android PowerShell over USB AOA

AOA is the prospective user-facing USB transport. It must not depend on ADB
or require users to enable USB debugging. This is a later integration gate,
not a prerequisite for the ADB-driven speech demo. Keep debugging available
while developing AOA; prove absence of ADB calls in the AOA data path rather
than disabling debugging in the daily loop.
The platform contracts are Android's [AOA protocol](https://source.android.com/docs/core/interaction/accessories/aoa),
[accessory permission and descriptor API](https://developer.android.com/develop/connectivity/usb/accessory),
and the [NativeActivity handle](https://developer.android.com/ndk/reference/struct/a-native-activity).
Windows driver admission must be checked against [WinUSB installation rules](https://learn.microsoft.com/en-us/windows-hardware/drivers/usbcon/automatic-installation-of-winusb),
not inferred from this development machine.

`tools/UsbAoa.ps1` already negotiates accessory mode on Windows, and
`tools/Invoke-KokoroAoa.ps1` has bounded request/reply framing for diagnostic
`status`, `ping`, and `receipt`. `src/runspace/Aoa.Appliance.ps1` is the old
managed-host endpoint, not the independent appliance implementation. The
current `src/appliance/aoa/AndroidManifest.fragment.xml` is not wired into
`setup-kokoro.ps1`, and its referenced accessory-filter XML resource is not
packaged. The independent appliance currently admits only `status` at its
startup expression boundary. None of these parts yet proves a release AOA
pipe. The Windows client currently asks `UsbAoa.ps1` to stop ADB when starting
accessory mode; determine whether that is necessary on each supported Windows
configuration, and do not make it a default product requirement.

- [ ] Add the accessory declaration, filter resource, and package-level gate
  to the NativeActivity build. On attachment or startup, obtain Android's
  accessory permission and descriptor through the narrow source-defined JNI
  boundary; hand bounded reads and writes to PowerShell. Test attach,
  already-attached, denial, detach, and process restart on each device.
- [ ] Turn the existing framing into a versioned, bidirectional session with
  correlation IDs, bounded binary chunks, cancellation, backpressure,
  timeouts, reconnect, and structured errors. Android-initiated events and
  Windows-initiated requests must both work without ADB in the data path.
- [ ] Expose a PowerShell-native Windows facade for connection, typed speech
  requests, receipts, model transfer, and optional PCM playback through
  WASAPI. Keep USB transport and synthesis semantics separate.
- [ ] Admit remote script updates only as authenticated, signed, bounded
  artifacts in private app storage. Validate identity and AST before an
  authorized runspace executes the admitted file; never evaluate request
  text as PowerShell or turn accessory permission into unrestricted eval.
- [ ] Prove accessory permission and bidirectional `status`/event exchange on
  the independent APK, then the same genuine speech request as the ADB demo.
  Test disconnect/reconnect and the Windows USB driver-binding path on a
  clean machine. Verify that neither `adb.exe` nor an ADB server participates
  in the AOA data path; debugging-off may be a final independence check, not
  a routine development condition.
- [ ] After the speech path reaches the facade boundary, stop for integration
  review before expanding to multiple Activities, Surface, or a chat demo.
  The language-model demo is not a Kokoro synthesis prerequisite.
- [ ] Publish a reproducible manifest, SBOM, signed APK, verified model DLLs,
  source-build instructions, size measurements, and cross-ASIC receipts.
  The default release is model-less; bundle a smallest viable quantized model
  only if its measured size and quality justify it.

## Change discipline

Only reviewed source, tests, manifests, and compact receipts enter Git. Keep
DLLs, APKs, checkpoints, QNN contexts, audio, and raw device logs out of Git.
The independent appliance build defaults to ignored `build/`; its signing-key
and package-cache defaults stay outside the repository. A checked roadmap item
requires its named test or receipt; a live speech claim requires PCM heard
from a physical speaker.
Production build reachability must be checked for forbidden reference
dependencies. Commit and push coherent, tested checkpoints.
