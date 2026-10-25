# Representation of the teacher's generator AdaIN constants across segments, SM8550, 2026-10-20

This measures how well a base and k components reproduce the constants Kokoro computes over its own input. Those
constants are an artifact of how the teacher produced its evidence; the Student's controller stream is judged by output,
not by reproducing them.

Kokoro-Hexagon `fd04ca8`, `Invoke-KokoroDevelopment.ps1 Run -Case generator-representation`.

## Method

Segments: 170 ticks (2.125 s) cut in order from the Student's cached `af_heart` teacher evidence for the sample corpus
`build/corpus-20261020T100048`. Windows with index 7 mod 8 supply held-out segments only; the other windows supply
training segments. 48 training segments; 4 held-out segments (all from window 7).

Input encoding: teacher x stored at the decoder fixture's `DecoderScales` (fitted per channel against the stock peach
capture, correlation 1.00), f0 as int32 Q16 Hz, the fixture's source draws. Check: the peach stock capture rebuilt this way
scores 34.80 dB against stock PCM on the same job, above the 31.29 dB of the accepted DSP-decoder input; with the source on
the DSP this job measured 37.24 dB on another sentence (`generator-whole-source-sm8550-20261008.md`).

Per segment, the export generator (library `9A668F8CFB0B112AB4D04740732996CD6E1BF8340D2F061575EEE42A403B18C0`) returns
each site's moments; `New-KokoroDecoderConstantsTables` turns them into exact 1/std and mean for all 48 sites, 9,216
channels, and checks them against the device's exported K and M. Coordinates: ln(1/std) and mean/std per channel
(18,432 values). Base: the training mean. Components: principal components of the centred training rows. Each held-out
segment receives its own least-squares coordinates on the first k components; the fitted constants run through the
constants generator (library `97FD245178351F91A9FD96B0DC6DC8DFDD87DE76BB4EA14CF698CBC63F840408`) on that segment's own x and
f0, scored against the segment's exported (statistics) PCM. Boundary SNR uses the propagation metric (relative 1/std error
and mean error in std units). `Exact` writes the exact constants through the same ratio encoding.

## Result

Mean over the 4 held-out segments:

| Components | Boundary SNR (dB) | PCM SNR (dB) | Lowest segment PCM (dB) |
| --- | ---: | ---: | ---: |
| Exact | 300.68 | 46.49 | 45.17 |
| 0 | 21.60 | 2.20 | 0.00 |
| 1 | 24.45 | 3.12 | 2.08 |
| 2 | 25.95 | 2.41 | 0.54 |
| 3 | 27.29 | 4.04 | 0.23 |
| 4 | 27.41 | 3.84 | 0.50 |
| 5 | 27.48 | 3.65 | 0.51 |
| 6 | 27.93 | 3.64 | 0.36 |
| 8 | 28.14 | 3.63 | 1.16 |
| 12 | 28.73 | 4.31 | 2.80 |
| 16 | 28.94 | 4.77 | 3.66 |
| 24 | 29.57 | 5.32 | 3.78 |
| 32 | 29.87 | 6.12 | 4.34 |
| 47 | 30.21 | 5.29 | 3.28 |

Training variance explained: 51.4% (k = 1), 86.1% (4), 90.4% (6), 94.8% (12), 98.2% (24), 100% (47).
Receipt: `build/representation-sm8550-20261020T161106/representation.clixml`.

## Observations

- Whole-segment AdaIN statistics vary with content. A base plus up to 47 components fitted on 48 segments reproduces a
  held-out segment's constants to at most 30.2 dB, against the about 60 dB that 40 dB PCM requires
  (`generator-propagation-sm8550-20261020.md`). The held-out variation lies mostly outside the training subspace.
- Writing exact constants through the ratio encoding gives 45.2 to 47.5 dB, the same floor as any small input change in
  the propagation measurement.
- Teacher x exceeded the fixture's int16 range in places: 146 saturated values in held-out segment 0 and 1 to 6 in the
  others.

Limitations: 48 training segments for 18,432 coordinates; held-out segments from one window; constants are per segment, so
a coefficient path that varies within a segment is not measured here.
