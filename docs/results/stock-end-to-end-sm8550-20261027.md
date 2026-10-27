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

## Utterance moments and length

The generator's export and the decoder both normalize with moments over the whole utterance. Measured sources for those
moments when an utterance is longer than one job:

**Decoder chunks, host port** (11.775 s sentence, 471 frames; each chunk with 16 frames of halo per side, scored over
its interior against one whole decode; `Invoke-OfflineDecoder`, live and supplied level modes):

| Chunk | Chunks | Own moments | Worst chunk | Two passes, composed moments | Exact moments supplied |
| --- | ---: | ---: | ---: | ---: | ---: |
| 32 frames | 15 | 8.02 dB | 3.92 dB | -0.96 dB | |
| 64 frames | 8 | 9.27 dB | 3.92 dB | -0.72 dB | |
| 128 frames | 4 | 12.56 dB | 9.05 dB | 6.60 dB | bit-exact |

"Composed" sums each site's interior statistics from a first pass of chunks with their own moments and supplies the
result to a second pass; the composed moments are 21 to 25 dB from the exact ones. With exact moments supplied, chunks
reproduce the whole decode bit for bit (the harness control).

**Generator, DSP** ("The dog naps in the sun.", first 130 ticks, 1.625 s; same x, f0 and seed): the voice base against
this stream's own exported constants gives -2.43 dB PCM SNR, with 1.29 dB more level (generator 41.7 against 41.1 ms).

**Export length.** The export (layer job, whole length in VTCM) runs at 130 ticks; at 166 and 180 ticks it emits but
fails on the device (`Stage=2 Done=0`), and at 228 ticks its layout does not fit.

Chunk-local, composed and voice-base moments are each far from the exact normalization. Exact moments at any length
need a pass that walks each layer over the whole utterance (the layer schedule), with activations outside VTCM.

Receipts: `build/decoder-chunk-moments-*`, `build/decoder-composed-moments-*`, `build/voice-base-vs-matched-*`.

## Voice base against matched, by spectrum

Same sentence and 130 ticks, rendered on the DSP with the stream's own constants (seed 1 and seed 2) and with the voice
base (seed 1). Hann window 1,024, hop 256, 149 frames; each column against the matched render with seed 1:

| Measure | Matched, seed 2 | Voice base |
| --- | ---: | ---: |
| Waveform SNR | 16.93 dB | -2.43 dB |
| STFT magnitude SNR | 23.78 dB | 5.82 dB |
| Log-spectral distance | 3.33 dB | 8.81 dB |
| Phase agreement (energy-weighted mean cosine) | 0.965 | 0.39 |
| Frame energy envelope correlation | 1.000 | 0.958 |

A second seed (a different noise and harmonic start draw, the same by construction) is the yardstick: the voice base
keeps the loudness contour but changes spectral detail and phase well beyond seed-to-seed variation. In a listening
comparison of the two renders no difference was heard. Waveform SNR against the matched render does not describe that
result; with supplied coefficients the comparison is spectral distance against the seed-to-seed yardstick, plus
listening on more varied material.

Receipt: `build/voice-base-vs-matched-20261027T183928` (matched.wav, matched-seed2.wav, voice-base.wav).
