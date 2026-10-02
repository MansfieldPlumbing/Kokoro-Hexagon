# Kokoro Android appliance boundary

Kokoro-Hexagon is a downstream speech engine for the Xamarin-independent Pwsh
NativeActivity/CoreCLR/System.Management.Automation appliance. Pwsh owns the
generic Android host. This repository owns the Kokoro model, its admitted
inputs, lowering, direct Hexagon code, speech-session contract, and audio
policy. Live direct-path Kokoro speech is not yet implemented; `ROADMAP.md` is
the current product gate.

## Build graph

`lib/manifest.json` pins the Pwsh repository, full commit, `setup.ps1`, and
Pwsh manifest by byte count and SHA-256. `tools/Get-PwshUpstream.ps1` retrieves
only those files into the ignored `build/upstream/` tree and verifies them
before use. `src/build/Import-PwshBuildFunction.ps1` parses that verified source
and imports only the explicitly admitted deterministic assembly-emission
helpers. The active downstream build does not read `setup-kokoro.ps1` or the
separate `C:\Dev\Pwsh` checkout.

The retained `setup-kokoro.ps1` is an unofficial historical fork. It is not the
host authority, product builder, or release lineage.

Pwsh's pinned build owns NativeActivity/CoreCLR startup, SMA, generic extension
admission, and generic package controls. The source gate verifies its legacy
DEX, Mono, and Xamarin payload rejectors. Kokoro code must not add
`Mono.Android`, `Java.Interop`, `libmonodroid`, `libxamarin-app`, Xamarin DEX,
or .NET-for-Android application-runtime dependencies.

## Model and runtime boundary

The downstream assembly identity is
`Dev.MansfieldPlumbing.Kokoro.Model`. The current reproducible IL-only artifact
contains all 548 admitted FP32 tensors, their index, the pinned phoneme contract,
the `af_heart` voice rows, and the current graph identity. It reports
`SynthesisReady = false` and intentionally exposes no synthesis entry point
because the full phoneme-to-PCM graph is not yet implemented.

`src/runspace/Model.Store.psm1` admits a model using a signed manifest, exact
length and SHA-256, compatibility identifier, and managed assembly identity.
It stores the DLL under a content-addressed private path using the signed
assembly name, atomically replaces the active pointer, and loads the admitted
payload only after process restart. The packaged Pwsh appliance has not yet
wired this store or demonstrated speech.

At inference time the admitted compiled model and minimal host must invoke the
cDSP and deliver PCM to AAudio. A PowerShell runspace must not orchestrate model
operators or perform tensor arithmetic. QNN, ONNX Runtime, Python/PyTorch, and
LLVM remain reference or comparison tools only.

## Evidence boundary

The current Windows gates prove immutable Pwsh source admission, deterministic
model assembly construction, fresh-process IL-only loading, resource integrity,
and signed-store admission. They do not prove Android packaging, full Kokoro
semantics, direct DSP execution, audio quality, time-to-first-audio, or audible
speech. Device claims require same-artifact physical receipts.
