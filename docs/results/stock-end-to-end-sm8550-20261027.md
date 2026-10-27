# Text to WAV through the stock pipeline, SM8550 (2026-10-27)

Kokoro-Hexagon `e20faff`. One sentence from text to a WAV file: our compiled phonemizer driver, the host port of the
stock front end (`tools/Invoke-KokoroPrecomputedDecoder.ps1`: ALBERT, `bert_encoder`, the predictor and the text
encoder; `Invoke-OfflineSpeech -SkipDecoder`), then the decoder and the generator on the DSP through the speech renderer
(`New-KokoroSpeechRenderer`; generator with the kept depth-first settings). Voice `af_heart`.

Text: "The quick brown fox jumps over the dog." 45 phoneme tokens, 114 decoder frames, 2.85 s of audio.

| Stage | Time | Where it ran |
| --- | ---: | --- |
| Phonemizer, warm | 3.0 ms | host PC (67.9 ms cold) |
| Front end, warm | 2,528 ms | host PC (7,332 ms cold) |
| Decoder | 15.8 ms | DSP, moments accumulated in the job |
| Generator | 72.2 ms | DSP: 25.3 ms per audio second, 39.5 times real time |

The DSP stages take 88.0 ms for 2.85 s of audio (32.4 times real time). The phonemizer on the phone is recorded at a
39.2 us warm median per sentence (`phonemizer-driver-sm8550-20261008.md`); the front end has not run on the phone.

## Limits found

- The decoder job holds its whole input in VTCM. Its capacity is 128 frames (3.2 s, VTCM 7,962,624 B); at 192 frames
  and above the high-plane input window and its read extent exceed one 2 MiB VTCM page. The first sentence tried
  (130 frames) was refused.
- The generator's AdaIN constants come from an export run of the layer job over the whole utterance. At 228 ticks
  (2.85 s) that layout does not fit ("ups[1] input planes cross a 4 MiB VTCM boundary"). This run used the cached voice
  base instead (the mean of exported constants over training stretches,
  `build/student/voice/af_heart/adain-base-*.bin`), so its PCM is not compared with stock here.
- The depth-first generator itself rendered the 2.85 s utterance (library `3DD74F61...`).

Receipt: `build/stock-end-to-end-20261027T180338` (stock-end-to-end.clixml, speech.wav).
