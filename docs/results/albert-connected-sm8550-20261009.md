# Connected ALBERT job on SM8550, 2026-10-09 (in progress)

`./Invoke-KokoroHexagon.ps1 AlbertJob`: the whole of stock ALBERT + bert_encoder in one DSP job (embed + LayerNorm,
mapping_in, 12 shared-layer repeats, bert_encoder), from the token ids of the hello-world capture (16 tokens) to `d_en`.
Every LSB is planned from four calibration captures (bench1-3, howareyou: 66, 128, 272, 67 tokens), never from the test
sentence. Shared W8 weights resident in VTCM (7.7 MB requested), per-operator tables streamed from DDR.

Runs to completion, 3/3 runs with identical output, 13.0 ms DSP time (249,457 ticks at 19.2 MHz).

Accuracy, not yet acceptable:

| Tensor | dB vs stock |
| --- | ---: |
| stream after mapping_in | 46.13 |
| stream after repeat 0 / 1 / 2 / 3 | 36.90 / 26.98 / 24.43 / 24.01 |
| stream after repeats 4-11 | 25.03, 26.38, 25.53, 26.63, 26.76, 27.53, 27.12, 27.58 |
| `d_en` | 25.72 |

Per operator (`AlbertJob -StopAfter`): repeat 0 up to ln_full 36.9 dB; repeat 1: q.1 36.47, k.1 30.72 (k's own
representation, same input as q). Two faults found and fixed on the way (weight blocks straddling a VTCM page: QuRT cause
0x26; conv input windows too coarse for the HMX group windows: 432 of 2048 ffn channels overflowed) are described in
`docs/handoff-20261009d.md`. Single operators alone: `albert-*-sm8550-20261009.md`.

Commit: the commit that adds this file.
