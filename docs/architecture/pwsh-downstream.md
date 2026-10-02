# Pwsh base and Kokoro downstream boundary

Kokoro-Hexagon is a downstream TTS engine for the Xamarin-independent Pwsh
appliance. `lib/manifest.json` pins Pwsh commit
`ba84d1921c272699b45e75e21360a454fb647f7c`, including the exact `setup.ps1`
and `lib/manifest.json` content identities. `tools/Get-PwshUpstream.ps1` fetches
only those immutable files into this repository's ignored `build/` tree and
verifies length and SHA-256 before promotion.

## Ownership

Pwsh owns the generic Android substrate:

- NativeActivity and CoreCLR startup;
- the IL-only assembly store and minimal SMA payload;
- package acquisition, integrity validation, APK assembly, and signing;
- `Profile.ps1` discovery and execution;
- the native activity handle and `AppContext.BaseDirectory` private-data root;
- generic managed/native binding, extension admission, transport, and media
  facilities accepted upstream.

Kokoro owns the TTS engine:

- text and phoneme admission, voice selection, and model controls;
- stock weight ingestion and the weight-bearing managed model assembly;
- whole-graph lowering and direct Hexagon emission;
- DSP session descriptors, execution receipts, and speech cancellation;
- PCM scheduling and Kokoro-specific audio policy.

The engine may use generic upstream AAudio and transport facilities, but Pwsh
must not acquire Kokoro graph, voice, checkpoint, phonemization, or Hexagon
model semantics.

## Legacy fork disposition

`setup-kokoro.ps1` remains temporarily as a migration and equivalence oracle.
It is not the upstream base authority. Its current diff contains obsolete
Xamarin, DEX, Java-peer, type-map, and package-version machinery that must not
be ported forward.

The only setup-level Kokoro behavior worth extracting is:

1. the model graph/control identity, now owned by
   `src/build/Get-KokoroModelContract.ps1`; and
2. the typed appliance operation contract, which must move into the admitted
   downstream engine session rather than the generic Pwsh host.

The legacy `PrivateDataRoot` method is unnecessary because pinned Pwsh already
sets `APP_CONTEXT_BASE_DIRECTORY` from `ANativeActivity.internalDataPath` and
publishes the native activity handle. `Model.Store.psm1`, `Native.Binding.psm1`,
and `Audio.AAudio.psm1` are already independent downstream modules and do not
belong inside the monolithic setup fork.

The extracted model contract deliberately reports `Complete = false`: its two
parsed decoder nodes do not represent the full phoneme-to-PCM computation.

`tools/Build-KokoroEngineAssembly.ps1` now consolidates verified weight and
phoneme/voice parts into one IL-only `Dev.MansfieldPlumbing.Kokoro.Model` DLL.
The current contract provides phoneme admission, voice-row selection,
vocabulary and graph identities, model-contract version, and
`SynthesisReady = false`. It intentionally omits `SynthesizePhonemes` until
the full direct backend exists.

## Migration gates

The repository-shape migration is complete: active builders and gates consume
the immutable Pwsh pin, the consolidated DLL is the sole downstream engine
identity, signed-store paths derive from that admitted identity, and no active
source reads `setup-kokoro.ps1`. The legacy file remains preserved only because
deletion requires separate change approval and later same-artifact equivalence
evidence.

The remaining items are product-integration gates, not host-fork migration:

1. Verify the immutable Pwsh pin with `tools/Get-PwshUpstream.ps1` and
   `tools/Test-PwshDownstream.ps1`.
2. Build and verify the pinned Pwsh base without Kokoro source or artifacts.
3. Admit the signed consolidated Kokoro model assembly from private storage
   after restart.
4. Expose a bounded typed phoneme request through the downstream engine
   session; user text remains data and is never evaluated as PowerShell.
5. Connect the complete direct phoneme-to-PCM Hexagon path to resident AAudio.
6. Delete `setup-kokoro.ps1` only after same-artifact package, startup, model
   admission, numerical, and physical-device equivalence gates pass.

No migration gate permits Xamarin, `Mono.Android`, `Java.Interop`,
`libmonodroid`, `libxamarin-app`, Xamarin DEX, or .NET-for-Android runtime
dependencies to re-enter the base or engine.
