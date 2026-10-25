# HMX conv with two exact output byte planes, V73 simulation, 2026-10-07

Local uncommitted work on `7363334`. Emitter `src/emit/Kokoro.HmxConv.ps1 -OutputPlanes`
(SHA-256 `F67296E2…`); harness `tools/reference/hmx-sim/emitted_conv_planes.c`
(`8A38A4CB…`) and `run-emitted-planes.sh`. No phone run.

## Mechanism

After the MAC loop, per 32-column accumulator half:

1. `bias = mxmem2(high table)`; `mxmem(out):after:retain:sat.ub = acc` (keeps the accumulator);
2. `bias = mxmem2(low table)`; `mxmem(low):after.ub = acc` (wraps, releases the half).

Both tables carry the same int32 bias `B = -128·Σw + 2^(L+15)` and power-of-two fp16
scales 2^(1-L) and 2^(9-L). For biased accumulator `a = acc + B`:
high = `sat(floor(a / 2^(L+8)))` in the odd bytes of the usual output tile (unchanged layout for
existing consumers), low = `floor(a / 2^L) mod 256` in the odd bytes of a second tile. Together
they are a 16-bit window of the exact accumulator.

Sources: onnxsim `0dd9980a50045a5079b4fd6c30a21300725e0f3b`,
`scripts/android/hmx_gemm/README.md:297-311` (conversion `floor(trunc(acc+B)·s/512)` with the
accumulator truncated to a multiple of 2^(5-E), exact for power-of-two scales; `:retain`; wrapping
`.ub`) and `hmx_qconv.h:226-234` (retained stores, then a releasing store, per half).
Encodings from SDK 6.4.0.2 `hexagon-llvm-mc` (+hmxv73) with registers (12,9), (3,17), (30,0):
`:after:retain:sat.ub` `10100110111sssssPP0ttttt00001100`, `:after.ub` `10100110111sssssPP0ttttt00000110`.

## Result

Random int8 activations and weights in [-8, 8], 3 output tiles × 128 channels.

| Conv | L | Emitted code SHA-256 | Bytes match SDK | High mismatches | Low mismatches |
|---|---:|---|---|---:|---:|
| 128→128, K=3, D=1 | 2 | `01D74062…` | yes | 0 | 0 / 12,288 |
| 128→128, K=3, D=1 | 0 | same | yes | 0 | 0 / 12,288 |
| 128→128, K=11, D=5 | 2 | `3EB330B7…` | yes | 0 | 0 / 12,288 |
| 128→128, K=11, D=5 | 0 | same | yes | 0 | 0 / 12,288 |

No output saturated in these runs; saturation of the high plane is not yet exercised.

## Rejected: `:after:sat.uh = acc:2x1`

Encoding `10100110111sssssPP1ttttt00001010`. With a power-of-two scale 2^-3 it wrote 16-bit values
within a few LSB of `floor(a·s/2)` but not equal (10,417 / 12,288 mismatches, per-channel offsets),
and its high byte differed from the u8 store in 369 cases. onnxsim also found the 16-bit stores of
no use for its layout. Not adopted.

## Consequence

The per-channel real-valued requantization scale leaves the HMX table (now a power-of-two
window per conv) and moves to the HVX consumer: AdaIN after conv1 is per-channel
scale-invariant, the residual body after conv2 already does integer arithmetic, and conv_post
feeds the tail's exp/sin. The low plane lands in a separate tile; placing it in the even
bytes of the main tile (shift and OR on HVX) is the next step.

Reproduce: `tools/Test-HexagonEmission.ps1 -Kernel KokoroHmxConv -ConvKernel 11 -ConvDilation 5
-ConvOutputPlanes -OutputDirectory build/<fresh>`, then
`run-emitted-planes.sh <emitted-code.bin> 128 11 5 2` in WSL.
