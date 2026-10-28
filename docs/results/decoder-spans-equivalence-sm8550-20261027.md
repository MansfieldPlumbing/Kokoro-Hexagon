# Decoder in 32-frame spans against the layer job, SM8550 (2026-10-27)

Kokoro-Hexagon at the commit that adds this record (parent `4c3ea3d`). This is the second milestone of the
depth-first decoder: the delayed decoder (`decoder-delay-equivalence-sm8550-20261027.md`) runs one span at a time
through every layer.

## Method

`New-KokoroDecoder16RunSteps -Delayed -Spans` (emission parameters `DecoderDelayed`, `DecoderSpans`) loops over
ceil((F + 10) / 32) spans. Span s takes frame tile s (tick tiles 2s and 2s + 1) through every layer in run order. Each
tensor holds one span after a lead tile:

- asr tile s is copied from the input, or zero-filled past the input. F0 and N are computed for the frames that fall
  in tile s at each tensor's delay (`New-KokoroStrideConv16Steps -CallerStart`).
- Before each delayed convolution, the history of its input windows is restored into the lead tile. The history is the
  last row pairs of every 32-channel block of that input's previous span: 4 row pairs for E's identity windows (asr_res
  reads up to 8 rows back), 1 row pair for the others (`New-KokoroTileTailCopy16Steps`). This span's tail is then
  saved. The history region is 130,304 bytes.
- The decode.3 pool now computes output tiles 2t and 2t + 1 from input tile t and the last row pair of tile t - 1, which
  sits in its input's lead tile. In whole-tensor jobs that lead tile holds zero. In span jobs it is carried from span to
  span.
- Pads are relative to the span: lead rows in span 0, and rows from count + delay - 32k x span through the span's k
  tiles.
- Each convolution's weights are streamed once per span. x tiles 2s and 2s + 1 are copied to the output after each
  span.

Without `-Delayed`, the six decoder libraries listed in the milestone 1 record emit with their previous SHA-256. The
whole-tensor delayed job changes with the new pool form and its lead tile, and passes again below.

The check is `Run -Case decoder-delay-equivalence -Parameters @{Schedules=...}`, as in milestone 1: the same input,
tables, weights and K/M for every job, and x compared with the layer job 20 ticks later, with the same two controls.

## Results

| Frames | Spans | Schedule | Different bytes | Different without the shift | Delayed VTCM | Layer DSP | Delayed DSP |
| ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 54 | 2 | Whole | 0 | 109,656 | 7,634,944 | 2.90 ms | 2.97 ms |
| 54 | 2 | Spans | 0 | 109,656 | 7,634,944 | 2.90 ms | 3.78 ms |
| 64 | 3 | Whole | 0 | 129,929 | 7,634,944 | 2.90 ms | 4.00 ms |
| 64 | 3 | Spans | 0 | 129,929 | 7,634,944 | 2.90 ms | 5.69 ms |
| 100 | 4 | Whole | 0 | 202,878 | 8,224,768 | 4.91 ms | 5.05 ms |
| 100 | 4 | Spans | 0 | 202,878 | 7,634,944 | 4.91 ms | 7.50 ms |
| 118 | 4 | Whole | 0 | 239,337 | 8,224,768 | 4.97 ms | 5.11 ms |
| 118 | 4 | Spans | 0 | 239,337 | 7,634,944 | 4.97 ms | 7.51 ms |
| 128 | 5 | Spans | 0 | 259,624 | 7,634,944 | 4.96 ms | 9.42 ms |

x is identical for every frame count and schedule. The span job's VTCM, 3,440,640 bytes of it the streamed-weight
buffer, and its code (68,536 bytes) are the same at 100 and 400 frames (emitted, not run). DSP times are from one run
each.

## Limits

- The reference bounds the check. The layer job's layout admits at most 128 frames (at 165 frames its windows and
  their read extent cross a VTCM page), so the span job is compared up to 128 frames, 5 spans.
- The span job costs more DSP time than the layer job: 9.42 against 4.96 ms at 5 spans. Every convolution's weights
  stream once per span (Get-KokoroDecoder16Layout gives 31,688,704 bytes of W8 per span), and HMX runs one tile per
  call.
- Frame counts are fixed at emission; the span count is not yet read at run time.

Receipts: `build/decoder-delay-equivalence-20261028T033545` (54, 64, 100 and 118 frames, both schedules) and
`build/decoder-delay-equivalence-20261028T033716` (128 frames, spans).
