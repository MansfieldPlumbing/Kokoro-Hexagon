# Decoder AdaIN coefficient corrections, SM8550, 2026-10-10

Proof steps 1 and 2 of `docs/adain-control-stream-design.md`. Hello world decoder (65 frames,
`build/decoder16-fixture-20261009m4d`), `KokoroDecoder16Run` capacity 65 with run-time frames, chunks [0,41) and
[24,65). 3 runs per job; DSP time is the median region time.

| Check | Result |
| --- | --- |
| `Corrected` with zero deltas against ordinary chunks (`Export`, own moments) | bit-exact, both chunks |
| `Corrected` with oracle deltas against supplied whole-utterance moments | bit-exact, both chunks |
| Stitched chunks against one pass on the DSP, own moments | 12.21 dB |
| Stitched chunks against one pass on the DSP, oracle corrections | 61.97 dB |
| DSP time per chunk, own / corrected | 13.405 / 13.472 ms and 13.420 / 13.470 ms |

The oracle delta for each site is the one pass's coefficients minus the chunk's local coefficients, both taken from a
`SuppliedExport` run (local coefficients computed on the supplied trajectory), subtracted as wrapping int32. Deeper
sites therefore see the corrected activations their delta was measured on. The correction (DMA of the deltas and a
`vadd-w` loop per site) costs about 0.06 ms per chunk. `SuppliedExport` (23.9 ms) is a measurement mode that computes
both coefficient sets.

The default emission (`Accumulate`) is byte-identical to the previous commit (capacity 96: fixed `EF4E0713...`,
run-time frames `B119BCB5...`).

| Artifact | SHA-256 |
| --- | --- |
| Skel, Export | `58F6173058ADA4C3B21CF5637C3BDC11CE83FA5D0657EDF1C6ACF5856AD22420` |
| Skel, SuppliedExport | `BC8B61DE6E2157F5F5028F2E3F65D45F6DBD18BBD937B563B7E98CF935DE35CF` |
| Skel, Corrected | `A9CFADB1377B1DCBBD638F24F2C153E71BE3335301A3682AB26426BDC353E8E3` |
| weights.bin, tables.bin, activations.bin | as `decoder-supplied-moments-sm8550-20261010.md` |

Not covered: generator sites, learned corrections, chunks without overlap.
