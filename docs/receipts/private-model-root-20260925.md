# Private model-root and signed load gate — 2026-09-25

The independently generated NativeActivity host exposes CoreCLR's base
directory as `NativeHost.PrivateDataRoot()`. Its native bootstrap supplies
`ANativeActivity.internalDataPath` to CoreCLR as
`APP_CONTEXT_BASE_DIRECTORY`. A rebuilt, locally signed APK was installed
and launched on both attached devices; each logged that the resulting
directory exists. The marker does not log the path.

`Model.Store.psm1` now revalidates the signed manifest, runtime ABI, contract
version, expiry, payload size, SHA-256, and managed assembly name when reading
the active pointer. `LoadActive` loads only the result of that revalidation.
The fresh Windows test passed signed admission and load, and rejected a
modified stored manifest before load. `Test-ProductionClosure.ps1` passed.

The rebuilt APK is 40,967,555 bytes, under the 40 MiB limit, with SHA-256
`F59740E9F54255FF719366EB29D7281F9E49821FFD01B988FF1E5FCDE15C63F1`.
This APK remains model-less: the store source and a model-signing public key
are not yet embedded, and the Android startup does not invoke `LoadActive`.
The Windows test uses a test assembly, not a stock Kokoro synthesizer. No
speech or on-device model-loading claim follows from this receipt.
