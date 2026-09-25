# Model-less NativeActivity appliance

Date: 2026-09-25

`setup-kokoro.ps1 -Headless -Step 11` completed the full ARM64 build from 27
pinned source specifications and 14 catalog-hash-verified packages. The build
classified 313 IL images and 16 native payloads, excluded 101 ReadyToRun
images, and selected 96 IL assemblies for the runtime store.

The independently read-back unsigned APK contained 12 entries. The production
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
