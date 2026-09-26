# ReadyToRun payload audit — 2026-09-26

The existing 96-assembly archive under ignored `build/` was scanned with
`PEReader`. Sixty-two images have a nonzero CLI managed-native-header size,
including `System.Private.CoreLib.dll`. The other 34 have no managed-native
header and set the IL-only flag. Earlier build messages counted ReadyToRun
candidates but did not exclude them from assembly selection. Historical
packaging receipts have been corrected; the existing APK is not an
R2R-free artifact.
All 62 managed-native headers carry the R2R signature. Their observed flag
values do not set the stripped-IL-bodies bit; this is an input observation,
not proof that an IL-only rewrite is correct.

`setup-kokoro.ps1` now rejects any selected R2R image before writing the
assembly archive and checks every image again before emitting the assembly
store. Its actual Step 4 run verified the pinned sources and package hashes,
classified the same 101 R2R candidates, then stopped because 62 selected
images still carried R2R. No new APK was signed or installed. The standalone
archive gate rejects the existing archive as expected.

`Model.Store.psm1` also requires downloaded managed model assemblies to have
no managed-native header and to set the IL-only flag. Its signed-install test
passes for an IL-only image and rejects a signed test image whose managed-native
header is nonzero. The production-closure source check passes.
The signed-install test was repeated in 15 fresh PowerShell processes. Its
synthetic manifest originally re-serialized a timestamp into a form that
intermittently failed parsing before PE inspection; the fixture now preserves
the original signed JSON except for the test assembly hash.

The [ReadyToRun format description](https://github.com/dotnet/runtime/blob/ab19415702aa8139d5369e47c73edb47343c34ad/docs/design/coreclr/botr/readytorun-format.md#L17-L26)
states that a single-file R2R image retains input IL and metadata. The
[CoreCLR PE decoder](https://github.com/dotnet/runtime/blob/ab19415702aa8139d5369e47c73edb47343c34ad/src/coreclr/utilcode/pedecoder.cpp#L1143-L1237)
has separate checks for images with and without an R2R header. These sources
guide, but do not yet validate, an IL-only re-emitter for the pinned runtime
pack. A header-only edit is not accepted as an R2R cut. No R2R-free build or
device startup is claimed.
