# Kokoro-Hexagon repository contract

The machine/workspace `AGENTS.md` security and change-control rules apply.
Use [ROADMAP.md](ROADMAP.md) for the current implementation gates. Do not infer
production status from historical receipts or reference harnesses.

## Build lineage and checkout boundary

Kokoro-Hexagon is a downstream TTS engine for the Xamarin-independent Pwsh
base pinned in `lib/manifest.json`. Pwsh owns the generic NativeActivity,
CoreCLR, SMA, package, and startup substrate. Kokoro source in this repository
owns model assembly, weight conversion, Hexagon emission, typed speech
sessions, and audio policy. `setup-kokoro.ps1` is a legacy migration and
equivalence oracle, not the upstream base authority; do not forward-port its
obsolete Xamarin, DEX, Java-peer, type-map, or package-version machinery.

`C:\Dev\Pwsh` is a separate, actively used upstream checkout. Kokoro agents
must not modify, build in, or use it as an input or output. When Scott
Mansfield explicitly authorizes read-only inspection of a named Pwsh checkout
in the current conversation, the shared owner-authorized exception permits
that inspection for the stated task only. Treat observations from an
uncommitted working tree as diagnostic evidence, not as reproducible product
input. Otherwise fetch required Pwsh source from an immutable GitHub revision,
verify its pinned hash, and keep generated files outside that checkout. Never
place Kokoro model files, artifacts, caches, or temporary files in the Pwsh
source tree.

Hard stop: the repository does not yet contain a working Kokoro synthesizer.
A launching APK, model-weight DLL, parsed graph, native-audio tone, QNN speech
job, or isolated Hexagon kernel is not one. Do not call any of them a product
speech build, admit `speak` in the appliance, or demonstrate them as if they
fulfill the mission. A live-speech claim requires one PowerShell-authored path
from admitted phonemes and verified stock weights through the full model and
directly emitted Hexagon code to audible PCM on the physical device.

Do not put PowerShell interpretation, tensor arithmetic, or per-operator
orchestration on the product inference path. PowerShell/SMA is the model
compiler frontend: validate authored source and stock inputs, recover and type
the graph/control representation, admit weights, optimize and lower as far as
the verified backend permits, and emit the managed model artifact and direct
Hexagon code. The admitted artifact and minimal device host execute the
compiled control/dispatch and audio path; the cDSP executes hot model math.
Bounded FP32 PowerShell operators are test oracles only: compare
each emitted operator against them before promotion, but do not require a
full scalar phoneme-to-PCM run before moving math to Hexagon. Missing ALBERT,
duration, F0/N, decoder, or waveform semantics must still be source-traced
and gated; DSP execution does not excuse a missing model stage. Keep oracle
timings separate from device benchmarks and audible-speech claims.

## Governing objective: PowerShell end to end

- PowerShell 7 is the authored implementation language and compiler frontend
  for Windows model ingestion and build, with an Android shell/control surface.
  Android is an unsupported PowerShell target that this project must make work
  through an owned NativeActivity/CoreCLR/System.Management.Automation host.
- PowerShell parses and validates authored source with SMA's AST, then emits
  the weight-bearing managed model assembly and Hexagon ELF directly. At
  inference time, the admitted compiled model and minimal host invoke the DSP
  and deliver PCM to Android AAudio or Windows WASAPI without a PowerShell
  runspace driving model stages. SMA's parser and AST are a frontend, not an
  automatic optimized Hexagon backend; every lowering and emitted operator
  still needs its own equivalence gate. The managed runtime and minimal native
  bootstrap are substrates, not alternate synthesis implementations.
- Do not author product behavior in C#, use Roslyn or `Add-Type` source
  compilation, or substitute a C/C++/Python/ONNX/QNN/LLVM compiler pipeline for
  PowerShell lowering and emission. A pinned native bootstrap needed to start
  CoreCLR on Android is an explicit platform exception, not permission to move
  model logic out of PowerShell.
- The performance goal is to beat a same-input, same-weight LLVM baseline with
  PowerShell-emitted Hexagon kernels while preserving stock Kokoro numerics.
  LLVM is a measurement competitor only, never a release build dependency.
  Partial-kernel wins do not establish whole-model performance or speech.

## Upstream source rule

- Derive model behavior from the pinned original Kokoro source revision,
  checkpoint, config, and voices. Re-author that behavior in PowerShell; do
  not derive an implementation from ONNX exports, QNN contexts, recordings,
  traces, or other downstream products. Use them only as wayfinders for
  differential checks, never as implementation inputs or release artifacts.
- Derive the compiler and runtime path from PowerShell/System.Management.Automation
  source and documented .NET behavior, then the Hexagon ISA specification and
  source-defined Android/Linux interfaces. Pin the exact revision or document
  which device source is still missing. Do not reverse engineer vendor binaries
  or invent an undocumented API from observed behavior.
- At each layer, record source identity, the PowerShell representation, the
  emitted artifact, and an executable equivalence gate. If the source contract
  is missing, mark only that layer unverified and continue independent work;
  never promote a reference implementation to fill the gap.

## Product boundary

- The product is a model-less NativeActivity/CoreCLR/SMA appliance and a
  separately verified, weight-bearing managed model DLL. The final DLL owns
  admitted text/phoneme logic, graph identity, weights, control schema, and
  lowered hot paths.
- The managed host namespace is `Dev.MansfieldPlumbing.Kokoro`. It is distinct
  from the lowercase Android package id and from historical Pwsh type names.
- PowerShell parses and validates authored source before lowering. User text is
  data: never parse or evaluate it as PowerShell. Check lengths, Unicode,
  tensor shapes, offsets, storage bounds, and resource hashes before use.
- `New-KokoroDecoderGraph.ps1` is currently an incomplete, parsed decoder
  contract. Its two nodes do not establish live phoneme-to-PCM synthesis.
- Name new product graph operators, emitted methods, and PowerShell stages
  for their actual model semantics. AdaIN normalization, style projection,
  and affine lowering must say `AdaIn` in their public names; do not publish
  them as generic `Normalize` or `Affine` methods. Historical diagnostic
  artifact labels may stay stable but must not become product APIs. Keep any
  future non-AdaIN model behind its own versioned model assembly and operator
  contract. The appliance must not assume AdaIN is permanent in all model DLLs.
- QNN libraries, ABI, contexts, and compiler; ONNX Runtime; Python/PyTorch;
  and LLVM are oracle/reference or historical material only. No production
  build or runtime edge may reach them. Do not package their outputs as a
  release dependency.
- Keep APK and model DLL separate. Stage a downloaded or AOA-supplied DLL in
  private storage; verify its signed manifest, compatibility, exact length,
  SHA-256, and managed identity; then promote it by atomic active-pointer
  replacement. An update becomes loadable only after the appliance process
  restarts; do not claim in-process model hot-swap. Do not fetch or compile
  code during ordinary inference.

## Repository boundaries

- `lib/manifest.json` pins external inputs and historical oracle provenance.
  The `hostCompiler` and `deviceRuntime` entries are not production dependencies.
- `src/export/`, `src/runspace/Qnn.*`, and prepared-context device jobs are
  isolated reference harnesses. New product code must live outside them and
  must not import their libraries or contexts.
- `src/appliance/provider/` is a historical C# baseline, not an implementation
  template. Do not promote its code or its measurements into the product.
- Do not commit generated DLLs, APKs, ONNX, contexts, ELF, weights, audio,
  device logs, signing keys, or raw device identifiers. Active downstream
  builders write generated artifacts under the ignored `build/` directory;
  signing keys and package caches remain outside the repository. The retained
  `setup-kokoro.ps1` fork is not an active product build input.
  Use `docs/receipts/` for compact reviewed evidence.
- Use approved PowerShell Verb-Noun names for executable scripts. Parsed graph
  sources must state what computation they currently describe.

## Evidence and promotion

- Pin source and inputs. Validate PowerShell ASTs and test emitted methods in
  a clean process before use. Source/checkpoint readers are build-time only.
- Keep generic C ABI binding in `Native.Binding.psm1`; product paths such as
  AAudio and direct FastRPC must not import `Qnn.Abi.psm1` for delegate types.
- Full Language Mode is required only for the owned managed/native interop
  boundary: `Native.Binding.psm1` emits validated delegate types with
  `Reflection.Emit`. User text and downloaded manifests remain data and are
  never compiled or evaluated.
- Compare each numerical or precision change to its preceding FP32/declared
  baseline, then measure audio quality, full-path timing, and memory.
- A device kernel claim needs a same-artifact physical receipt. A live speech
  claim needs PCM audibly played from the phone speaker on the owned path;
  a reference recording or prepared QNN context is not a substitute.
- Keep SM8550 and SM8635 results separate; do not infer cross-ASIC portability
  from an ISA-subset argument alone.
- Do not treat FastRPC as the required or lowest CDSP transport. The recorded
  SM8635 R0Sub0 result is an emitted-kernel comparison invoked through
  FastRPC, not evidence that FastRPC was bypassed. Historical DSPQueue echo
  diagnostics recovered from both phones passed and show a Razr+ queue median
  1.94x faster than its synchronous-invoke baseline. The scripts differ by
  device, are not checked in, and still use `libcdsprpc.so`; they are not a
  product transport or a controlled cross-device benchmark. A 2026-09-26
  live rerun with the archived worker failed at the first response on both
  phones; a subsequent pinned-source rebuild passed on both, with a 120.364 µs
  Razr+ warm median. See `docs/receipts/dspqueue-live-reproduction-20260926.md`.
  Preserve the distinction between archived-worker failure, source-built
  diagnostic success, and the still-unbuilt product transport.
- DSPQueue-style shared-memory dispatch is physically evidenced as a
  historical diagnostic, not a proved product path. Distinguish one-time
  FastRPC bootstrap from per-job signaling and queue traffic; the pinned
  upstream fallback can signal through FastRPC. Do not claim Queue Monitor
  support, a 0.1 ms dispatch, or a Razr+/S23 cause without a same-artifact
  physical receipt.
- Preserve user changes, back up before overwriting, and obtain explicit
  approval before deletion, history rewrite, or push.
