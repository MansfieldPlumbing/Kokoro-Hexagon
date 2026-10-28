# Generator tail streamed per batch, SM8550 (2026-10-28)

Kokoro-Hexagon at the commit that adds this record (parent `88cd5a8`). The generator tail (leaky_relu, `conv_post`,
spectrum, iSTFT, PCM) no longer holds its whole tile range in VTCM. Its VTCM is now one batch and its halo, the same
for any range, so a span's tail no longer grows with the span.

## Method

`Add-KokoroGeneratorTail16JobSteps` (`src/jobs/Kokoro.GeneratorTail16Run.ps1`) runs each batch of output tiles as one
pass:

- The spectrum tiles the batch needs (one tile each side) that are not yet in the spectrum window are computed in
  chunks of at most one batch. Each chunk's input arrives by DMA with one tile of halo on each side. HVX then applies
  leaky_relu into the `conv_post` input window, HMX runs `conv_post`, the combine writes the logits, and the spectrum
  kernel writes the chunk's Re/Im planes into the spectrum window.
- HMX runs the iSTFT taps over the batch from the spectrum window, which holds the batch and one tile each side
  contiguously. The combine and the copy write the PCM as before.
- Before the next batch, the spectrum tiles still needed (the last two) move to the window's front. Tiles -1 and Tiles
  are filled with the zero halo when a batch reaches them.

Every tile's arithmetic is unchanged; only the order of tiles and where they are held in VTCM changed.

The tail's VTCM, from `Get-KokoroGeneratorTail16Layout` (16-tile batches):

| Range | Before | Streamed |
| --- | ---: | ---: |
| 244 tiles (1.625 s, one call) | 6,291,456 B | 1,638,400 B |
| One 60-tile span's 360 tiles and halo | 8,650,752 B | 1,638,400 B |

The 60-tile span's tail no longer exceeds VTCM. The 128-channel span front still does (11,599,872 B at 31,201 frames,
60-tile spans).

The check is `Run -Case generator-tile-equivalence -Parameters @{Joint='WholeSource'; Runs=1}`, run once at `88cd5a8`
and once with the streamed tail, on the same input. In it, the layer job runs the tail over the whole range in one call,
and the depth-first job (the kept settings: 60-tile spans, host coefficients, queued weights, resident sources) runs it
once per span.

## Results

| Tail | Layer PCM SHA-256 | Depth-first PCM SHA-256 | Layer DSP | Depth-first DSP |
| --- | --- | --- | ---: | ---: |
| At `88cd5a8` | `AF52480D...` | `AF52480D...` | 67.04 ms | 39.36 ms |
| Streamed | `AF52480D...` | `AF52480D...` | 66.63 ms | 39.69 ms |

PCM is byte-identical in all four jobs (39,000 samples) and equals the PCM of `generator-source-on-dsp-sm8550-20261024.md`.
The final tensor before the tail is identical in all four (`607A350B...`). DSP times are from one one-shot run each.

## Limits

- At this fixture's length one 60-tile span covers the input, so the depth-first job's tail ran as one call here. The
  layer job's single call covered 244 tiles in 16 batches, so the window's carry ran 15 times.
- The tail still reads its input from the DDR workspace, the last section's output.

Receipts: `build/tail-stream-committed-20261028-020731`, `build/tail-stream-20261028-020731` and
`build/tail-stream-20261028-020731.clixml`.
