# Hardware receipt: float playback handoff

Date: 2026-09-24
Target: physical Samsung Galaxy S23, SM8550
Phrase: `p01`, 33,600 samples, 1.40 seconds at 24 kHz
Pipeline: Kokoro-82M, FP16 QNN AOT contexts, `af_heart`

The diagnostic runner previously converted every float sample to PCM16 and
created a WAV file before starting `AudioTrack`. The revised path validates
the float buffer with runtime extrema, writes float PCM directly, starts
playback, and performs oracle comparison and WAV creation while audio is
already playing.

| Metric | Before | After |
| --- | ---: | ---: |
| Front | 21.3 ms | 22.3 ms |
| Generator | 341.6 ms | 341.4 ms |
| Prepared input to playback start | 1,650.6 ms | 780.7 ms |
| Audio SNR | 18.43 dB | 18.43 dB |
| Playback | complete | complete |

Prepared-input-to-playback handoff decreased by 869.9 ms, or 52.7%. The
generator timing did not materially change. The measured improvement is host
audio-path work removed from the critical path, not a DSP acceleration claim.

The runner still uses managed `AudioTrack` as a diagnostic bridge. The release
appliance target remains a persistent native AAudio stream.
