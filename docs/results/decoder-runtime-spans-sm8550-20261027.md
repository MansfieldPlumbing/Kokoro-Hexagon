# Decoder spans with the frame count read at run time, SM8550 (2026-10-27)

Kokoro-Hexagon at the commit that adds this record (parent `dff78f2`). This is the third milestone of the depth-first
decoder: the span job (`decoder-spans-equivalence-sm8550-20261027.md`) reads its frame count at run time, so one
library decodes any length up to its input capacity.

## Method

`New-KokoroDecoder16RunSteps -Delayed -Spans -RuntimeFrames` (emission parameters `DecoderDelayed`, `DecoderSpans`,
`DecoderRuntimeFrames`; `DecoderFrames` is the capacity). The job reads the frame count from the input and computes
F, 2F, the span count ceil((F + 10) / 32) and the input tile count ceil(F / 32) into VTCM. The loop bound, the
zero-filled input tiles, the pad rows and the F0 and N frame ranges of each span follow those counts. Kernel tile counts
stay at one span (1 frame tile, 2 tick tiles). Fixed-frame libraries, delayed or not, are unchanged: the six
undelayed libraries and the delayed whole and span libraries at 100 frames emit with their previous SHA-256.

`Run -Case decoder-delay-equivalence` gains the `RuntimeSpans` schedule (one library of `-Capacity` frames, 512 here)
and inputs past the capture's 165 frames (the capture's inputs repeated from frame 0). The reference is the layer job
up to 128 frames, its VTCM limit. Past that it is the layer job at 128 frames with run-time frames, in overlap-save
chunks of 96 frames with 16 frames of halo per side (`Invoke-KokoroDecoderChunks`). With supplied coefficients the
chunk boundaries do not reach x (`stock-end-to-end-sm8550-20261027.md`). The two controls are as before.

## Results

Run-time span library `F0D908F0...` (capacity 512 frames, VTCM 7,634,944 bytes), the same library in every row:

| Frames | Spans | Reference | Different bytes | Different without the shift | Reference DSP | Span DSP |
| ---: | ---: | --- | ---: | ---: | ---: | ---: |
| 54 | 2 | layer job | 0 | 109,656 | 2.90 ms | 3.80 ms |
| 100 | 4 | layer job | 0 | 202,878 | 4.90 ms | 7.50 ms |
| 128 | 5 | layer job | 0 | 259,624 | 4.95 ms | 9.42 ms |
| 300 | 10 | 4 layer chunks | 0 | 605,542 | 16.92 ms | 18.70 ms |
| 471 | 16 | 5 layer chunks | 0 | 949,400 | 24.94 ms | 29.84 ms |

The fixed-frame span jobs at 54, 100 and 128 frames, run alongside, match too (3.81, 7.55 and 9.42 ms). A run-time
span job costs what the fixed one does at the same length. DSP times are from one run each; chunked references sum
their chunks.

## Limits

- The F0 and N curves are copied into VTCM whole, at 16 bytes per frame of capacity: 131,200 bytes of Small at 512
  frames. Everything else in VTCM is the same at any length.
- x leaves the job 20 ticks late, so the generator cannot take it unchanged yet. The speech renderer and the phone's
  speech path still decode with the layer job in chunks.
- Weights are streamed once per span. At 471 frames the span job takes 29.84 ms against 24.94 ms for the chunked layer
  decode.

Receipts: `build/decoder-delay-equivalence-20261028T034533` (54, 100 and 128 frames) and
`build/decoder-delay-equivalence-20261028T034636` (300 and 471 frames).
