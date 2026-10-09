# HVX threads and batch size for the decoder + generator job, SM8550, 2026-10-09

`Compare-KokoroSetup -Case decoder-generator-hello-sm8550 -Setup Baseline, Threads2, Threads3, Batch16, Batch32, Batch44`
(`tools/Kokoro.Evaluator.psm1`), commit `6736192`. Hello world (1.625 s of audio), captured asr/F0/N to PCM; median of
3 runs per setup. Noise floor measured the same day: 106.9-110.2 ms over 5 unchanged Baseline runs (3.0%).

| Setup | HVX threads | Batch tiles | Median | vs Baseline | PCM |
| --- | ---: | ---: | ---: | ---: | --- |
| Batch32 | 4 | 32 | 106.404 ms | -1.5% (within noise) | `69F79772...`, identical |
| Baseline | 4 | 22 | 107.992 ms | | `69F79772...` |
| Batch16 | 4 | 16 | 111.750 ms | +3.5% | identical |
| Threads3 | 3 | 22 | 113.999 ms | +5.6% | identical |
| Threads2 | 2 | 22 | 125.472 ms | +16.2% | identical |
| Batch44 | 4 | 44 | refused at emission | | ups[1] input planes cross a 4 MiB VTCM boundary |

Every setup produced the same PCM bytes (31.99 dB against stock, 0 clipped): thread count and batch size change the
schedule, not the arithmetic. Four HVX threads are clearly best; batch size between 16 and 32 is within noise. The
remaining time in this job is not in these two parameters (candidates: the decoder's single HVX thread and
unoverlapped weight DMA; generator combine + moments fusion).
