# Proposed Pwsh upstream contributions from Kokoro-Hexagon

The contribution boundary is generic Android infrastructure. Kokoro speech
semantics remain in Kokoro-Hexagon. Every proposed change must remain fully
independent of Xamarin, `Mono.Android`, `Java.Interop`, `libmonodroid`,
`libxamarin-app`, Xamarin DEX, and the .NET-for-Android application runtime.

## PR 1: generic AAudio lifecycle module

Contribute the generic mechanism behind `src/runspace/Audio.AAudio.psm1`, not a
Kokoro player. Bind the pinned Android NDK AAudio C API through Pwsh's generic
managed/native binding layer. The public contract should cover:

- validated sample rate, format, channel count, and bounded frame writes;
- open, start, drain, cancellation, stop, and idempotent close;
- one resident stream reused across multiple chunks;
- frame counters, xrun count, capacity, and frames-per-burst receipts;
- deterministic teardown after partial writes and exceptions.

Keep tensor arithmetic, sample synthesis, speech chunking, and model scheduling
out of Pwsh. PowerShell may control stream lifecycle and submit bounded PCM
chunks; it must not process individual samples on the hot path.

Admission gates should include AST validation, exact pinned `AAudio.h`
provenance, no runtime source compilation, package inspection for forbidden
Xamarin/Mono payloads, and physical runs on each claimed backend. A tone is an
audio-binding gate only, never a TTS result.

## PR 2: private-storage managed extension admission

Generalize the mechanism demonstrated by `src/runspace/Model.Store.psm1` into
a Pwsh extension store:

- signed manifest and dedicated trust anchor;
- compatibility, exact-length, SHA-256, and managed-identity validation;
- staged writes followed by atomic active-pointer replacement;
- load only at process start, with restart required after activation;
- rollback, interrupted-write, tamper, expiry, and incompatible-ABI gates.

This PR has a Xamarin-independent Android prerequisite. The pinned CoreCLR
cryptography implementation requires its Android native cryptography library
to receive `JNI_OnLoad` through Java-side library loading; loading it only as a
CoreCLR P/Invoke dependency does not initialize its `JavaVM*`. Pwsh should use
its planned fixed emitted `NativeActivity` subclass to call
`System.loadLibrary` and package the pinned runtime's companion cryptography
DEX. That narrow emitted Java bridge must remain independent of Xamarin,
`Mono.Android`, `Java.Interop`, `libmonodroid`, and `libxamarin-app`. Gate
SHA-256 and ECDSA on every claimed backend before admitting an extension.

The upstream abstraction should know only about admitted managed extensions.
Kokoro's model identity, weights, graph schema, and voice resources remain
downstream.

## PR 3: typed extension session boundary

Expose a small compiled contract for extension load, request, cancellation,
bounded binary output, receipts, and disposal. Requests are data and must not
be parsed or evaluated as PowerShell. The generic host owns lifecycle and
backpressure; an admitted extension owns request semantics. Kokoro can then
implement text/phoneme requests without adding speech behavior to Pwsh.

## PR 4: AOA transport after the local contract is stable

AOA should carry the same typed session frames over a versioned, bounded,
bidirectional transport with correlation IDs, cancellation, timeouts,
backpressure, reconnect, and structured errors. It must not require ADB in the
product data path. This PR should follow, not precede, the in-process extension
session and AAudio lifecycle gates.

## PR 5: admitted application profile and branding inputs

The pinned Pwsh builder currently fixes `ic_launcher.png` to its own lib
manifest and does not package a downstream `Profile.ps1` or modules. Add a
generic, integrity-declared application-input contract for:

- one launcher icon with exact length, SHA-256, PNG dimensions, and resource
  name validation;
- one startup profile and a bounded module set, each with exact length and
  SHA-256;
- a package/application identity supplied as validated data rather than source
  rewriting; and
- archive readback proving every admitted input is present byte-for-byte before
  signing.

The generic host must not know Kokoro names, UI state, speech controls, or model
semantics. Kokoro's `Build-KokoroFacadePackage.ps1` already stages the proposed
input shape for validation, but it is not an APK builder and must not patch the
pinned Pwsh setup source.

## Keep downstream

Do not upstream Kokoro graph construction, checkpoint or voice handling,
phonemization, duration/F0/noise prediction, AdaIN, vocoding, direct Hexagon
kernels, DSP transport policy, speech streaming boundaries, or audio-quality
evaluation. Those are engine behavior, not Pwsh substrate.
