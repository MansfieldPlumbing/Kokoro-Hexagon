# ALBERT job: one conversion of the stream for query, key and value (SM8550)

Kokoro-Hexagon `867e6a5` plus this change. `Test-KokoroAlbertJob -Runs 5`, with and without `-SharedWindows`
(emission parameter `AlbertSharedWindows`, `New-KokoroAlbert16RunSteps -SharedWindows`), alternated over two rounds;
test capture `stock-albert-capture-hello` (16 tokens), calibration captures bench1-3 and howareyou.

## Change

Each linear converts its 16-bit input into HMX's two conv-input windows (`albert_identity_<channels>`), contracts and
combines. Query, key and value read the same stream `H` with identical identity tables, and neither query's contraction
nor its combine writes the windows. With `-SharedWindows`, key and value skip the conversion and read the windows query
wrote: 24 of the job's 74 conversions. `New-KokoroAlbertJobInput` refuses the input if key's or value's identity table
differs from query's in any byte.

## Result

| Job | DSP median, 5 runs, round 1 / round 2 | Output tensor SHA-256 | Library |
| --- | ---: | --- | --- |
| Each linear converts its input | 13.00 / 13.00 ms | `28E3D7274375D6E6...` | `3888705E1EC13C28...` |
| Shared windows | 12.54 / 12.55 ms | `28E3D7274375D6E6...` | `AAEAB26AD194AEEB...` |

The output tensors (`d_en` and the stream after mapping_in and each repeat, without the header's tick counts) are
byte-identical in all four runs; `d_en` is 25.72 dB against stock in both.

## Observations

- Shared windows remove 0.45 ms (3.5%), about 19 microseconds per skipped conversion at 16 tokens.
- The conversion is a small part of this job at 16 tokens; the rest of the 12.5 ms is not yet broken down by
  category (per-operator table DMA, synchronization after each call, attention, contractions).

Receipt: `build/albert-shared-windows.clixml`.
