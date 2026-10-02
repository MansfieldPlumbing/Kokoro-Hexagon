# Model-less appliance with Kokoro managed namespace

Date: 2026-09-25

The external Build directory was empty before this run. The managed host
namespace is `Dev.MansfieldPlumbing.Kokoro`; the Android package remains
`dev.mansfieldplumbing.kokorohexagon`.

`setup-kokoro.ps1 -Headless -Step 4 -KeepIntermediates` verified 27 local
specifications, 22 pinned upstream sources, and 14 package catalog hashes;
it selected 96 managed assemblies after classifying 101 ReadyToRun images.
`Test-WindowsModelAssembly.ps1` then loaded the regenerated
`Kokoro-Hexagon.dll` in a fresh Windows process, resolved the renamed
`NativeHost`, and passed the graph/control check.

`setup-kokoro.ps1 -Headless -Step 11` completed APK Signature Scheme v2
verification. The signed APK is 40,967,479 bytes with SHA-256
`E62AC595D7D77D0793D1CFBD8EA04DBAF2C25647268AC61D1866925BA6704518`.
An independent ZIP read-back found 12 entries, no DEX, Mono/Xamarin library
name or model-like payload name. There was no separately named ReadyToRun DLL,
but a later PE-header audit found 62 ReadyToRun images among the selected
96 assemblies. The assembly-store
bytes contain `Dev.MansfieldPlumbing.Kokoro` and not the prior managed
namespace.

That exact APK installed and launched on both connected physical devices.
Each application process remained live three seconds after launch. No APK was
tracked in this Git repository and no push or release was performed.

This is a host packaging and startup receipt only. The APK has no Kokoro
model and does not establish model loading, direct Hexagon synthesis, or
audible speech.
