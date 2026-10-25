# Whole generator time split, SM8550

Kokoro-Hexagon after `6304583`, `Run -Case generator-pmu -Parameters @{Profiles=@('P3'); Parity='Pcm'}`: the whole
generator with the harmonic source and supplied AdaIN values (`KokoroGeneratorWholeSource16Run`, 10,201 frames,
51,000 samples, batches of 14 tiles, four HVX threads), on the accepted constants input of
`generator-constants-full-corpus-20261012-143702`. The unprofiled run's PCM equals that receipt's variant G PCM byte for
byte (89.11 ms); its library hash differs from the receipt's, so only the PCM gate applies. Two profiled runs (event sets
A and B) measured 90.12 and 90.61 ms; the categories and stages account for the same ticks.

## By category (event set A)

| Category | ms | Calls | HVX packets |
| --- | ---: | ---: | ---: |
| Matrix-unit convolutions | 26.26 | 709 | 0 |
| AdaIN and Snake window fill | 23.59 | 648 | 44,601,957 |
| Plane combine | 13.29 | 720 | 16,204,922 |
| DMA | 8.16 | 285 | 648 |
| Unmarked | 7.91 | 3,182 | 30,752 |
| Source (phase, voicing, merge, STFT) | 5.13 | 1 | 2,875,116 |
| Tail | 3.95 | 1 | 1,446,271 |
| Tile fixes | 0.94 | 350 | 88,608 |
| Synchronization | 0.59 | 1,416 | 0 |
| Mean | 0.21 | 4 | 355,404 |

HVX arithmetic (window fill, combine, mean) is 41.2% of the generator; the matrix unit 29%.

## By stage (event set A)

| Stage | ms | Stage | ms |
| --- | ---: | --- | ---: |
| Source | 5.13 | Front128 | 0.74 |
| Har layout | 4.74 | Noise128 | 12.88 |
| Front256 | 0.42 | Ups128 | 2.34 |
| Noise256 | 6.14 | Res128_0 | 9.47 |
| Ups256 | 1.06 | Res128_1 | 11.23 |
| Res256_0 | 4.89 | Res128_2 | 12.96 |
| Res256_1 | 6.12 | Mean128 | 0.33 |
| Res256_2 | 7.51 | Tail | 3.95 |
| Mean256 | 0.13 | | |

The source branch (source, har layout and the two noise resblocks) is 28.89 ms, about a third of the generator.

## Observations

- After the matrix work halves with one weight plane (W4 or W8; `generator-tile-schedule-sm8550-20261021.md`), the
  vector side (38 ms here) is the larger of the two by about three to one, so overlapping the matrix unit with HVX
  saves at most the matrix side; further speed comes from the vector side: the window fill and the combine.
- The source branch is the largest single target after the resblocks.
