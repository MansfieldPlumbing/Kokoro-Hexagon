# PowerShell-emitted Hexagon ELF executes on the S23

## Result

PowerShell emitted both the ELF container and all 53 Hexagon instructions in
`libkqnn_emit_skel.so`. The S23's existing FastRPC loader opened the unsigned
library, dispatched calls, returned correct arithmetic, rejected invalid calls,
and closed the handle. No compiler, assembler, linker, or qaic output is used
to produce the loaded library.

- ELF: 8,384 bytes; code: 212 bytes; ELF32 little endian; EM_HEXAGON; e_flags 0x73.
- SHA-256: `95743649561D263E1BC1CBF703D521619F0A79B0E0F64DD5248956B35BFFDBD1`.
- No DT_NEEDED dependencies, imported functions, or relocations.
- Uses the phone's existing `libcdsprpc.so`, unsigned cDSP process and DSP loader.
- Entry: `kqnn_emit_skel_handle_invoke(uint64 handle, uint32 scalars, remote_arg *args)`.
- Method 2: two int32 input values, one int32 output, addition modulo 2^32.

## Reused implementation and target contract

`tools/Emit-HexagonProbe.ps1` extracts an allowlist of ELF functions from the
existing Pwsh writer at commit `e215a96`, after checking its complete SHA-256
and the provenance manifest. It parses the source before loading only those
functions. It does not execute the Pwsh build or change the Pwsh repository.
The adapter permits an empty dependency list and adds the ABI-mandatory
`DT_HEXAGON_VER=3` entry. ELF32 layout, program headers, symbols, SysV hash,
dynamic table and section table come from the existing writer.

The Hexagon target supplies named instruction encoders in `src/emit/Hexagon.ps1`.
Every instruction is a singleton packet and is decoded back before emission.
The SDK assembler independently produces exactly the same 212 code bytes from
the generated assembly listing. Its output is a verification artifact only.

Sources:

- Pwsh `setup.ps1` SHA-256:
  `44432CB738EDB13FB7B2AEA999C265A94F5EEAC867DC4E4E39C1503E0E813D62`.
- Pwsh `lib/manifest.json` SHA-256:
  `C2B3C6D044EACBACAD7E7B1C58F18EA8AE6FB836B421B5EC3788D009E57CEDC4`.
  ELF constants are checked against that manifest's pinned LLVM inputs.
- Qualcomm V73 Programmer's Reference Manual, 80-N2040-53 Rev. AB,
  SHA-256 `44EBAFD1119F725BD3C6FFB87499232520DF9A0A6E3E3DC6EA329B15DAED11A8`.
  Packet parse bits p. 145; instruction encoding tables pp. 157, 163, 189,
  206, 214, 242 and 304.
- Hexagon Tools 19.0.04, Application Binary Interface User Guide,
  SHA-256 `12157E376C44E1B8D4910FCD8B78F4FF6297984D174A858DA455AA3CC6ED821F`.
  Fixed parameters place the handle in r1:r0, scalars in r2, arguments in r3.
  The dynamic section requires DT_HEXAGON_VER, with value 3 for this ABI.
- SDK 6.4.0.2 `incs/remote.h`, SHA-256
  `F61E1F92C88DBC642D17DF3855DD6FF9D5E605D442A5DE73B8A7E023C225BC0D`.
  The DSP remote_arg is 8 bytes; the arm64 host remote_arg is 16 bytes.
- Existing generated `kqnn_skel.c`, SHA-256
  `6EAADF253BA344181782BDA208084BF479B85986F513AA13744A262D2D6B99B7`.
  Its open/close dispatch establishes the handle interface wire convention.
- SDK assembler SHA-256
  `FC64C65ACA06186106A73BA93E65DDF7C906BF4905B786DC748D3F034401EA27`.

## Device receipt

Galaxy S23, SM8550 / Hexagon V73, existing AndroidSMA preview host:

```text
Job=hexagon-emitted-elf
LibrarySHA256=95743649561D263E1BC1CBF703D521619F0A79B0E0F64DD5248956B35BFFDBD1
UnsignedPdRc=0
OpenRc=0
Add a=19 b=23 expected=42 got=42 rc=0
Add a=-200 b=73 expected=-127 got=-127 rc=0
Add a=2147483647 b=1 expected=-2147483648 got=-2147483648 rc=0
Add a=0 b=0 expected=0 got=0 rc=0
Reject=short-input rc=14
Reject=short-output rc=14
UnsupportedMethodRc=20
WrongSignatureRc=20
CloseRc=0
Passed=True
```

The first host test incorrectly required preservation of an output-only buffer
on a failed invocation. `remote.h` makes no such promise. The final test checks
error codes and only reads results after success; the DSP library bytes were
unchanged. This receipt does not claim buffer preservation on error.

## Reproduction and scope

Host generation: `tools/Emit-HexagonProbe.ps1`.
Independent instruction check: `tools/Test-HexagonEmission.ps1` (WSL SDK 19.0.04).
Device test: `src/runspace/HexagonEmitProbe.ps1`, using the existing AndroidSMA
preview host and a separately staged, hash-checked delegate factory.
Device selection stays in `KOKORO_QNN_SERIAL`.

All generated output lives under `..\Build\Kokoro-QNN\hexagon-emission`.
The phone's previous startup scripts were backed up and restored; their hashes
matched before and after the test. Nothing was committed or pushed.

Controls: pinned source extraction and parse validation (SSDF/SI-7), exact
signature and buffer-length checks, bounded host allocations, zeroing/freeing
host buffers and handle closure (AC-6/SC-4). The existing host uses FullLanguage
for .NET native interop; this is not a ConstrainedLanguage claim.

This proves our emitter-to-loader execution path and buffer ABI. It does not
establish a minimal ELF, shared-memory zero-copy operation, HVX/HMX performance,
or a completed Kokoro backend. No runtime executable mapping was used. The
artifact is a native ABI probe, not a QNN graph or a Kokoro inference result.
