# Hardware receipt: native AAudio speaker path

Historical QNN-backed audio-sink test. The native AAudio result does not make
the QNN model path a product dependency or prove direct-path speech.

Date: 2026-09-24
Target: physical Samsung Galaxy S23, SM8550
Phrase: `p01`, 33,600 frames, 1.40 seconds
Pipeline: Kokoro-82M, FP16 QNN AOT contexts, `af_heart`

PowerShell bound the Android NDK AAudio C ABI directly through
`libaaudio.so`. The stream used blocking float PCM writes and no managed
`Android.Media.AudioTrack` object.

| Metric | Result |
| --- | ---: |
| Front | 41.2 ms |
| Generator | 341.3 ms |
| Whole waveform ready | 745.5 ms |
| AAudio stream open | 81.6 ms |
| Prepared input to playback start | 910.2 ms |
| Sample rate | 24,000 Hz |
| Channels | 1 |
| Format | float PCM (`AAUDIO_FORMAT_PCM_FLOAT`) |
| Buffer capacity | 768 frames |
| Frames per burst | 48 |
| Frames written / consumed | 33,600 / 33,600 |
| Underruns | 0 |
| Audio SNR | 18.43 dB |
| Close result | 0 |

Playback completed through the phone speaker and the receipt gate passed.
The stream was opened for this single diagnostic phrase, so this result does
not claim a first-audio improvement over the earlier managed static-buffer
test. The verified AAudio stream is intended to stay open in the persistent
long-form runspace, where stream-open and first-start costs are paid once.

ABI source: AOSP `frameworks/av` commit
`9e7dd63dfff0cc967f025ea9e27a299aaa99fd69`, `AAudio.h` blob
`25ad5f8ef976c33b8670e4217d3f984c13096829`.
