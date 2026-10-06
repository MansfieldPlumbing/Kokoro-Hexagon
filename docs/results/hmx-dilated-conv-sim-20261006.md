# HMX int8 dilated Conv1d in the V73 simulator

Tool: Hexagon SDK 6.4.0.2 `hexagon-clang` and `hexagon-sim -mv73 --mhmx 1`
(test tools only). Sources: `tools/reference/hmx-sim/` (`run-sim.sh <probe>`).

## Window offsets (`single_offset.c`)

Two consecutive croutons hold row indices in input channel 0, a one-hot weight
selects that channel, and the output shows which input row lands at output row 0
for each `Rs` offset value (spatial mask all Y, `Rt = 2048 | 0x7ff`).

| Read | Rows per crouton | Window start for offset `o` |
|---|---:|---|
| `activation.ub :single:cm` | 64 | `4 * (o >> 1)` rows; `Rs[1]` has no effect |
| `activation.ub :single` | 32 | `o` rows, for every `o` in 0..31 |

Kokoro's dilated taps shift by `D * (k - (K-1)/2)`: up to ±25 rows in steps of
1, 3 or 5. The plain `:single` read reaches every shift directly; `:cm` reaches
only multiples of 4.

## Dilated convolution (`dilated_conv.c`)

128 input and 128 output channels, 96 frames, same padding. Signed int8 inputs
and weights in [-8, 8]; activations stored as `x + 128`, halo croutons filled
with 128. Per tap and 32-channel input block: one
`{ activation.ub = mxmem(..):single ; weight.b = mxmem(..):deep }` packet
(64 output channels). The 64-bit column table adds `-128 * sum(w) + 128 * 4096`
exactly and scales by 0.125, so `out = sat_u8(floor(acc / 4096) + 128)`.

| K | D = 1 | D = 3 | D = 5 |
|---:|---|---|---|
| 3 | 0 / 12288 mismatches | 0 / 12288 | 0 / 12288 |
| 7 | 0 / 12288 | 0 / 12288 | 0 / 12288 |
| 11 | 0 / 12288 | 0 / 12288 | 0 / 12288 |

All nine Kokoro kernel and dilation combinations are bit-exact against a scalar
reference.

## PowerShell-emitted kernel (`emitted_conv.c`, `run-emitted.sh`)

`src/emit/Kokoro.HmxConv.ps1` (`New-KokoroHmxConvSteps`) emits the same
computation with time-major croutons, weights in consumption order and one
loop over 32-row output tiles; taps and channel blocks are unrolled at build
time. `tools/Test-HexagonEmission.ps1 -Kernel KokoroHmxConv` matched the SDK
assembler byte for byte for all 18 shapes. `run-emitted.sh` runs those exact
`emitted-code.bin` bytes in `hexagon-sim -mv73` against the integer reference:

| Channels | K = 3 (D = 1/3/5) | K = 7 | K = 11 | Code bytes (K = 3/7/11) |
|---:|---|---|---|---|
| 128 | 0 / 12288 each | 0 / 12288 each | 0 / 12288 each | 500 / 1012 / 1524 |
| 256 | 0 / 24576 each | 0 / 24576 each | 0 / 24576 each | 1724 / 3772 / 5820 | The simulator's `upcycle` read 0, so no timing is claimed here; speed
needs a phone run. Simulator agreement is not a device receipt.
