# Generator byte-plane depth, 2026-10-07

Reference measurements on Windows: pinned stock PyTorch Kokoro
(`dfb907a02bba8152ca444717ca5d78747ccb4bec`) with byte-plane quantization at
every generator conv (53 Conv1d/ConvTranspose1d). No emitted kernel, phone or
timing claim. Each capture's generator is replayed from its recorded inputs and
RNG state; the unquantized replay equals the saved stock capture output exactly.
Score: raw PCM SNR against that output, stock exp/sin/iSTFT, no lag or gain fit.

Notation: A8×n input, W8×n weights (per output channel), O8×n output, as n signed
INT8 byte planes. Activation scales are per tensor, calibrated on the same
utterance. Captures: af_heart seed 29 and am_michael seed 23, `tˈɛst.`.
AdaIN, Snake and residual arithmetic run in float except where a stored tensor
is quantized, so this bounds conv-boundary precision only.

## Dataflow models

- **Storage**: every conv output is a stored O8×n tensor.
- **Recompute**: conv inputs are regenerated per tile (planes cost HVX work);
  convs1 runs twice, statistics then a fused pass, so its output reaches AdaIN
  wide; conv_post feeds exp/sin wide. Only stored tensors take output planes:
  the residual stream after each add, and ups/noise_convs stage outputs.

| All convs A / W / O | Storage | Recompute |
|---|---:|---:|
| ×1 / ×1 / ×1 | 2.7 / 7.0 | 9.5 / 11.3 |
| ×2 / ×1 / ×2 | 28.5 / 26.8 | 28.7 / 26.8 |
| ×2 / ×2 / ×1 | 1.5 / 3.8 | 15.5 / 16.9 |
| ×2 / ×2 / ×2 | 44.7 / 48.2 | **48.4 / 52.3** |
| ×3 / ×2 / ×3 | 69.9 / 71.9 | 77.2 / 75.9 |

PCM SNR dB, af_heart / am_michael. MSE-optimal single-plane clipping changes
the ×1 rows by at most 0.5 dB, so a single plane is limited by width, not scale.
Stored tensors at ×1 cap the result at 15-17 dB in every configuration.

## Greedy plan at 42 dB (recompute)

Starting from ×2/×2/×2 everywhere, single-plane drops are tried least harmful
first and kept while both captures stay at or above 42 dB.

- Final: 42.58 / 42.21 dB. 34 drops accepted: 31 weight planes, 3 input planes.
- All 28 stored tensors keep O8×2.
- A8×2/W8×2 remain at 12 convs: conv_post, ups, noise_convs and most of
  resblocks 4-5 (the 128-channel stage). Stage-0 resblocks, noise_res and most
  convs1 run W8×1.
- HMX work, counting plane-pair products to leading order and convs1 twice:
  3.53× today's single-pass path (×2 everywhere: 4.46×). Generator conv work is
  33.2 G MAC per 1.35 s of audio today, 117 G MAC under the plan. At the onnxsim
  published 17 TMAC/s (not measured here) that is 6.9 ms.

Frozen-plan check on untouched captures (stock misaki phonemes from
`examples/phoneme_example.py` at `dfb907a0`, "How are you today? I am doing
reasonably well, thank you for asking"; af_heart seed 41, 99,000 samples;
am_michael seed 43, 115,200 samples): **42.02 / 41.65 dB**, plan unchanged.
Played stock then plan on the Windows PC (not phone): judged to sound very good.
Report `build/generator-plane-greedy42-sentence-20261007/report.json`.

## Residency (128-channel stage, 7,801-frame group)

Under recompute only the residual stream is resident across a resblock. At O8×2
that is about 1.9 MiB, against about 2.9 MiB for today's three single-plane
tensors (ROADMAP, `dd72baf`). The stage input and three-way mean remain in DDR at
twice today's bytes. Fits SM8635's 4 MiB; not yet checked against the tiled path.

## Not covered

AdaIN, Snake and residual arithmetic in integer; the decoder, predictors and
ALBERT; more utterances; listening to the plan's output; emitted HMX/HVX cost.

Reproduce:

```powershell
C:\bin\micromamba\envs\mono\python.exe tools/reference/Measure-KokoroGeneratorPlaneDepth.py --model recompute --greedy-target 42 --spec build/stock-generator-weight-calibration-20261007/capture-spec.json --spec build/stock-generator-weight-holdout-20261007/capture-spec.json --output build/<fresh>
```

Tool SHA-256 `F2ECC66508DE2730DA3C8D400E013CF59C51B247FF13E57F2D4D9B83FE394A91` (adds `--render-plan`; searched with `9D5E635E281E55B9A9696F1A49CAE93863DDEAA7A3A499008A8AE679FEC8D7FF`).
Reports: `build/generator-plane-greedy42-20261007/report.json`,
`build/generator-plane-depth-recompute-v2-20261007/report.json` (identical to the
earlier revision's 142 values), `build/generator-plane-depth-20261007/report.json`
and `build/generator-plane-depth-mse-20261007/report.json` (storage model, earlier
revision of the same arithmetic).
