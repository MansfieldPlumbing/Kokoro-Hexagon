# Generator tail: where the 8-bit boundaries lose quality, 2026-10-07

Reference measurements on Windows against stock PyTorch Kokoro at
`dfb907a02bba8152ca444717ca5d78747ccb4bec`. Raw PCM SNR over all samples,
no lag, gain fitting or cropping. No phone or emitted-candidate claim.

## Result

The tail loses quality at two 8-bit boundaries, not in the weights and not in
synthesis.

| conv_post input | Weights | exp/sin from conv output | Current 8-bit logit codes |
|---|---|---:|---:|
| stock float | stock | 125.1 / 128.5 | 17.6 / 12.6 |
| stock float | W8×1 | 39.8 / 40.9 | 17.7 / 12.7 |
| A8×1 (current) | stock | 10.7 / 14.2 | 10.2 / 10.2 |
| A8×1 (current) | W8×1 | 10.8 / 14.3 | 10.2 / 10.2 |
| A8×2 | stock | 49.3 / 52.9 | 17.6 / 12.6 |
| A8×2 | W8×1 | **39.3 / 40.6** | 17.7 / 12.7 |

PCM SNR in dB, af_heart seed 29 / am_michael seed 23, both `tˈɛst.`. Inputs
are stock final LeakyReLU captures, so this bounds the tail alone; the frozen
integer generator input adds its own error upstream.

- Per-channel W8×1 weights cost about 1 dB relative to the input encodings.
- A8×1 at the conv_post input (scale 0.536311112) costs about 30 dB. A second
  signed byte plane at scale/256 recovers it.
- The 8-bit logit codes cap PCM at 12.6-17.7 dB whatever feeds them.
- Integer synthesis is not a loss: stock complex spectra through the integer
  four-phase overlap-add give 75.54 dB PCM, and the four-phase schedule
  reproduces all 39,000 existing integer samples exactly
  (`build/tail-polyphase-projector-stock-control-20261007/report.json`).

## Emitted tail on the phones (saved runs, reverified)

`src/emit/Kokoro.GeneratorTailRun.ps1` (conv_post on HMX with coarse and fine logit codes,
integer exp/sin tables and four-phase overlap-add) on the frozen 7,801-frame fixture. Skel
SHA-256 `118245BAD6AD50E8EABDA618B41A52692773D9F3B822D8BE32F7B5EB7BA4A34B`; PCM SHA-256
`23D3E8C8CA880E1A7BED37110F41C0C740CE16268B78E09933F667244C86DBD9` on both phones, equal to the
V73 simulator and to the integer reference.

| SoC | Median region | Runs | AAudio playback |
|---|---:|---|---|
| SM8550 | 27.452 ms | 3/3 | 39,000 frames written, XRunCount 0 |
| SM8635 | 27.531 ms | 3/3 | 39,000 frames written, XRunCount 1 |

Receipts: `build/emit/KokoroGeneratorTailRun/device-receipt-SM8550-411491de….txt` and
`device-receipt-SM8635-33ac2c85….txt`. This is the current 8-bit tail (about 10 dB PCM against
stock); the two-plane input and direct exp/sin above are not yet emitted.

## Plane depth

Notation: A8×n and W8×n are n signed INT8 byte planes, not native wider operands.

Signed byte planes at the existing scales: activations `x = s(p0 + p1/256 + p2/65536)`,
weights `w = s_w(q0 + q1/256)` per output channel. exp/sin from the conv output, no
logit codes. PCM SNR in dB, calibration / holdout.

| conv_post input | W8×1 | W8×2 | stock weights |
|---|---:|---:|---:|
| A8×1 | 10.8 / 14.3 | 10.7 / 14.2 | 10.7 / 14.2 |
| A8×2 | 39.3 / 40.6 | 49.3 / 52.9 | 49.3 / 52.9 |
| A8×3 | 39.8 / 40.9 | 87.9 / 90.6 | 90.6 / 94.6 |

Activation and weight planes limit in turn: a third input plane needs a second
weight plane to matter. Each plane pair is one HMX pass whose INT32 sum is
bounded by 896 x 127^2; pairs below the target scale can be skipped.
Scratch measurement; not yet a repository tool.

## Listening check (Windows PC, not phone)

Stock, current A8 plus logit codes, and two-plane direct exp/sin were played on
the PC for both captures. The 10.2 dB am_michael rendering sounded rough; both
39-41 dB two-plane renderings were judged indistinguishable enough to ship.
Working target: about 40 dB raw PCM SNR against stock on shared-noise captures.

## Superseded work

conv_post weight rounding (704 bounded floor/ceil changes, per-channel bias,
channel scale grid) moved held-out conv_post tensor SNR from 29.3 to 36.4 dB
but held-out PCM from 10.23 to 10.17 dB, and even with float exp/sin from
14.26 to 13.11 dB. Equal-weight logit MSE is the wrong objective: PCM error
follows complex-spectrum error weighted by magnitude. Weights are not the
bottleneck, so this line and the extra residual weight plane are dropped.

## Next gate

Remove both boundaries in the emitted tail:

1. Feed conv_post a second signed byte plane of the final LeakyReLU output and
   combine the two contractions in the accumulator.
2. Read the conv_post accumulator exactly and derive exp/sin inputs from it in
   integer HVX, without 8-bit logit codes. Reference mechanism: onnxsim
   `0dd9980a50045a5079b4fd6c30a21300725e0f3b`, `scripts/android/hmx_gemm/hmx_qconv.h:164-240`
   (accumulator byte-plane extraction into an 8 KiB scratch tile, then integer requantization).

Then apply the same input-plane test to each A8 boundary inside the generator,
using stock captures, to find which boundaries need a second plane.

Reproduce:

```powershell
C:\bin\micromamba\envs\mono\python.exe tools/reference/Measure-KokoroTailBoundaryCeiling.py --capture build/stock-generator-weight-calibration-20261007 --capture build/stock-generator-weight-holdout-20261007 --output build/<fresh>
```

Tool SHA-256 `106C91CEDF85323D9DF292E1E3818520794B792219B51D69BD3F836CF88F2AF4`;
report `build/tail-boundary-ceiling-20261007/report.json`.
