# 16-bit generator 60x stage kernels, V73 simulation, 2026-10-07

Local work on `393dfe4`; design `docs/generator60x-16bit-design.md`. Each kernel is emitted by
PowerShell, its bytes match SDK 6.4.0.2 `hexagon-llvm-mc` (+hvxv73, +hmxv73), and it runs in
`hexagon-sim -mv73` against a scalar C model of its integer contract in the harness. No phone run.

| Kernel (emitter) | Harness | Configurations | Result |
|---|---|---|---|
| Two-group HMX conv, four byte planes (`Kokoro.HmxConvPlanes.ps1`) | `emitted_conv_twogroup.c` | 128 ch: K3 D1 W8x1; K11 D5 W8x1; K7 D3 W8x2; K11 D5 W8x2 (LA 2, LB 7) | 0 / 12,288 mismatches on each of A1 high, A1 low, A2 high, A2 low, every configuration |
| Plane combine (`Kokoro.PlaneCombine.ps1`) | `plane_combine.c` | conv; residual (Q15 ratio, saturating add into R) | 0 / 12,288 each |
| 16-bit moments (`Kokoro.AdaInMoments16.ps1`) | `adain_moments16.c` | 7 tiles, full int16 range, pre-filled record | 0 / 512 record words; `65536 A2 + 512 AB + B2 = sum x^2` for 128/128 channels |
| Phase-turns coefficients (`Kokoro.AdaInTurnsCoefficients.ps1`) | `adain_turns_coefficients.c` | 128 ch, N = 777, random moments and in-contract Ka, Mb, S, epsD | 0 / 128; K within 1.08e-5 of the real-valued AdaIN gain |

`Hexagon.ps1` adds `Vdd.w += vmpy(Vu.h, Vv.h)` and `Vdd.w += vmpy(Vu.h, Rt.h)` (SDK bytes for two
register sets each; exercised by the moments kernel). The coefficients contract requires
`|Ka| N / root < 2^31`; the first harness draw violated it on one channel (true K about 4.9e9), where
the kernel saturates at 2^31 - 1 and the model wrapped; the harness now draws Ka from an in-range K.

The two-group conv omits the low-input x low-weight product where both planes are kept; its effect
on PCM is measured separately with `Measure-KokoroGeneratorPlaneDepth.py --drop-low-cross`.

Not covered: the connected 16-bit stage, its padded-row handling, SM8550 timing.
