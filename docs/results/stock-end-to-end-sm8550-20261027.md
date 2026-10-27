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
keeps the loudness contour but changes spectral detail and phase well beyond seed-to-seed variation. With supplied
coefficients the waveform is not expected to match the matched render; the comparison is spectral distance against
the seed-to-seed yardstick, on more varied material than this one sentence.

Receipt: `build/voice-base-vs-matched-20261027T183928` (matched.wav, matched-seed2.wav, voice-base.wav).

## Any length: decoder by overlap-save, both on voice bases

The speech renderer's `Decode` now takes a decoder constants table: the stream decodes in chunks whose interiors are a
multiple of 16 frames (whole 32-tick output tiles), each with 16 frames of halo per side, in the decoder job's Constants
mode. Without a table it runs the one accumulating job as before. `DecoderConstants` exports a 128-frame stretch as a
constants table (`New-KokoroDecoderConstantsTables`, which checks every exported K and M against its exact terms);
`DecoderVoiceBase` averages such exports as `VoiceBase` does for the generator. The decoder voice base here is the mean of
six exports from paragraphs of `build/grammar-corpus/raw/pg14006.txt` taken at a fixed stride.

**Stitching.** "The quick brown fox jumps over the dog." (114 frames) decoded with the same table at interiors of 96, 48
and 32 frames (2, 3 and 4 chunks): identical x in all three (`EC352C59...`). With supplied constants the chunk boundaries
do not reach the output.

**An 11.775 s sentence** (471 frames), decoder and generator each on its voice base, one pass on the DSP:

| Stage | DSP | Per audio second |
| --- | ---: | ---: |
| Decoder, 5 chunks | 60.8 ms | 5.2 ms |
| Generator (depth-first, kept settings) | 289.6 ms | 24.6 ms (40.7 times real time) |
| Total | 350.4 ms | 29.8 ms (33.6 times real time) |

A decoder chunk takes about 12 ms, most of it deriving coefficients from the table on the DSP (as in
`decoder-direct-coefficients-sm8550-20261010.md`, where direct coefficients took a chunk from 13.4 to 2.9 ms).

Receipt: `build/streaming-decoder-20261027T185820` (streaming-decoder.clixml, decoder-base.bin, passage.wav).

**K/M from the host.** The decoder's Constants mode and the generator's run the same coefficient kernel
(`New-KokoroAdaInConstantCoefficientsLoopSteps`, flat K/M/S for the generator, K/M blocked per 32 channels for the
decoder). `Get-KokoroConstantCoefficient` reproduces its per-channel arithmetic for both
(`ConvertTo-KokoroGeneratorStageCoefficients`, `ConvertTo-KokoroDecoderCoefficients`), and `Decode` now computes the
decoder's K/M once per table and runs its chunks in Direct mode. Same voice base, same chunks:

| Input | Constants mode | Direct mode | x |
| --- | ---: | ---: | --- |
| 114 frames, 2 chunks | 22.26 ms | 7.89 ms | identical (`EC352C59...`) |
| 471 frames (11.775 s), 5 chunks | 60.79 ms | 24.96 ms | identical |

The decoder takes 2.1 ms per audio second; with the generator's 289.6 ms the 11.775 s sentence needs about 314.6 ms on
the DSP (26.7 ms per audio second, 37.4 times real time).

Receipt: `build/decoder-direct-*` (decoder-direct.clixml).
