# Fixed-point Snake in phase turns, Windows reference, 2026-10-07

Reference arithmetic only; no emitted kernel or phone claim. Tool
`tools/reference/Measure-KokoroSnakeTurns.ps1` (PowerShell). Captures: stock generator,
"How are you today? I am doing reasonably well, thank you for asking" (stock misaki phonemes from
`examples/phoneme_example.py` at `dfb907a02bba8152ca444717ca5d78747ccb4bec`), af_heart seed 41
and am_michael seed 43. Sites: the 18 Snake activations of resblocks.3-5 (adain1.k and adain2.k
outputs into convs1.k and convs2.k), first 2,000 frames, all 128 channels.

## Form

Stock Snake (`istftnet.py` AdaINResBlock1.forward) uses one alpha per channel inside and outside:
`s = y + sin(a*y)^2 / a`. With the phase in turns `P = a*y/pi`,

    s = (pi/a) * (P + (1 - cos(2*pi*P)) / (2*pi)).

`P` is one signed fixed-point register; its fractional part is the cos argument, so integer
wraparound is the range reduction, and `1 - cos` is evaluated directly (no cancellation at small
phase). After AdaIN folds to a per-channel affine `y = G*x + H`, `P = K*x + M` per channel.

## Result (SNR against the captured stock conv input, dB)

| Form | Min | Median | Weakest site | Tool SHA-256 |
|---|---:|---:|---|---|
| Q24 phase, six-term Q30 polynomial in theta^2 (int64) | 118.2 | 139.6 | resblocks.3.adain2.0 | `ADB839CC…` |
| Q24 phase; 16-bit fractional turn folded by abs; `1 - cos = 1 + sin(pi/2*u)`, five-term odd Q14 polynomial with Q15 rounding-saturating multiplies | **64.8** | **90.4** | resblocks.3.adain2.0 | `ADB839CC…` |
| Q24 phase; 16-entry Q15 cos/sin tables on the top 4 bits, small-angle cos/sin of the remainder, `cos(H+L) = cosH cosL - sinH sinL` | 65.1 | 88.5 | resblocks.3.adain2.0 | `01C4046D…` |

Largest phase: 9.9 turns (af_heart), 9.0 (am_michael); Q24 in int32 has ±128 turns.
The two 16-bit forms agree within 2 dB and share the weakest site, so their floor is the 16-bit
fractional phase and Q14 output, not the cos method. The polynomial form needs no tables and is
the one chosen for the HVX body. The table run's tool adds only that mode to the earlier tool.

Reports: `build/snake-turns-{q24,halfword,table}-20261007.json`.

## Halfword HVX instructions

`src/emit/Hexagon.ps1` gains `vmpy(Vu.h,Vv.h):<<1:rnd:sat`, `vadd.h`, `vadd.h:sat`, `vsub.h`,
`vabs.h:sat`, `vasr.h`, `vasl.h` and `vsplat.h`. Each matches SDK 6.4.0.2 `hexagon-llvm-mc`
(+hvxv73, 128B) bytes for two register sets (16/16) and decodes back to the same form. Their
arithmetic semantics are not yet exercised in the V73 simulator.

Reproduce: `pwsh -File tools/reference/Measure-KokoroSnakeTurns.ps1 -CaptureDirectory <af>,<am>
-MaxFrames 2000 [-CosHalfword | -CosTable] -ReportPath build/<new>.json`.

## Emitted body, V73 simulation

`src/emit/Kokoro.AdaInSnakeTurns.ps1` emits the halfword-polynomial form as one HVX body: biased
16-bit input in native croutons, per-channel K, M, S, and both conv-input byte planes out (high
`(out >> 8) + 128`, low `out & 255`, odd bytes). 70 instructions per 128-byte vector (64 values),
unpacked; 1,524 code bytes, matching SDK assembly. Harness
`tools/reference/hmx-sim/adain_snake_turns.c` models the integer contract lane by lane.

| Check (128 channels, 2 tiles, random x, K, M, S) | Result |
|---|---|
| High plane vs integer model | 0 / 8,192 mismatches |
| Low plane vs integer model | 0 / 8,192 mismatches |
| 16-bit output vs double-precision Snake of the same constants | 86.22 dB |

This confirms the simulator semantics of the Q31 multiply pair (`vmpye` + accumulating
`vmpyo:<<1:rnd:sat:shift`), the Q15 rounding multiply and the halfword add, subtract, abs and
shifts as modeled. Not yet connected to the resident stage (its 16-bit residual, moments and
coefficient generation), and not timed.
