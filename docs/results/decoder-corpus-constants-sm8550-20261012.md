# Decoder corpus constants: Gate 2(b)

Measured 2026-10-12 at Kokoro-Hexagon commit
`d07f9f1fc59225c5b607ad95e365badee02a2133`, on SM8550 through
`dev.mansfieldplumbing.kokoro`. Ran `Invoke-KokoroDevelopment.ps1 Run
-Case decoder-constants-corpus` with the accepted network-free peach fixture,
the seven-utterance decoder corpus, and a fresh output directory. The peach
fixture was excluded from the training corpus. Gate 2(b) passed; variant A's
PCM SHA256 matched the accepted peach hash
`E6456751BDBCCE0D5CB38DA8226B4EEC8B1C514E16626755C5BD975699374054`.

## Measurements

Each variant generated 51,000 PCM samples. RMS and peak are normalized to
full scale; SNR is measured against the peach fixture's float PCM reference.
DSP times are single-run measurements, not repeated-run medians.

| Variant | Decoder mode | Decoder DSP ms | Generator DSP ms | Samples | RMS | Peak | PCM SNR dB | Clipped samples |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| A | Statistics | 14.476 | 130.079 | 51,000 | 0.0447223 | 0.292511 | 31.29 | 0 |
| B | Corpus constants | 11.077 | 128.714 | 51,000 | 0.0439303 | 0.397308 | 0.50 | 0 |
| C | Normalization off | 10.558 | 130.100 | 51,000 | 0.0313558 | 0.332123 | -1.03 | 0 |
| D | AdaIN off | 10.579 | 131.457 | 51,000 | 0.0376770 | 0.258789 | -0.23 | 0 |
| E | Zero decoder style; statistics normalization | 14.518 | 131.584 | 51,000 | 0.0435584 | 0.283264 | 0.62 | 0 |

Listening verdict: **B only** produced intelligible peach and was described as
"not bad". A, C, D and E were not labeled. The command's `ListeningLabel`
fields remain empty; this subsequent listening observation applies only to B.

SNR below 1 dB does not discriminate here: E, the zero-style statistics path,
also measures 0.62 dB. B's intelligibility is listening evidence and must not
be inferred from its 0.50 dB waveform SNR. This receipt establishes neither
corpus-wide listening quality nor equivalence to the statistics path.

Total command wall time was 339.45 s, including 42.97 s emission: statistics
decoder 3.24 s, constants decoder 2.03 s, generator 37.70 s. Remaining preparation,
device transport, execution, playback and measurement took 296.48 s. The
in-process emission cache did not survive the preceding command process.

## Artifact identities

| Library | SHA256 |
| --- | --- |
| Statistics decoder, A/E | `99D8FA3E527A9EF0F15422A407B4A4FFFF38AD372AC029A8E5AF35A231E7A997` |
| Constants decoder, B/C/D | `4E63E1405A5486E70F316679AE143575B9C792FF8F18D09E86F47127436D2DFD` |
| Generator, A–E | `13D75D38B0B5BC8695BCAFF49378F860B5E923C80D8F14872321B14854301428` |

The generator used statistics normalization for all five variants.

Structured receipts and WAVs remain under ignored `build/`:

- Run: `build/gate2b-d07f9f1-20261012-120621-run.clixml`.
- Gate: `build/gate2b-d07f9f1-20261012-120621/acceptance-b.clixml`.
- PCM metrics: `build/gate2b-d07f9f1-20261012-120621/pcm-metrics.clixml`.
- Audio: `build/gate2b-d07f9f1-20261012-120621/{A,B,C,D,E}.wav`.
