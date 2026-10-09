# ALBERT attention and embeddings on SM8550, 2026-10-09

Two more integer kernels, run on the SM8550 DSP from the stock hello-world ALBERT capture (16 tokens) and compared with the
captured stock outputs. Scales come from the same capture (kernel checks, not calibrated deployment).

## Precision choice (Windows, `Measure-KokoroAlbertAttention`)

Context of the attention core against the captured context, repeats 0, 5, 11. The float model agrees with the capture at
118.6-128.0 dB.

| q, k, v precision | dB |
| --- | ---: |
| q 16-bit, k and v int8 per row (one HMX weight plane) | 34.8-41.5 |
| q 16-bit, k and v 16-bit per tensor | 75.5-80.3 |
| q 12-bit (int32 headroom for the 64-term q.k sums), k and v 16-bit | 66.7-67.7 |

int8 k and v would fall below the linears, so the attention core takes 16-bit k and v and runs on HVX.

## Attention core (`src/kernels/Kokoro.Attention16.ps1`)

k rescaled to one LSB per head and q to q' (|q'| <= 2047) with q'_c k'_c in one LSB per head (two
`New-KokoroScaleConvert16Steps` passes); per head: k and v rows broadcast across lanes, q.k by vmpy plus a rotate-add lane
reduction, softmax per query row over the keys (row max, exp2 by the Q15 Horner polynomial of `Kokoro.TailSpectrum16.ps1`,
padded keys masked, one exact reciprocal per row, Q15 probabilities), context by probability-pair splats against v, no
reduction. Structure after MNN `43bc0686` `attention_common.hpp`. `./Invoke-KokoroHexagon.ps1 AlbertAttention -Repeat 0..11`:

| Repeat | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Context dB vs stock, phone | 70.10 | 68.36 | 67.32 | 67.11 | 67.25 | 67.29 | 66.24 | 66.75 | 67.48 | 67.13 | 66.40 | 66.81 |
| Precision model (q 12-bit, k, v 16-bit per tensor) | 67.66 | 67.48 | 66.26 | 67.23 | 65.71 | 66.77 | 66.96 | 67.54 | 66.20 | 67.77 | 67.78 | 66.65 |

0.473-0.476 ms for 12 heads, 0 saturated. With only q rescaled (k at its per-channel LSB) the core measured 57.88-65.51 dB:
q' channels with a small k LSB kept few bits. Rescaling k per head removed that 2-8 dB.

## Embeddings (`src/kernels/Kokoro.Embed16.ps1`)

Token-id gather from gather-ready word rows (`ConvertTo-KokoroEmbeddingRows`), ids clamped to the vocabulary, plus the
position + token type 0 tensor, then `Kokoro.LayerNorm16.ps1` over 128 channels. Structure after MNN `shared_gather_ops.cc`.
`./Invoke-KokoroHexagon.ps1 AlbertEmbed`: from the captured token ids, 75.96 dB against the captured embeddings output,
0.045 ms, 0 saturated.

Every ALBERT operator now runs on the DSP. Single-stage checks only: accuracy through 12 shared-layer repeats is measured
by the connected job (handoff next step).

Commit: the commit that adds this file.
