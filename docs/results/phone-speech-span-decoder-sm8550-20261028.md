# Text to WAV on the phone with the span decoder, SM8550 (2026-10-28)

Kokoro-Hexagon at the commit that adds this record (parent `cf718fd`). The speech path of
`text-to-wav-phone-sm8550-20261027.md`, with the decoder changed from the layer job in overlap-save chunks to the
run-time span decoder (`decoder-runtime-spans-sm8550-20261027.md`) in one job.

## Method

`PhoneSpeech -Parameters @{Text=...; Runs=3}` (`Invoke-KokoroPhoneSpeech -DecoderSchedule Spans`, the default). On
the host, the speech renderer's `Decode` runs the span library of 512 frames in one Direct job for streams up to that
length (`DecoderSchedule`, `DecoderSpanCapacity`). It then moves x back by the job's 20-tick output delay
(`ConvertFrom-KokoroDelayedCroutons`, `tools/Kokoro.CaptureKernels.psm1`, shared with the phone). Longer streams, and
`-DecoderSchedule Chunks`, use the layer job in chunks as before. The phone's speech mode loads the span library and
shifts x the same way. As a check, the host reference is also decoded on the other schedule and the two x compared.

Text, voice and seed as in the earlier record: 193 phonemes, 471 decoder frames, 942 ticks, 11.775 s of audio.

## Results

| Check | Result |
| --- | --- |
| Reference x, spans against chunks | identical (`431445A7...`) |
| Reference WAV against the earlier record's reference | identical (SHA-256 `88B3CE80...`) |
| Phone WAV against the reference | 57.47 dB waveform SNR, 61.61 dB magnitude SNR, f0 difference 0 cents |
| Reference decoder DSP | 29.89 ms in one span job (chunks: 24.88 ms in 5 jobs) |

On the phone:

| Run | Phonemizer | Front end | Decoder (DSP) | Generator | Total |
| --- | ---: | ---: | ---: | ---: | ---: |
| 0, first | 36.6 ms | 8,341.8 ms | 177.3 ms (29.70) | 430.3 ms | 8,995.7 ms |
| 1 | 0.6 ms | 4,793.3 ms | 54.5 ms (29.70) | 391.0 ms | 5,240.6 ms |
| 2 | 0.6 ms | 4,605.9 ms | 50.1 ms (29.92) | 373.8 ms | 5,031.7 ms |

The decoder's DSP time rises by about 5 ms because weights are streamed once per span. Its wall time falls from 96.8 and
85.5 ms (warm runs of the earlier record) to 54.5 and 50.1 ms: one job replaces five, and the CPU time around the
DSP calls falls with it. The phone's WAV compares with the reference as in the earlier record (57.5 dB there). The
difference comes from the phone's front end, not the decoder.

## Limits

- x is still written to the output buffer, moved by 20 ticks on the CPU and passed to a second job for the generator.
- Streams longer than 512 frames fall back to chunks of the layer job.

Receipt: `build/phone-speech-20261028T035548` (phone-speech.clixml, reference.wav, pack/, compare/).
