# Model-less NativeActivity appliance

Date: 2026-09-25

Historical packaging and startup receipt only. The measured APK predates the
current startup-only dispatch source. It is not a release candidate and does
not prove model loading, direct Hexagon transport, or Kokoro speech.

`setup-kokoro.ps1 -Headless -Step 11` completed the full ARM64 build from 27
pinned source specifications and 14 catalog-hash-verified packages. The build
classified 313 IL images, 16 native payloads, and 101 ReadyToRun candidates,
then selected 96 managed assemblies for the runtime store. A subsequent
PE-header audit found that 62 selected images still carried ReadyToRun code.
The inventory classification did not exclude them.

The independently read-back unsigned APK contained 12 entries. The packaging
closure gate found no DEX, `libmonodroid.so`, or `libxamarin-app.so`; the
manifest declares `android.app.NativeActivity` with `hasCode=false`; and the
native host imports only libc, liblog, CoreCLR, and the assembly store.

The APK Signature Scheme v2 verifier accepted the final artifact. Its size was
40,967,549 bytes, 975,491 bytes below the strict 40 MiB limit. The same signed
APK installed and launched on physical SM8550 and SM8635 devices; each process
remained live after the three-second startup check.

This receipt proves the base host and packaging boundary only. The APK contains
no Kokoro model, and the private model store is not yet wired into its startup
or AOA control path.
