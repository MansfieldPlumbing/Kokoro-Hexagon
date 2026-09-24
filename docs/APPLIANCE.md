# Kokoro Android appliance

The product is a speech application with an embedded, deliberately reduced
PowerShell runtime. PowerShell is an implementation substrate, not a permission
boundary or a USB command language.

## Build graph

`setup-kokoro.ps1` is a fork of the pinned Pwsh build graph. It emits and checks
the Android manifest, managed host, XABA assembly store, native ELF libraries,
APK archive and v2 signature from one PowerShell program. Its package provenance
is isolated in `lib/pwsh-build-manifest.json`; Kokoro and QNN provenance remains
in `lib/manifest.json`.

The product identity is `dev.mansfieldplumbing.kokorohexagon`. The admitted host
is NativeActivity/CoreCLR only. Xamarin, Mono, DEX, Android managed bindings and
the recovery activity are not part of the intended release payload.

With `-KeepIntermediates`, selection also saves every chosen managed assembly
under the external build directory and writes `assemblies.json` with byte counts,
SHA-256 values and package provenance. The APK still consumes the mapped XABA
store; the archive exists for diffing, reuse, trimming and release artifacts.

## Resident provider contract

`src/appliance/provider/ProviderHost.cs` preserves the original scripted-provider
control for A/B measurement. The product build graph now lowers the admitted
operation tree into `Kokoro-Hexagon.dll`:

1. create one runspace and keep it resident;
2. create the least-capability initial session state rather than default cmdlets;
3. invoke persisted typed methods from the signed entry assembly;
4. pass text as UTF-8 data and receive bounded binary results;
5. never load a profile from writable storage or evaluate source received from USB;
6. dispose the runspace only when the Android process shuts down or recovers.

The C# project is a behavioral baseline, not a second application framework, and
is not packaged into the APK. Its scripted warm-dispatch cost is retained so the
physical-device A/B can quantify the benefit of persisted methods.

## Model boundary

The current runtime consumes the pinned upstream Kokoro-82M checkpoint. Graph
splits, QNN contexts, emitted Hexagon kernels and quantized device artifacts are
runtime derivatives, not a separately trained model. A separately published
model becomes appropriate when weights or architecture change, such as a baked
integer checkpoint, trained speaker material or a FiLM-based generator.

An optional language or perception model sits in front of this contract. It may
produce text and speech-planning hints, but it does not own phonemization, audio
playback or the measured Kokoro synthesis path.

## Evidence boundary

The Windows provider gate proves the scripted baseline's lifecycle, profile
integrity, AST parsing, binary return semantics and warm reuse. The build graph
separately proves that the admitted operation tree persists into the generated
entry assembly. Neither proves Android startup time, APK size, phone memory use,
AOA service behavior or speech TTFT. Those claims remain gated on a signed APK
and physical-device receipts.
