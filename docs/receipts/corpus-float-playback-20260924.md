# Hardware receipt: corpus float playback

Historical QNN reference playback only; this does not validate the direct
PowerShell phoneme-to-PCM product path.

Date: 2026-09-24
Target: physical Samsung Galaxy S23, SM8550, Hexagon V73
Model: Kokoro-82M
Weight path: FP16 QNN AOT contexts
Voice: `af_heart`
Workload: frozen ten-phrase corpus, ten warm executions per stage

The corpus ran after moving quality comparison and diagnostic WAV creation out
of the first-audio path and writing float PCM directly to the Android audio
sink. All ten phrases synthesized and played completely. Nine passed the
12 dB reference-quality gate; `p02` remained the known quality-gate failure at
6.06 dB and was excluded from passing aggregates.

| Metric | Earlier diagnostic path | Float playback path |
| --- | ---: | ---: |
| Passing phrases | 9 | 9 |
| Passing audio | 23.12 s | 23.12 s |
| Generator RTF mean | 0.3725 | 0.3724 |
| Generator RTF p50 | 0.4147 | 0.4180 |
| Generator RTF p95 | 0.4611 | 0.4601 |
| Prepared input to playback start, mean | 2,565.5 ms | 1,648.2 ms |
| Mean audio SNR | 22.10 dB | 22.10 dB |
| Complete playback | yes | yes |

Mean prepared-input-to-playback handoff decreased by 917.3 ms, or 35.8%,
without a material generator or quality change. The shortest 64-frame phrase
decreased from 1,650.6 ms to 772.1 ms. Longer phrases still pay for complete
waveform generation and copying before playback; persistent chunked synthesis
and native AAudio are required to remove that structural delay.

## Per-phrase results

| ID | Capacity | Audio | Generator mean | Playback start | SNR | Gate |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| p01 | 64 | 1.400 s | 343.0 ms | 772.1 ms | 18.43 dB | pass |
| p02 | 96 | 1.900 s | 587.3 ms | 1,159.4 ms | 6.06 dB | quality |
| p03 | 96 | 1.975 s | 587.7 ms | 1,202.5 ms | 22.33 dB | pass |
| p04 | 96 | 2.300 s | 589.3 ms | 1,159.3 ms | 22.03 dB | pass |
| p05 | 128 | 2.700 s | 1,161.5 ms | 1,844.0 ms | 23.44 dB | pass |
| p06 | 160 | 3.275 s | 1,369.0 ms | 2,163.6 ms | 24.06 dB | pass |
| p07 | 128 | 2.525 s | 1,161.7 ms | 1,855.5 ms | 22.61 dB | pass |
| p08 | 128 | 2.575 s | 1,162.2 ms | 1,833.3 ms | 20.60 dB | pass |
| p09 | 160 | 3.250 s | 1,369.3 ms | 2,166.0 ms | 23.27 dB | pass |
| p10 | 128 | 3.125 s | 1,163.2 ms | 1,837.7 ms | 22.11 dB | pass |
