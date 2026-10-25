# Generator with its source on the DSP at any length (SM8550)

Case `generator-tile-equivalence`, fixture `build/generator-whole-source-fixture-20261008` (7,801 frames, 1.625 s;
input x, f0 and the noise draws). Weights are int8 for the resblocks and `noise_res`, with supplied (constants) AdaIN
values. Follows `generator-source-on-dsp-sm8550-20261024.md`, where the harmonic source, its STFT and the `har`
phase-major layout ran over the whole input in VTCM and limited the job to about 2 s.

## Method

**Harmonic source and STFT in chunks** (`-SourceChunkTiles`, default 128 `har` tiles). Each chunk computes its samples
from 64 before its first tile to 64 after its last, which is the reach of the STFT windows:

- Phase head, segments and tail run as separate pieces. The running phase sum P_k crosses chunks in one carry word.
- Voicing, merge and seeded noise run over the chunk's range. Overlapping samples are recomputed, and every sample
  depends only on its own inputs.
- Reflect padding: the first chunk pads its front, the last chunk its back.
- STFT batches run over the chunk's tiles from a virtual signal base, and their `har` tiles go to the DDR workspace.

**`har` phase-major layout in chunks** of 8 slow tiles, each from the 60x tiles its rows read, with virtual base
pointers.

**Defect found.** A five-argument tile-parallel call stored its count in the slot that the join reads as the worker
report. The join could end before the workers finished, and the PCM differed between runs. In jobs with a chunked
section the count now goes only to the slot workers read (offset 56). Layer jobs keep their pinned emission.

## Result

**1.625 s, depth-first with spans, against the layer job.** Every section's input and output, both computed sources,
the 60x `har` planes, the phase-major `har` planes and the PCM are equal to the layer job's byte for byte. PCM SHA-256
AF52480D4594AC4EFD49CAC413CFD6CE6C5C7B86599C15330FEF8E0E33049B93.

| Source chunk | Chunks | DSP ms | Layer job ms | Library bytes | VTCM bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| `har` layout chunked, source whole | | 62.37 | 66.83 | 1,249,524 | 7,602,176 |
| 128 tiles | 2 | 62.85 | 66.15 | 1,253,620 | 7,602,176 |
| 16 tiles | 16 | 62.60 | 66.67 | 1,261,812 | 7,602,176 |

**11.375 s** (`-Joint SpansSource -Repeat 7`, 54,601 frames; the fixture's x, f0 and noise repeated). The layer job
does not fit VTCM at this length, so the check is between span sizes: PCM and every section's output are identical.

| Span tiles | Spans | DSP ms | Times real time | Library bytes | VTCM bytes |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 20 | 15 | 358.70 | 31.7 | 1,769,716 | 7,602,176 |
| 40 | 8 | 352.83 | 32.2 | 1,941,748 | 7,929,856 |

PCM SHA-256 55AACD7654AE27E73406F2C9A026C2AE322B3804CC9EAE3D26C36BE816A78C03.

`VerifyEmission`: every pinned recipe is byte-identical to the emission baseline.

## Not yet done

- **Library growth.** Source chunks, STFT batches and `har` layout chunks are unrolled, so the library grows with
  length (1.25 MB at 1.6 s, 1.77 MB at 11.4 s). A chunk of 240 tiles is 128 f0 frames exactly, which would make the
  middle chunks uniform and allow a runtime loop.
- **Profile.** The source costs about 23 ms per 1.6 s. The one-branch chunked `noise_res.1` schedule, synchronous
  weight DMA and dispatch overhead are the candidates.
