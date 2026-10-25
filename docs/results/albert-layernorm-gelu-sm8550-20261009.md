# ALBERT LayerNorm and gelu_new on SM8550, 2026-10-09

Two new integer HVX kernels, each run on the SM8550 DSP from the stock hello-world ALBERT capture (16 tokens) and
compared with the captured stock output. Scales come from the same capture (kernel checks, not calibrated deployment).

## LayerNorm (`src/kernels/Kokoro.LayerNorm16.ps1`)

Per token over the channels: S1 and the split squares A2, AB, B2 (as `Kokoro.AdaInMoments16.ps1`) summed over the
32 lanes by a rotate-add tree, D = C sum x^2 - S1^2 + epsD, root by exact trial bits, one normalized multiplier per
token, then the per-channel gamma/beta folded into the output LSB. Structure after MNN `43bc0686`
`htp-ops-lib/src/dsp/layer_norm_ops.cc` (per-row reduction, one reciprocal square root per row); arithmetic integer.
Input: the captured residual sum (16-bit, one LSB per tensor); output LSB per channel.
`./Invoke-KokoroHexagon.ps1 AlbertLayerNorm -Norm attention.0,full.0,...,attention.11,full.11`, 3 runs each:

| LayerNorm | SNR vs stock, phone | host float LayerNorm of the same 16-bit input | DSP vs that host value | DSP ms | Saturated |
| --- | ---: | ---: | ---: | ---: | ---: |
| attention.0..11 (input layer input + attention dense) | 71.22-73.78 | 71.25-73.83 | 91.75-94.04 | 0.059 | 0 |
| full.0..11 (input attention LayerNorm + ffn_output) | 52.92-59.88 | 52.92-59.88 | 90.01-91.56 | 0.059 | 0 |

The kernel adds no measurable error (90+ dB against the host computation on its own input); the full-layer figure is
the 16-bit per-tensor input LSB of a sum with ffn outliers.

## gelu_new (`src/kernels/Kokoro.Gelu16.ps1`)

gelu_new(x) = relu(x) - q(|x|), q(a) = -gelu_new(-a): a 256-interval Q17 table of q over |x| in [0, 5.5] with 8-bit linear
interpolation (the `Kokoro.SnakeInteger.ps1` vlut16 lookup; q(0) = 0 and q(5.5) rounds to 0, so the next index wraps).
Table activation as MNN `43bc0686` `unary_ops.cc`; host model of the arithmetic: `Invoke-KokoroGeluTable`.
Windows, all 12 repeats: the table model is at least 77.7 dB against stock (exact gelu on the same 16-bit input: 84.2 dB).
`./Invoke-KokoroHexagon.ps1 AlbertGelu -Repeat 0,5,11` (2048 channels), 3 runs each:

| Repeat | SNR vs stock, phone | table model vs stock | DSP vs model | model rounded to the output LSB vs model | DSP ms | Saturated |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 72.02 | 82.50 | 72.35 | 72.56 | 0.205 | 0 |
| 5 | 69.39 | 79.46 | 69.73 | 69.77 | 0.206 | 0 |
| 11 | 67.40 | 78.26 | 67.58 | 68.35 | 0.205 | 0 |

The DSP equals the model up to the 16-bit per-tensor output LSB (crest factor 22-35); a per-channel output LSB would
recover about 10 dB. Every stage so far sits well above the W8 linears (41-48 dB).

Infrastructure: `src/jobs/Kokoro.WrappedJob.ps1` (`New-KokoroWrappedJobSteps`) replaces the per-job copy of the checked
resource wrapper; the ALBERT linear job built on it is identical step for step to the earlier one (4,959 steps, five
shapes) and moved into `src/jobs/Kokoro.Albert16Run.ps1` with the LayerNorm and gelu jobs.

Commit: the commit that adds this file.
