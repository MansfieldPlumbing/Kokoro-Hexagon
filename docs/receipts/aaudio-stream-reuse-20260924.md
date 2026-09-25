# Hardware receipt: persistent AAudio stream reuse

Date: 2026-09-24
Target: physical Samsung Galaxy S23, SM8550
Input chunk: `p01`, 33,600 frames, 1.40 seconds
Pipeline: Kokoro-82M, FP16 QNN AOT contexts, `af_heart`

One PowerShell runspace opened one native AAudio stream and wrote the same
validated PCM buffer twice as two sequential chunks. The stream was started
only for the first write and drained only after both writes.

| Metric | Result |
| --- | ---: |
| AAudio open | 82.4 ms |
| Prepared input to first playback start | 905.7 ms |
| Stream format | 24 kHz mono float PCM |
| Buffer capacity / burst | 768 / 48 frames |
| Chunks | 2 |
| Frames written | 67,200 |
| Frames consumed at drain | 67,440 |
| Underruns | 0 |
| Playback complete | yes |
| Audio SNR | 18.43 dB |
| Close result | 0 |

The second chunk reused the live stream and paid no additional open or start
operation. This receipt proves the native audio queue substrate only; the
speech waveform was synthesized once. The next long-form gate is producing
successive chunks through cached QNN contexts in the same runspace.
