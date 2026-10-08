# Decoder on the DSP: design

Status: design. Campaign step 2 (`docs/end-to-end-campaign.md`): stock `Decoder` front from captured `asr`, `F0_curve`,
`N` and style to the generator's input, then on into the whole-generator job (`-Whole -Source`), PCM against stock.

Source: hexgrad/kokoro `dfb907a02bba8152ca444717ca5d78747ccb4bec`, `kokoro/istftnet.py` `AdaIN1d` (lines 20-31),
`UpSample1d`, `AdainResBlk1d` and `Decoder.forward` (lines 328-421).

## Stock computation (F frames, F = 65 for hello world)

    F0 = F0_conv(F0_curve)        Conv1d(1, 1, k 3, stride 2, pad 1): 2F -> F
    N  = N_conv(N_curve)          same
    x  = encode(cat[asr 512, F0, N])                         514 -> 1024
    a  = asr_res(asr)             Conv1d(512, 64, k 1)
    x  = decode.i(cat[x, a, F0, N])  for i = 0, 1, 2         1090 -> 1024
    x  = decode.3(cat[x, a, F0, N])                          1090 -> 512, 2F frames

Each `AdainResBlk1d(dim_in, dim_out)`:

    r = conv1(pool(LeakyReLU0.2(AdaIN1(x))))     conv k 3, pad 1; pool is identity except decode.3
    r = conv2(LeakyReLU0.2(AdaIN2(r)))           conv k 3
    y = (r + conv1x1(upsample(x))) / sqrt(2)     conv1x1 (no bias) on every block (dim_in != dim_out)

decode.3: `upsample` is nearest x2 and `pool` is a depthwise `ConvTranspose1d(k 3, stride 2, pad 1, output_padding 1)`:
`p[2t] = w1 x[t] + b`, `p[2t+1] = w2 x[t] + w0 x[t+1] + b` (x[F] = 0). A 1x1 conv commutes with nearest upsampling, so
the shortcut is computed at F frames and each output frame is written twice.

AdaIN statistics are per channel over the group's F (or 2F) frames, exact: stock behavior for one breath group
(`docs/breath-groups.md`). `weight_norm` is folded at weight load from the checkpoint tensors.

## Weights

W8 per output channel (team decision, `docs/decoder-weight-bits.md`): 31,133,696 conv parameters, 40.62 dB PCM with
exact activations. One weight plane (`-WeightPlanes 1`). Concatenated inputs are padded to whole 32-channel blocks
(514 -> 544, 1090 -> 1120) with zero weights; the padded channels hold zero.

Weights stream from DDR once per breath group, one conv at a time, by DMA into two VTCM buffers (ping-pong): conv n+1
loads while conv n runs. The largest conv (`decode.*.conv1`, 1024 x 1120 x 3) is 3.44 MB, so two buffers fit the 8 MiB
SM8550 grant; the 4 MiB SM8635 grant needs each conv split into output-channel slices (a later step).

## Representation

As the generator's 16-bit stage (`docs/generator60x-16bit-design.md`): stored activations are biased u16 in the native
crouton layout, 32-frame tiles; conv inputs are never stored but regenerated as high/low HMX windows by the fused body;
two accumulator groups per output tile (A1 high x W, A2 low x W), combined on HVX. Scales: one per stored tensor from
calibration on captures other than the test sentence; per-channel scales where the tensor only feeds AdaIN (conv1 output).

Fused bodies:
- AdaIN + LeakyReLU(0.2) -> windows: `y = G_c x + H_c`, `y < 0 ? 0.2 y : y`, scaled by `1 / sX`, split into the high
  (zero point 128) and low planes. `G_c`, `H_c` as the generator's coefficients (`AdaIN1d`, eps 1e-5), without the
  Snake turns.
- Identity -> windows for the shortcut's conv1x1 (its input is the block input, not normalized).
- decode.3: AdaIN + LeakyReLU, then the depthwise transposed conv, -> windows at 2F frames.

## Building blocks and what changes

| Block | Today | Decoder needs |
| --- | --- | --- |
| `Kokoro.HmxConvPlanes.ps1` | in 64-512, out 64-256, k 3/7/11 | in 544 / 1120 / 512, out 64 / 512 / 1024, k 1 and 3; weight base per call (streamed buffer) |
| `Kokoro.PlaneCombine.ps1` | 64-256 channels | 64 / 512 / 1024; residual mode with the 1/sqrt(2) folded into the ratio |
| `Kokoro.AdaInMoments16.ps1` | 128, 256 | 544 / 1120 / 1024 / 512 |
| `Kokoro.AdaInTurnsCoefficients.ps1` | 128, 256, Snake terms | the same channel counts, LeakyReLU terms (`G`, `H`, `1/sX`) |
| AdaIN + LeakyReLU body | new | as above |
| Depthwise transposed conv x2 | new | HVX, decode.3 only |
| `Kokoro.DmaCopy.ps1` | two chained descriptors | one conv's weights per ping-pong buffer |

## Order of proof

1. HMX plane conv at decoder shapes (V73 simulator, against an integer model): 1120 -> 1024 k 3, 1120 -> 1024 k 1,
   544 -> 1024 k 3, 512 -> 64 k 1, 1120 -> 512 k 3 at 2F frames.
2. Combine, moments and coefficients at decoder channel counts (simulator).
3. AdaIN + LeakyReLU body; depthwise transposed conv (simulator).
4. One `AdainResBlk1d` (encode) from the stock capture: SNR of its output against stock.
5. The connected decoder with streamed weights from the capture: SNR of its output, then that output into the
   whole-generator job: PCM SNR against stock (target near the 40.62 dB of W8 with exact activations).
6. SM8550: decoder + generator in one job from captured `asr`, `F0_curve`, `N`; 3/3 runs, timing, played.
