# ALBERT integer formats through all 12 repeats: host simulation

Kokoro-Hexagon port `tools/Invoke-KokoroPrecomputedDecoder.ps1`, `-Mode FrontEnd -AlbertQuantization`, on the host.
ALBERT's and `bert_encoder`'s linears run in the named format, simulated in float (lowered methods `Hadamard`,
`QuantizeRows`, `QuantizeRowsComplement`, `ScaleColumns`); attention, LayerNorm and GELU stay exact. The rest of the
front end (predictor, text encoder) is the stock-exact port. Same twelve stock captures as
`frontend-host-port-stock-20261027.md` (the bank-front-end capture skipped): five ALBERT captures (14 to 270 phonemes)
scored after each repeat and at `d_en`; seven decoder captures (11 to 510 phonemes) scored on F0, N and the aligned
text encoding, which have stock's length only if every duration's sum matches.

## Formats

- Activations: 16-bit (`A16`, the job's two 8-bit passes) or 8-bit (`A8`) with one step per token row.
- Weights: symmetric with one step per output row (`row`) or per output row and 16 input columns (`g16`), at 8, 12 or
  16 bits. 12 bits stands for int8 weights plus an int4 plane of their rounding remainder.
- Rotation: block Hadamard of 32 or 256 input columns (`H32`, `H256`), applied to weights offline and activations at run
  time. Variants: activation steps rounded up to powers of two; two or twelve random sign sets ahead of the rotation,
  cycled over the repeats; the complement weight rounding on odd repeats (`Alternate`).

## Result

| Format | Stream after repeat 11 | `d_en` | Decoder captures with stock durations |
| --- | ---: | ---: | ---: |
| A16, W8 row | 28.6 to 32.7 dB | 27.2 to 31.2 dB | 3 of 7 |
| A16, W8 row, Alternate | 27.0 to 29.4 dB | 26.0 to 27.4 dB | 3 of 7 |
| A16, H256 with 2 sign sets, W8 row | 31.3 to 32.5 dB | 30.0 to 30.7 dB | 3 of 7 |
| A16, H256 with 12 sign sets, W8 row | 30.6 to 33.1 dB | 29.3 to 31.2 dB | 4 of 7 |
| A16, W8 g16 | 34.5 to 35.6 dB | 32.9 to 34.4 dB | 4 of 7 |
| A16, W12 row | 53.4 to 55.3 dB | 52.1 to 53.2 dB | 6 of 7 |
| A16, W16 row | 64.1 to 65.3 dB | 62.9 to 63.7 dB | 6 of 7 |
| A8 per token, H32, W8 row | 26.1 to 27.2 dB | 24.3 to 25.6 dB | 3 of 7 |
| A8 per token, H256, W8 row | 28.1 to 30.8 dB | 26.4 to 28.9 dB | 2 of 7 |
| A8 power-of-two steps, H256, W8 row | 26.3 to 28.1 dB | 24.5 to 26.1 dB | 2 of 7 |
| A8 per token, H256, W12 row | 32.3 to 34.1 dB | 31.1 to 32.1 dB | 1 of 7 |

Where durations hold, F0 and N against stock are 44 to 65 dB with W8 row, 61 to 76 dB with W12 and 73 to 95 dB with
W16. The 510-phoneme capture comes out 2 frames longer (1,123 against 1,121) with both W12 and W16.

## Observations

- Weight precision sets the stream through the repeats: 12-bit weights lift `d_en` by about 23 dB over 8-bit, and
  16-bit by about 11 dB more.
- With 12-bit weights, 8-bit activations cap the stream near 32 dB, about 20 dB below 16-bit activations. Single-linear
  results with 8-bit weights (`albert-single-pass-numerics-20261027.md`) hid this limit because the weights dominated.
- Alternating complementary rounding over the repeats loses 1 to 2 dB; per-repeat sign sets add nothing over one 256-wide
  rotation (2 and 12 sets agree within 1 dB).
- Predicted durations are sensitive to small errors: at 510 phonemes even 16-bit weights change the frame count.

## Not yet done

- The number of tokens whose duration changes, and by how many frames, per format.
- Error-diffusion (GPTQ) rounding of 8-bit weights, and a per-repeat, per-channel drift correction fitted on separate
  calibration text.
- Any of these formats on the phone.

Receipts: `build/albert-formats/<format>-<time>/frontend.clixml` and `albert-format.clixml`.
