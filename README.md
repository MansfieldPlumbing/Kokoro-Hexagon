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

## Current state, 2026-10-06

The connected integer generator residual branches `resblocks.3`, `.4` and
`.5` each pass V73 simulation and three SM8550 runs with exact meaningful
output lanes and live AdaIN coefficients. See the
[branch receipt](docs/results/generator-residual-branches-sm8550-20261006.md)
and [resblocks.3 receipt](docs/results/resblock3-integer-device-sm8550-20261006.md).
The [256-channel integer operators](docs/results/generator-c256-integer-simulator-20261006.md)
have separate simulator evidence.

The combined three-branch worker and native-layout mean match SDK assembly,
pass malformed-input checks, and pass full-group V73 arithmetic simulation:
all 19 stages complete with exact meaningful output lanes and live AdaIN
coefficients. The combined output matches the separately checked branch
mean byte for byte. The separate LeakyReLU has simulator evidence. Next is
to run that same combined ELF on the phone before advancing to the remaining
generator stages.

Whole-generator execution, source synthesis, spectral output/iSTFT and the
front half still require integration. Phoneme-to-PCM speaker playback,
whole-model RTF and TTFA remain unproved on both target phones. This is an
implementation in progress.
