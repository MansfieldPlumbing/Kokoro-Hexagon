# Kokoro-Hexagon

Kokoro-82M text-to-speech on Android with the whole model on the Hexagon DSP.
PowerShell reads the stock checkpoint, quantizes and packs the weights, and
emits Hexagon machine code directly: HMX for convolutions and matrix
multiplies, HVX for the rest, one dspqueue job per breath group.

See [AGENTS.md](AGENTS.md) for the build contract and `docs/results/` for
device receipts.

| Path | Contents |
|---|---|
| `src/emit` | Hexagon instruction encoders and HMX/HVX kernels (the ELF writer is `tools/Emit-HexagonProbe.ps1`) |
| `src/models` | Checkpoint readers and weight conversion |
| `src/runspace` | Checkpoint reader, native binding, AAudio, dspqueue layout, device probes |
| `tools` | Build, test, and device-run scripts |
| `lib` | Pinned inputs (`manifest.json`) and the stock Kokoro config |

Generated files go in the ignored `build/`.
