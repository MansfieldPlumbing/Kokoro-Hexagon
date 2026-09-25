# Hardware receipt: speaker baseline

Date: 2026-09-24
Target: physical Samsung Galaxy S23
Pipeline: established QNN FP16 front and generator contexts

The resident known-good phrase produced 33,600 samples (1.40 seconds at
24 kHz) and played completely through the phone speaker.

| Metric | Result |
| --- | ---: |
| Front, first run | 25.6 ms |
| Generator, first run | 342.7 ms |
| Harness total | 842.6 ms |
| Warm front, three-run mean | 5.9 ms |
| Warm generator, three-run mean | 341.7 ms |
| Audio SNR | 18.43 dB |
| Non-finite samples | 0 |
| Written / played frames | 33,600 / 33,600 |

Playback completed, the receipt gate passed, and the original application
startup files were restored by exact hash. This is the audible FP16 baseline;
it does not claim that the newly proven direct W4A8 matrix path is integrated
into the complete speech graph.
