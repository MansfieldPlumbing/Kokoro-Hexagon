# Generator in alternating spans with saved section state (SM8550)

Kokoro-Hexagon `970fcf8`. Case `generator-tile-equivalence` with `-Joint Whole`, `Front` and `Spans`. Receipts:
`build/generator-tile-equivalence-20261023T234637` (Spans) and the Whole and Front runs of the same day.

## Method

With supplied source streams, the depth-first whole job runs in spans of `-SpanTiles` 256-channel tiles (default 20, a
multiple of 10 and of the block size). A span plan fixed at build time gives each stage the tiles its upstream has
finished:

1. 256-channel front over the span's decoder tiles.
2. Chunked 256-channel section steps.
3. 128-channel front over the 256-channel mean that has one tile of right halo.
4. Lockstep 128-channel section steps.
5. Tail, with two tiles of halo.

At the end of the input every stage finishes.

- **DDR workspace:** holds the whole-length tensors: each section's input and output, and the PCM.
- **VTCM state:** each section's state is saved to a workspace slot after its steps and restored before its next ones.
  The chunked section saves its history, rings, records and K/M/S. The backward section saves its rings, records,
  K/M/S, progress words and resident weights.
- **Fronts and tail:** each works over a tile range in span-sized VTCM. It reads its input with halo from the
  full-length tensor.

## Result

Int8 resblock weights, supplied AdaIN values, blocks of 4 tiles.

| Check | Frames | Spans | Compared | Depth-first ms |
| --- | ---: | --- | --- | ---: |
| Whole against the layer job | 7,801 | 3 (20 tiles) | every section's input and output, PCM: equal | 38.53 |
| Whole against the layer job | 7,801 | 2 (40 tiles) | every section's input and output, PCM: equal | 37.20 |
| Front against the layer job | 1,700 | 3 (20 tiles) | 256-channel mean: equal | 20.93 |
| Spans, 20 against 40 tiles | 31,201 (6.5 s) | 9 and 5 | both sections' outputs, PCM: equal | 124.83, 122.16 |

- **Whole PCM:** SHA-256 704674F05D818666A844408BEAAEE2B65FA6879C0A357BE15034BC6FFED61D20, identical to the layer job.
  Library SHA-256 prefix 27C755C2.
- **Spans input:** the x, S0 and S1 streams repeated frame by frame four times. The layer job cannot run that length
  (its tail alone needs whole-length VTCM), so this check is self-consistency across span sizes.
- **Spans PCM:** SHA-256 prefix 8BECC02202423AFF.
- **VTCM:** 7,602,176 B at 20-tile spans and 7,929,856 B at 40-tile spans, independent of the length.
- **Library size:** 1,482,996 B (20-tile spans) and 1,183,988 B (40-tile spans) at 6.5 s. It grows with the number of
  spans.

## Not yet done

- **Library size:** every span's code is emitted. A runtime loop over the uniform middle spans, with span-relative
  base registers, would make the library independent of length.
- **State traffic:** the saved state is the whole range of persistent regions. The backward section's resident
  weights could be reloaded from the weights input instead of saved.
- **Front size limit:** spans larger than about 40 tiles do not fit the 128-channel front's span regions in VTCM.
