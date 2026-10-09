# ALBERT linears on SM8550, 2026-10-09

Every distinct ALBERT `nn.Linear` shape runs on the SM8550 DSP through one job,
`src/jobs/Kokoro.AlbertLinear16Run.ps1`: stored 16-bit token tensor -> identity windows -> HMX conv (kernel 1, W8 per
output channel, one weight plane) -> combine -> 16-bit output. It reuses the decoder's bodies unchanged
(`New-KokoroAdaInLeaky16Steps -Identity`, `New-KokoroHmxConvPlanesLoopSteps`, `New-KokoroPlaneCombineLoopSteps -Mode Conv`).

Input: stock capture of hello world (`həlˈoʊ wˈɜɹld.`, 16 tokens, `./Invoke-KokoroHexagon.ps1 StockCapture -Block albert`).
Each linear's input is the captured input; scales come from the same capture (a kernel check, not a calibrated
deployment). Command: `./Invoke-KokoroHexagon.ps1 AlbertLinear -Linear mapping_in,query.0,dense.0,ffn.0,ffn_output.0,bert_encoder,query.11,ffn.11`.
3 runs each; DSP time is the median, weight DMA from DDR included.

| Linear | Shape | SNR vs stock, phone | Windows A16W8 prediction | DSP ms | Saturated | Skel SHA-256 prefix |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| mapping_in | 768 x 128 | 46.42 | 46.67 | 0.03 | 0 | 9F3FD58FDB072698 |
| query.0 | 768 x 768 | 45.22 | 45.22 | 0.06 | 0 | 6EC649B5E643CDE2 |
| dense.0 | 768 x 768 | 44.04 | 44.03 | 0.06 | 0 | 6EC649B5E643CDE2 |
| ffn.0 | 2048 x 768 | 43.46 | 43.46 | 0.11 | 0 | EBBEB538BE4C5170 |
| ffn_output.0 | 768 x 2048 | 48.82 | 48.83 | 0.12 | 0 | FDD11E1A4A12FCC2 |
| bert_encoder | 512 x 768 | 42.11 | 42.12 | 0.05 | 0 | CB083D1FF6F2A920 |
| query.11 | 768 x 768 | 41.87 | 41.88 | 0.06 | 0 | 6EC649B5E643CDE2 |
| ffn.11 | 2048 x 768 | 41.41 | 41.42 | 0.11 | 0 | EBBEB538BE4C5170 |

The DSP matches the Windows measurement of the same quantization (`AlbertError`, A16W8) to 0.01 dB except
`mapping_in` (0.25 dB lower), so the job adds no error beyond W8 weights and 16-bit activations. Single-linear error
only: propagation through 12 shared-layer repeats is not measured until LayerNorm, GELU and attention run on the DSP.
No new instruction forms (all bodies are the decoder's, already checked against the SDK assembler).

Commit: the commit that adds this file.
