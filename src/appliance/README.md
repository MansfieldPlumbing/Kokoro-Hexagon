# Kokoro appliance

This directory owns the source for the intended downloadable Kokoro-Hexagon
appliance. The current base APK proves only a Xamarin-free PowerShell 7
NativeActivity/CoreCLR host that launches on two phones. It embeds no Kokoro
model and does not yet load one, execute the full model, or produce speech.
Direct Hexagon execution remains a separate integration gate.

The appliance is a product boundary, not a build-output directory:

- source and packaging policy live here;
- model creation and admission live outside the APK; `src/export` is historical
  oracle material only;
- ARM64 and Hexagon instruction emission remains in `src/emit`;
- device-side diagnostic probes remain in `src/runspace` and are not appliance
  dependencies;
- generated APKs, packed weights, native libraries, audio, and receipts go to
  `..\Build\Kokoro-Hexagon\appliance` and are not committed.

## Release gate

A build is downloadable only after one immutable artifact passes all of these
checks on the physical target:

1. The APK contains the owned Pwsh NativeActivity/CoreCLR host and contains no
   Xamarin runtime libraries or application DEX.
2. Every external input and packaged native library matches its pinned
   SHA-256 manifest entry, and the model-less APK is smaller than 40 MiB.
3. Each separately installed model DLL passes signed-manifest, compatibility,
   length, hash, managed-identity, and transactional-activation checks.
4. DSP state is initialized and warmed before the measured synthesis request.
5. Output matches the approved reference gate and valid PCM plays through the
   device speaker.
6. Cold time to first audio, warm time to first audio, sustained synthesis
   rate, peak resident memory, and transport/compute timing are recorded.
7. Application startup and device state are restored after the test.
8. The Windows compute-node demo accepts framed requests over AOA without an
   adb process in the command or data path.

The first release target is ARM64 on the Samsung Galaxy S23. Additional SoCs
and ABIs require their own device receipts; compatibility is not inferred from
the V73 result.

## Android platform surface

The release uses `android.app.NativeActivity`. Its manifest retains the
declarative `MAIN` and `LAUNCHER` filter and, for the Windows compute-node
mode, the standard USB accessory attachment filter for the pinned Kokoro AOA
identity.
The runtime does not depend on managed `Intent`, `ContentResolver`, activity
result, Xamarin, Mono.Android, Java.Interop, application DEX, or provider
types.

Platform operations use the narrowest owned boundary:

- the application files directory comes from `ANativeActivity`;
- environment variables and file mapping use libc;
- diagnostics use liblog;
- DSP access must use a source-defined direct transport after its device gate;
- audio output uses a pinned native Android audio API after a hardware gate;
- JNI is added only for a capability that has no adequate native API. AOA is
  one such boundary: the host obtains the granted accessory descriptor through
  `UsbManager.openAccessory`, then ordinary bounded reads and writes own the
  established pipe.

The diagnostic scripts in `src/runspace` still target the older host and may
reference `$Activity` or `Android.*` types. They are evidence tools, not
dependencies of the release appliance.

`src/runspace/Aoa.Appliance.ps1` is the diagnostic managed-host endpoint. The
release port preserves its framed protocol and allowlist, but obtains the file
descriptor from the NativeActivity/JNI boundary rather than Xamarin types.
The exact accessory identity and activity declarations live under
`src/appliance/aoa`; the build merges the fragment into its NativeActivity and
packages the XML filter unchanged.
