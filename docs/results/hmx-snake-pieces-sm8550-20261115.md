# The pieces a Snake needs are in HMX's integer stores, exact on the phone (SM8550, 2026-11-15)

Kokoro-Hexagon `a2bfca0`, branch `live-adain`, on the attached SM8550. One job, three runs, run from a scratch harness
(a copy of the 13 November timing point with a custom-steps option; not a `Run -Case`). Receipt:
`build/hmx-snake-pieces-20261115/` (predictions and their hash, both scripts, the log, the emitted library, the phone's
output, `snake-pieces.csv`, `manifest.csv`).

**Result.** On HMX's integer path, with no HVX step anywhere:

- a crouton that one multiply stored is read by the next multiply as its input, byte for byte;
- a wrapping store gives each column its own phase, at any FP16 scale tried, exactly as the model says;
- a saturating store gives a rising clamp, and with a negative scale a falling clamp, the latter one count low.

These are the parts of AdaIN followed by Snake: a per-channel scale and offset, a phase that repeats, and a bounded
shape of that phase. Not tested: how a Snake built from them sounds, what it costs in time, and the rest of a
resblock.

## The job

Two pointwise multiplies, `activation.ub` against `weight.b :deep`, identity weights, one 32-row tile.

- **Stage 1.** One activation crouton, 32 rows by 32 channels, value (8 row + channel) mod 256, into 64 accumulator
  columns; column c and column 32 + c hold channel c's value a. Half 0 leaves through three retained saturating stores
  and a final wrapping store; half 1 through one retained saturating store and a final wrapping store.
- **Stage 2.** The crouton that half 1's wrapping store wrote is given to the next multiply as its activation
  crouton, with nothing between, and its accumulators leave through four more stores.

Every store's table carries, per column, an FP16 scale s and an int32 bias B. The model compared with the phone:

    value = floor((a + B) s / 512), saturated to 0..255, or taken mod 256 for a wrapping store

The repository had stated this exact for power-of-two scales only (`Kokoro.HmxConv.ps1`).

## Predicted and observed

`PREDICTIONS-SNAKE-PIECES.md`, SHA-256 `53A03EBD701AE42C7E5E33C15F2F8F245F3CCF0D132351827BB7248C8B46D3B2`, written at
09:47 before the run. Each store has 1,024 cells; the job passed and all three runs completed.

| Store | Scale and bias | Predicted | Observed |
| --- | --- | --- | --- |
| 0, 4 linear | s = 512 | all equal | 1,024 of 1,024, both |
| 1 rise, saturating | s = 2048, B = -64: 4 (a - 64) | all equal | 1,024 of 1,024 |
| 2 negative scale, saturating | s = -2048, B = -192: -4 (a - 192) | not as the model says, fewer than 512 equal | **wrong**: 772 equal, all 1,024 within one count |
| 3 phase A, wrapping, columns 0 to 15 | s = 512 (1 + c / 4) | all equal | all equal |
| 3 phase A, columns 16 to 31 | s = FP16 of 512 (1.37 + 0.31 (c - 16)) | at least 90 % within one count, not all equal | **better**: all equal |
| 5 phase B, wrapping | s = 1280, and FP16 of 512 pi | binary columns equal, the rest within one count | all 1,024 equal |
| 6, 8, 9 phase B read back | s = 512, saturating and wrapping, both halves | equal to what store 5 wrote | 1,024 of 1,024 in each |
| 7 rise of the phase | s = 2048, B = -32: 4 (p - 32) | all equal | 1,024 of 1,024 |

- **The negative scale.** Wherever the model's value lies strictly between the two limits, the phone stores one
  less: column 0 reads 255 ... 255 223 191 159 127 95 63 31 0 ... 0 where the model has 224 192 160 128 96 64 32.
  The saturated cells agree. So a falling ramp comes from the table alone, one count low.
- **The comparison can fail.** It did, by one count, in 252 cells of store 2.
- The scales that are not binary fractions (1336 in column 20 of phase A, 1608 for pi) match in every cell, so the
  model holds beyond the power-of-two case on this phone, over the range tried: accumulators 0 to 255, scales 512
  to 3,082.

## What this allows

For one convolution whose accumulator holds y, per output column:

1. **Scale and offset.** Held AdaIN levels are a scale and an offset per channel, which is what the store's table
   holds. No separate step.
2. **Linear part.** A retained saturating store writes the scaled value as a byte plane with its own range per
   column.
3. **Phase.** A wrapping store at scale alpha a 256 / pi writes the phase of sin squared, whole periods dropped.
4. **Shape.** One pointwise multiply reads the phase plane back and two stores clamp it: a rising ramp and a falling
   ramp, the two sides of a trapezoid in place of sin squared.
5. The next convolution reads the linear plane and the two ramps as input channels, with the weights carrying each
   one's coefficient.

That is AdaIN and Snake between two convolutions with nothing leaving HMX. The cost moves into pairs: the next
convolution has about three times the input channels, plus the small pointwise multiply. By the 24 October profile
the matrix unit is held about 8 ms of a 40 ms job whose bound is the AdaIN and Snake fill on HVX; three to four
times the pairs would be about 28 ms with the fill and the combine gone. That is arithmetic from records, not a
measurement.

## Not known

- How a trapezoid in place of sin squared sounds, and how fine the phase has to be.
- Whether one byte plane carries the linear part. By ear on laptop speakers, 8-bit convolution inputs with a range
  per channel were about the same as float (`generator-precision-listening-20261115.md`); with int8 weights the
  per-column ranges and coefficients have to be folded into the weights, which costs weight precision.
- The residual add of a resblock inside HMX, and the stream between stages, which has to stay wider than 8 bits.
- Time. Nothing here was timed.
- Saturation at the low limit with negative accumulators, scales below 512 or above 3,082, and accumulators beyond
  0 to 255: not exercised.
- The assembler check did not run: WSL would not start on the development PC, so the emitted library was not
  compared with the SDK assembler. Every instruction form used is one the repository already encodes and has run.

Reproduce (takes the phone lock):

```powershell
& C:\Dev\Pwsh-Development\tools\board.ps1 Lock -Agent <name> -Reason 'HMX Snake pieces'
try { pwsh -NoProfile -File build\hmx-snake-pieces-20261115\scripts\Invoke-HmxSnakePieces.ps1 -Runs 3 -WorkRoot <fresh directory> }
finally { & C:\Dev\Pwsh-Development\tools\board.ps1 Unlock -Agent <name> }
```
