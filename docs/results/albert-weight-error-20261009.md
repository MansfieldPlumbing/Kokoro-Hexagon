# ALBERT linear quantization error, Windows, 2026-10-09

Stock ALBERT capture of hello world (`həlˈoʊ wˈɜɹld.`, 16 tokens, af_heart, seed 17), pinned Kokoro `dfb907a0`,
torch 2.14.0+cpu, transformers 5.17.0 (sdpa attention, gelu_new, LayerNorm eps 1e-12):
`./Invoke-KokoroHexagon.ps1 StockCapture -Block albert` (165 tensors: embeddings, the 128->768 mapping, all 12 repeats
of the shared layer, `bert_dur` [1,16,768], `d_en` [1,512,16], every ALBERT and `bert_encoder` parameter).

Measured with `./Invoke-KokoroHexagon.ps1 AlbertError -Path stock-albert-capture-hello`: each linear on its captured
input, float64, against its captured output. The unquantized linear agrees with the capture at 129-135 dB, so the
comparison is sound. W8 = int8 symmetric per output channel (absmax/127), one weight plane. A16 = 16-bit per-tensor
symmetric activations. Single-layer error only; propagation through 12 repeats is not measured here.

Worst repeat per linear, dB SNR against stock:

| Linear | Shape | W8 | A16W8 | A8W8 | max abs input |
| --- | --- | ---: | ---: | ---: | ---: |
| mapping_in | 768 x 128 | 46.67 | 46.67 | 40.48 | 3.12 |
| query | 768 x 768 | 41.88 | 41.88 | 27.55 | 11.53 |
| key | 768 x 768 | 44.78 | 44.78 | 39.42 | 11.53 |
| value | 768 x 768 | 42.34 | 42.33 | 28.25 | 11.53 |
| dense | 768 x 768 | 43.14 | 43.14 | 37.11 | 6.35 |
| ffn | 2048 x 768 | 41.42 | 41.42 | 23.41 | 26.79 |
| ffn_output | 768 x 2048 | 48.03 | 48.03 | 30.96 | 13.04 |
| bert_encoder | 512 x 768 | 42.12 | 42.12 | 25.61 | 11.63 |

16-bit activations cost nothing measurable (A16 alone: 75-97 dB). 8-bit activations lose up to 18 dB on `ffn`, whose
input is the attention LayerNorm output with outliers to 26.8. ALBERT takes the generator's A16W8 HMX path
(`Kokoro.HmxConvPlanes.ps1`, a linear being a kernel-1 conv over tokens), not A8.

Commit: the commit that adds this file.
