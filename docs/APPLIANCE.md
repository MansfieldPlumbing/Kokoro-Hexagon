# Kokoro Android appliance

The product is a PowerShell 7 speech application on an unsupported Android
target. PowerShell owns the authored model, lowering, control, and runtime
logic; NativeActivity/CoreCLR/System.Management.Automation are the host
substrate. This document describes that host boundary, not a completed
synthesizer. Live direct-path Kokoro speech is not yet implemented.
`ROADMAP.md` is the current product gate.

## Build graph

`setup-kokoro.ps1` is this repository's independent, unofficial fork of the
Pwsh build graph. It is not an official Pwsh build and does not track upstream
changes automatically. The active `C:\Dev\Pwsh` checkout is neither an input
nor an output. The fork emits and checks the Android manifest, managed
host, XABA assembly store, native ELF libraries, APK archive and v2 signature
from one PowerShell program. Its package provenance is isolated in
`lib/pwsh-build-manifest.json`; Kokoro source and historical
oracle provenance remain in `lib/manifest.json`.

Pwsh does not perform Kokoro model lowering or speech. Those belong to this
repository's separately built model artifact and direct backend.

The product identity is `dev.mansfieldplumbing.kokorohexagon`. The admitted host
uses the managed namespace `Dev.MansfieldPlumbing.Kokoro` and is
NativeActivity/CoreCLR only. Xamarin, Mono, DEX, Android managed bindings and
the recovery activity are not part of the intended release payload.

With `-KeepIntermediates`, selection also saves every chosen managed assembly
under the external build directory and writes `assemblies.json` with byte counts,
SHA-256 values and package provenance. The APK still consumes the mapped XABA
store; the archive exists for diffing, reuse, trimming and release artifacts.

## Resident runtime boundary

The base APK has proved NativeActivity/CoreCLR startup only. A product runspace
must still be wired to a verified model DLL, bounded request and PCM contracts,
direct DSP execution, and AAudio. The parsed two-node decoder description
currently contributes graph identity to the host assembly; it is not executable
Kokoro synthesis. Historical provider benchmarks are not an implementation
contract for this product.

## Model boundary

The intended runtime consumes a verified managed model DLL derived from the
pinned upstream Kokoro-82M checkpoint; it does not read that checkpoint.
Historical QNN contexts are reference artifacts, not runtime derivatives in
the product path. The current DLL experiments contain phoneme admission or
weights separately and are not a complete model. Quantized variants retain
their own precision and release identity.

An optional language or perception model sits in front of this contract. It may
produce text and speech-planning hints, but it does not own phonemization, audio
playback or the measured Kokoro synthesis path.

## Evidence boundary

The Windows provider gate is a historical baseline. The build graph proves
only persistence of the current incomplete graph identity into the generated
entry assembly. The signed base APK has separately passed size and launch
checks on two phones. None of these proves model loading, direct DSP transport,
speech quality, or speech time-to-first-audio.
