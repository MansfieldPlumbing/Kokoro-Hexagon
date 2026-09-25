# Kokoro managed lowering and archive — 2026-09-24

Target selection: Android arm64, NativeActivity/CoreCLR, Minimal payload.

`setup-kokoro.ps1 -Step 4 -KeepIntermediates` consumed the pinned Pwsh package
and specification manifest, emitted the product entry assembly, translated the
single donor `Pwsh.dll` assembly-order slot, and selected 96 managed assemblies.

Observed product assembly:

```text
Name       Kokoro-Hexagon.dll
Bytes      15360
SHA-256    B6A851E53F50B512C334D7E2C7EB77257E78E1938864F97DE9CFAEF907D5E56E
Method     int DispatchOperation(string)
Operations status, ping, receipt, speak, benchmark, transcribe
Unknown    0
```

The dispatcher originated in
`src/appliance/Kokoro.ApplianceExpression.ps1`. The build parsed and verified
that source, compiled its LINQ expression tree through the donor's persisted
method machinery, and placed the resulting method in the generated managed PE
assembly. The Android runtime path no longer loads `Profile.ps1` or calls
`PowerShell.AddScript`; it opens a minimal SMA session and warms the persisted
`status` operation.

The external artifact archive contained 96 DLLs plus `assemblies.json` with
per-file byte count, SHA-256, package id and package path. Generated artifacts
remain outside Git.

This receipt proves build-time lowering and managed artifact preservation. It
does not yet prove phone startup, warm dispatch, speech TTFT or a smaller APK.
The selected donor list still includes `Mono.Android.dll` (41,887,544 bytes),
`Java.Interop.dll` and `Mono.Android.Runtime.dll`; removing the unused recovery
activity from the NativeActivity entry assembly is the next payload gate.
