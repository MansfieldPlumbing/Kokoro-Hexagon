# Generator 60x stage at 16 bits: numeric design

Status: design; kernels are built and proved one at a time in the V73 simulator, then the stage is
compared with stock PyTorch captures and timed on SM8550. Precision plan:
`docs/results/generator-plane-depth-20261007.md` (about 42-48 dB PCM for the generator).
Builds on `docs/generator60x-resident-design.md` (resident layout and pass order, unchanged).

## Representation

Every stored activation (residual stream `R`, conv1 output `C`) is a signed 16-bit value held in
the native crouton halfword, biased by 32768 (u16 = x + 32768). The odd byte is the high byte, so
it keeps the layout the 8-bit stage used. Conv inputs are never stored: the fused AdaIN+Snake body
regenerates them per batch as two HMX windows (`docs/results/snake-turns-reference-20261007.md`).

Scales:

- `R` uses one scale per stage, `sR = absmax / 32767`. Stock captures (resblocks.3-5, two
  sentences) peak at 71.3 for `R` and 26.7 for `C`; `sR` is set from calibration with margin.
- `C` uses a per-channel scale `sC_c`: it only feeds AdaIN, which normalizes each channel, so
  the per-channel factor is absorbed into that channel's K and M.
- Conv inputs use one scale per conv, `sX`, written by the fused body through `S_c`.

## Conv

Input planes: high `h` (u8, zero point 128) and low `l` (u8, zero point 0), `x = (h - 128) * 256 + l`
in units of `sX / 256`. Weights: per-output-channel `W8x1`, or `W8x2` (`W = 256 Wh + Wl`) where the
plan keeps a second weight plane. Two HMX accumulator groups per output tile:

    A1 = sum (h - 128) * Wh                       (one pass; table int32 carries -128 * sum Wh)
    A2 = sum l * Wh  [+ sum (h - 128) * Wl]       (one or two passes into the same accumulator)

`A1 * 256 + A2 + A3 / 256` is the conv in units of `sX * sW_c / 65536` (`W8x1`: `sW_c / 256`), with
`A3 = sum l * Wl`. A3 leaves at shift `L + 8` through its low plane only (its high plane would need table
exponent `8 - L`); its window stays a signed byte (peaks 45-59 on the captures; the fixture builder checks
every capture it reads), and the combine sign-extends it. Each table bias rounds to nearest. Each group leaves HMX as two exact
byte planes of a 16-bit window at a power-of-two shift (`docs/results/hmx-two-plane-output-sim-20261007.md`):
`A1` at shift `L - 8`, `A2` at shift `L`. Their sum is the 16-bit output within two LSB.

## Combine (HVX, per output tile)

- `win(A1)` = floor(A1 / 2^(L-8)) = floor(256 A1 / 2^L) and `win(A2)` = floor(A2 / 2^L) share output
  units, so the 16-bit result is `win(A1) + win(A2)` (two floors: within two LSB).
- conv1: `C16` = that sum, stored as biased u16; its scale is per channel.
- conv2: `O16` as above, then multiplied per channel by `rO_c = (sX * sW_c * 2^L) / sR` (Q15) and
  added into `R` with saturation: `R += O`. Combine and residual are one pass.

## Moments (HVX, in the producing pass's epilogue)

Per channel over the group's valid frames: `S1 = sum x` (int32: 7,801 * 32,767 < 2^31) and
`S2 = sum x^2` (up to 2^43). `S2` is accumulated exactly as three int32 partial sums of the byte
planes of `x = 256 a + b`: `sum a^2`, `sum a*b`, `sum b^2` (each < 2^31 at 7,801 frames), and
combined on the scalar core as `65536 sum a^2 + 512 sum a*b + sum b^2`.

## Coefficients (scalar, per channel)

From `S1`, `S2`, `N` and the voice-load style affine (stock AdaIN1d: `gamma`, `beta` from `fc(s)`,
norm weight and bias): `D = N S2 - S1^2 + round(eps N^2 / s^2)`, `G = A N / sqrt(D)` per LSB of the
input, `H = B - G * S1 / N`. Then for the Snake body:

    K = round(alpha * G * 2^37 / pi)       (Q31 multiplier of x * 2^16 -> Q22 turns)
    M = round(alpha * H * 2^22 / pi)       (Q22 turns)
    S = round((pi / alpha) * 2^9 / sX)     (Q31 multiplier of Q22 turns -> output LSB)

Q22 rather than Q24 (`-TurnsBits 22`) gives K four times the int32 range: with Q24, one channel of
resblocks.4 stage 0 had no room between its residual peak and the K bound across sentences
(`docs/results/generator60x-16bit-holdout-sm8550-20261008.md`).

`alpha`, `pi` and the scale factors fold into per-channel constants at voice load; only
`G`, `H` depend on the group. Integer sqrt and division use exact 64-bit trial bits, as
`Kokoro.AdaInInteger.ps1` does today.

## Stage boundary

Input `R0` arrives from DDR as 16-bit (for the first proof, quantized from the stock capture);
the three-branch mean and the stage output stay 16-bit.

## Order of proof

1. Two-group HMX conv with plane stores (simulator, against an integer model).
2. Combine and residual (simulator).
3. 16-bit moments (simulator).
4. Coefficients (simulator, against exact rational arithmetic).
5. Connected stage (simulator) against the stock PyTorch capture: target the plan's SNR.
6. SM8550: 3/3 runs, timing against 86.05 ms; listen.
