# Hexagon linear-tile emission gate, 2026-09-27

`src/emit/Kokoro.LinearTile.ps1` emits an FP32 row-major affine tile for the
3×768→512 ALBERT-to-BERT projection shape. PowerShell generates and validates
the instruction stream; its scalar multiply-add loop is in the emitted V73
routine, not in the product PowerShell runspace. The tile takes a 12-byte
geometry record, input, contiguous weight+bias buffer, and output, with
length, pointer, and exact-dimension guards. It uses separate `sfmpy` and
`sfadd` rounding, so numerical parity with the stock framework remains to
be measured, not assumed.

`tools/Test-HexagonEmission.ps1 -Kernel KokoroLinearTile
-OutputDirectory build/hexagon-emission` passed. The PowerShell-emitted ELF
is 8,384 bytes; the routine is 504 bytes; its byte stream matched the
independent pinned assembler exactly. Library SHA-256:
`EB507396900B71293E25B4B0C1B276D0EE574FF2E710088F54993A6EE117C37D`.
It has zero imports and relocations. The assembler digest is
`fc64c65aca06186106a73ba93e65ddf7c906bf4905b786dc748d3f034401ea27`.

This is not a physical-device or numerical gate. The currently attached S23
has `dev.mansfieldplumbing.kokorohexagon` installed, but `run-as` reports that
package is not debuggable. The historical AndroidSMA preview probe is not a
substitute for exercising the independent Kokoro appliance. A verified
private-artifact intake and dispatch path in that appliance is still needed
before this tile can be compared on-device with the same input and weights.
