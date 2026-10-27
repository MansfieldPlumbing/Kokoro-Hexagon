# ALBERT linear in one 8-bit activation pass: host numerics

Kokoro-Hexagon `5c741d5`, host only (float64 simulation of integer formats), stock captures pinned as in
`albert-dsp-accuracy-diagnosis-20261027.md`. Linear: repeat 1's key (768 x 768), scored on the hello capture (16
tokens) against stock with exact inputs; calibration statistics from bench1-3 and howareyou.

## Formats

- Weights: symmetric int8, one step per output channel (largest weight over 127), or one step per output channel and
  group of 16 input columns.
- Activations: symmetric int8 with one step per tensor (calibration peak) or per token row (that row's own peak). The
  job's current format is 16-bit activations as two 8-bit passes.
- Rotation: block Hadamard (orthonormal, symmetric) of 32 or 256 input columns, applied to the weights offline and to
  the activations before quantization; W x = (W H)(H x) holds exactly before quantization.

## Result

Input crest factor (peak over RMS): 24.4 dB unrotated, 15.2 dB after the 32-column rotation, 12.6 dB after the
256-column rotation.

| Rotation | Activation step | Exact weights | W8 per row | W8 per 16 columns |
| --- | --- | ---: | ---: | ---: |
| none | per tensor | 40.29 dB | 39.75 dB | 40.23 dB |
| none | per token | 40.89 dB | 40.26 dB | 40.84 dB |
| Hadamard 32 | per tensor | 48.53 dB | 47.46 dB | 48.10 dB |
| Hadamard 32 | per token | 51.09 dB | 49.31 dB | 50.26 dB |
| Hadamard 256 | per tensor | 50.96 dB | 49.35 dB | 50.31 dB |
| Hadamard 256 | per token | 54.74 dB | 51.59 dB | 53.26 dB |

Reference, same linear and inputs: 16-bit activations with W8 per row, 49.14 dB (`albert-dsp-accuracy-diagnosis-20261027.md`).

Weight formats alone, 16-bit activations, rotation then step groups (same linear): one step per row 49.14 (unrotated),
53.81 (Hadamard 32); per 32 columns 56.80, 56.62; per 16 columns 59.41, 57.62 dB.

## Observations

- 8-bit activations with a per-token step and a 32-column rotation match the current two-pass 16-bit activations with
  W8 per row (49.31 against 49.14 dB) in one pass; with a 256-column rotation they exceed it (51.59 dB).
- Without rotation, 8-bit activations lose about 9 dB against 16-bit.
- Rotation and finer weight step groups do not add: after rotation, 16-column groups score lower than without it.

## Not yet done

- A whole repeat and the propagated stream with these formats.
- The rotation on the phone (after each LayerNorm, before each linear) and its time against one HMX pass saved.
