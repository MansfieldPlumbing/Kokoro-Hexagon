# Text to WAV on the phone, SM8550 (2026-10-27)

Kokoro-Hexagon after `f8a452f`, `Invoke-KokoroDevelopment.ps1 PhoneSpeech` (`Invoke-KokoroPhoneSpeech`). One process on
the phone, the app's PowerShell runspace (`src/runspace/KokoroGeneratorTailProbe.ps1` speech mode), takes the text to a
WAV file:

1. our compiled phonemizer driver;
2. the stock front end on the CPU (the host port, `tools/Invoke-KokoroPrecomputedDecoder.ps1` Library mode, with its
   numeric kernels prebuilt on the host, as in `frontend-phone-cpu-sm8550-20261027.md`; 8 worker threads);
3. the decoder on the DSP in five overlap-save chunks (128-frame job, 16 frames of halo, Direct mode on the decoder voice
   base's K/M);
4. the depth-first generator on the DSP (kept settings, on the generator voice base), on a second handle of the same
   FastRPC session.

The job inputs are packed on the phone by the functions the host renderer uses (`tools/Kokoro.CaptureKernels.psm1`:
`ConvertTo-KokoroDecoderInput`, `Invoke-KokoroDecoderChunks`, `ConvertTo-KokoroGeneratorInput`,
`ConvertFrom-KokoroPcm16`); against the renderer's previous inline packing they give identical bytes for 2, 57, 96 and
128 frames and identical stitched x for a 471-frame stream.

The host supplies what the phone does not build: the front end's compiled kernels, the decoder library, the generator
library for this text's length (942 ticks), and their tables and weights.

Text: "When the evening came, the old keeper climbed the narrow stairs of the lighthouse, lit the great lamp, and
watched the ships pass slowly along the dark and quiet coast until the morning light returned." 193 phonemes,
471 decoder frames, 11.775 s of audio. Voice `af_heart`.

## Time on the phone

Loading the phonemizer and the front end took 1,835 ms. Each run times the whole path from text to PCM; stage times
include the packing done on the CPU:

| Run | Phonemizer | Front end | Decoder (DSP) | Generator (DSP) | Total |
| --- | ---: | ---: | ---: | ---: | ---: |
| 0, first | 36.1 ms | 8,506.5 ms | 206.0 ms (24.88) | 488.1 ms (286.81) | 9,245.6 ms |
| 1 | 0.6 ms | 4,851.9 ms | 96.8 ms (25.02) | 421.7 ms (291.02) | 5,375.9 ms |
| 2 | 0.6 ms | 4,915.3 ms | 85.5 ms (24.95) | 421.6 ms (288.78) | 5,425.7 ms |

Warm, 11.775 s of speech takes about 5.4 s from text to PCM, 2.2 times faster than real time; the front end is about
90 % of it. Outside the DSP region the decoder spends about 60 to 72 ms on its chunks and the generator about 130 ms
(input packing, the FastRPC call and the PCM conversion). All three runs gave the same PCM, and the WAV played through
AAudio (282,600 frames, no underruns).

## Output against the host

The same text through the host front end and the speech renderer on the resident listener (same libraries, tables,
weights, voice bases and seed) is the reference. Phonemes, durations, F0 and N are identical on the phone
(`frontend-phone-cpu-sm8550-20261027.md`); the text encoding differs. `CompareAudio` of the phone's WAV against the
reference:

| Measure | Value |
| --- | ---: |
| Waveform SNR | 57.47 dB |
| Magnitude SNR (mean of three resolutions) | 61.61 dB |
| Log-spectral distance | 0.019 dB |
| Mel-cepstral distortion | 0.043 dB |
| f0 difference (RMS) | 0 cents |
| Voicing agreement | 100 % |
| Loudness envelope correlation | 0.9999999 |

The DSP stages on the reference took 24.93 ms (decoder) and 288.29 ms (generator).

## Limits

- The generator library is emitted on the host for this text's tick count; the phone does not emit. A generator that
  takes its span count at run time removes this.
- Not streaming: the whole front end runs before the decoder, and the whole decode before the generator. The decoder is
  not depth-first; its chunks recompute 16 frames of context on each side.
- Both normalizations are voice bases, not the utterance's own moments (`stock-end-to-end-sm8550-20261027.md`).

Receipt: `build/phone-speech-20261028T015310` (phone-speech.clixml, reference.wav, pack/, compare/); the phone's WAV is
beside the generator emission (`speech-SM8550-*.wav`).
