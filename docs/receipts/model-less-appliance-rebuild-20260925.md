# Model-less appliance rebuild before managed-namespace change

Date: 2026-09-25

This receipt covers a `status`-only NativeActivity/CoreCLR/SMA base host built
before the namespace changed to `Dev.MansfieldPlumbing.Kokoro`. The external
Build directory was subsequently cleared. It does not establish that the
renamed source has been built, model loading, direct Hexagon speech execution,
or audible Kokoro synthesis.

The two Android header URLs in `lib/pwsh-build-manifest.json` were changed to
GrapheneOS mirrors at the same pinned commits. Each fetched file matched its
unchanged SHA-256 pin. Step 1 verified all 27 local specifications and all 22
remote source bytes. Step 2 verified 14 package SHA-512 catalog entries.

`setup-kokoro.ps1 -Headless -Step 11` completed through APK Signature Scheme v2
verification. Its assembly-selection gate classified 101 ReadyToRun images and
rejected them from the 96-assembly runtime store. The resulting signed APK is
40,967,465 bytes, below 40 MiB, with SHA-256
`868A887E04A0809C3178A25C9C312A226CD71442F97EDB3EDB294F834745CD2A`.
An independent ZIP read-back found 12 entries, no DEX or Mono/Xamarin native
library names, no ReadyToRun-named DLL, and no model-like payload name.

The same signed APK installed with package replacement and launched on both
connected physical devices. Three seconds after launch, the application
process was live on each. `Test-ApplianceExpression.ps1` and
`Test-ProductionClosure.ps1` both passed; the former admits only `status` and
the latter is a source-policy check, not a speech test.
