# Kokoro-Hexagon

Text to speech on the Hexagon DSP of a Snapdragon phone, built on Kokoro-82M's frozen decoder and generator, with every
DSP instruction emitted by PowerShell. PowerShell reads the checkpoint, packs the weights, and writes the HMX and HVX
machine code and the ELF itself. No C or C++, LLVM, QNN or ONNX Runtime is involved in the product path.

## Design

```text
Text → phonemizer (CoreCLR) → front end: phonemes, durations, F0 and N → Kokoro's text encoder → aligned encoding
     → Hexagon: decoder → x → harmonic source → generator, depth-first in spans → PCM
```

- **Front end.** Two producers of the low-rate controls (each phoneme's duration, and F0 and energy N on the generator's
  80-per-second tick clock):
  - the lowered port of stock Kokoro's front end (ALBERT, `bert_encoder`, the predictor and the text encoder), compiled
    from PowerShell to IL and run on CoreCLR ([`tools/Invoke-KokoroPrecomputedDecoder.ps1`](tools/Invoke-KokoroPrecomputedDecoder.ps1));
  - the Student, a procedural learning system of typed objects that replaces PL-BERT, `bert_encoder` and the predictor
    ([student/AGENTS.md](student/AGENTS.md)).
- **Decoder** on the DSP. With a supplied normalization table it decodes any length by overlap-save: chunks of at most
  128 frames with 16 frames of context on each side, joined on whole output tiles. Its AdaIN coefficients are computed
  once on the host from the table.
- **Generator** on the DSP, depth-first in spans (below), with its source branch (harmonic source, STFT, `noise_convs`,
  `noise_res`) computed on the DSP from F0 and seeded noise.
- **Normalization.** Stock Kokoro normalizes every AdaIN site with moments over the whole utterance, which ties each
  output sample to the end of the utterance. Here the coefficients are supplied: a voice base per site (the mean of
  exported moments over training stretches), so neither the decoder nor the generator has a whole-utterance dependency.
- **Arithmetic.** Integer kernels throughout: 16-bit activations carried as two byte planes, int8 weights with
  per-channel scales. HMX runs the convolutions; HVX runs AdaIN, Snake, the source and the transforms, on four hardware
  threads.

### Depth-first execution

A conventional generator runs layer by layer: each layer reads the whole utterance's activations and writes them back
before the next starts, so memory traffic and working memory grow with the length of the speech.

Here the generator runs depth-first. Time is cut into 32-frame tiles, and each tile passes through all of a section's
stages while its data stays in VTCM, the DSP's 8 MiB local memory:

- Every convolution reads only rows at or before its output; its left context lives in small rings that carry from one
  tile to the next. In each residual pair the first convolution taps its reach late and the second the remainder, so a
  pair's output emerges exactly one tile behind its input.
- The 128-channel section and both source sections keep their weights resident and run one tile per HVX thread, the four
  threads staggered one stage apart around the matrix unit. The 256-channel section streams its weights per stage over
  a block of tiles, the next stage's transfers queued behind the current stage's convolutions.
- The job runs in spans of 60 tiles. Each span advances every stage over the tiles its upstream stage has finished and
  saves each section's VTCM state for the next span, so VTCM does not depend on the length of the input. A span is an
  execution boundary only: the output is the same at any span size.

Every schedule change is proved against the layer-by-layer generator, which stays in the repository as the reference:
given the same integer weights and inputs, the depth-first job must produce byte-identical PCM. Changes to the
synthesis itself (the supplied normalization) are judged by listening and by spectral measures, not by waveform
agreement with stock Kokoro.

## Measured on SM8550

| Measurement | Result | Record |
|---|---:|---|
| Generator with its source on the DSP, from x and F0 to PCM, 1.625 s of speech | **39.65 ms, 41.0× real time**; PCM byte-identical to the layer reference | [source on the DSP](docs/results/generator-source-on-dsp-sm8550-20261024.md) |
| The same job on 2026-10-27 before this day's changes (host coefficients, resident sources, 60-tile spans, queued weights, packed fill and combines) | 62.58 ms, 26.0× | same |
| DMA per run for that job, by the emitted ledger | 135.9 MB at 60-tile spans, from 226.4 MB at 20-tile spans | same |
| Decoder and generator on voice-base normalization, 11.775 s of speech in one pass | 314.6 ms on the DSP (decoder 24.96 ms, generator 289.6 ms), 37.4× real time | [stock pipeline](docs/results/stock-end-to-end-sm8550-20261027.md) |
| Text to WAV, our phonemizer and the host front end, then decoder and generator on the DSP, 2.85 s of speech | DSP 88.0 ms; host front end 2,528 ms warm on the development PC | same |
| Phonemizer on the phone, warm median per sentence | 57.8 µs (challenge set), 96.6 µs (held out) | [phonemizer](docs/results/phonemizer-polish-sm8550-20261008.md) |

Times are DSP times of warm runs unless stated. The generator rows take x and F0 from a captured stock Kokoro run.
The 11.775 s row's normalization is the voice base; its waveform is not compared with stock (see the record for the
spectral comparison and why).

## Status

| | |
|---|---|
| Depth-first generator with its source on the DSP; kept settings are the defaults, with VTCM fallbacks | Measured; byte-identical to the layer reference |
| Decoder and generator at any length with supplied normalization | Measured (11.775 s in one pass); decoder chunks byte-identical across chunk sizes |
| Supplied (voice-base) normalization against each utterance's own | Measured: loudness envelope correlation 0.958; log-spectral distance 8.81 dB against 3.33 dB between two seeds of the same render ([record](docs/results/stock-end-to-end-sm8550-20261027.md)) |
| DDR workspace bounded by the span (tensors held as rings, not whole length) | Next |
| The span loop with resident source sections (code size independent of length) | Next |
| Front end on the phone's CPU | In progress: the port's SIMD workers need the portable vector API, which needs a PSLowering update |
| Student producing durations, F0 and N from unseen text | In progress ([stage 1](docs/results/student-stage1-audition-sm8550-20261025.md)) |
| Streaming PCM while later text is still being processed; time to first audio | Not yet built or measured |
| SM8635 | Not yet run |

## Development

PowerShell 7.7.0-preview.5, the version CI pins:

```powershell
pwsh -NoProfile -File ./Invoke-KokoroDevelopment.ps1
pwsh -NoProfile -File ./Invoke-KokoroDevelopment.ps1 Verify
pwsh -NoProfile -Command "& ./Invoke-KokoroDevelopment.ps1 Run -Case generator-tile-equivalence -Parameters @{Joint='WholeSource'}"
```

The default command reports repository state and available commands without touching a phone. `Verify` runs the
same checks as CI. `generator-tile-equivalence` runs a depth-first job and its layer reference on the phone and
compares them section by section and in PCM; with no options it uses the kept depth-first settings
(`Invoke-KokoroGeneratorDepthFirstEmission`). Its joints are:

| Joint | Scope |
|---|---|
| `Section` | One section |
| `Front` | The 256-channel front and section |
| `Whole` | The whole generator with supplied sources |
| `WholeSource` | The whole generator with its source on the DSP |
| `Spans` | Long input, compared across span sizes |

The speech renderer (`New-KokoroSpeechRenderer`) runs the decoder and generator on the phone from an aligned encoding,
F0 and N, with exported or voice-base normalization.

Dependencies are pinned by hash; generated artifacts stay under the ignored `build/` directory. Phone commands run
only against an attached, authorized device, and results from different phone models are kept separate.

Machine-specific locations come from environment variables:

| Variable | Used for |
|---|---|
| `KOKORO_ADB` (or `adb` on `PATH`) | Phone commands |
| `KOKORO_PYTHON` | Stock reference captures |
| `KOKORO_STOCK_SOURCE` | The pinned Kokoro source |
| `HEXAGON_SDK_TOOLS` | The optional assembler check |

## Layout

Each subsystem is one file of declared records and steps, reached through `Invoke-KokoroDevelopment.ps1`:

| File | Subsystem |
|---|---|
| `Invoke-HexagonDevelopment.ps1` | Hexagon instruction records, encoder, packet grouping, kernels and emission |
| `src/jobs/Kokoro.Generator60x16Run.ps1` | The generator job: layer reference, depth-first schedules, spans, fronts, source sections, DMA ledger |
| `src/jobs/Kokoro.DecoderRun16.ps1` | The decoder job and its normalization modes |
| `Invoke-KokoroDevelopment.ps1` | Commands, phone runs, the speech renderer and the depth-first defaults |
| `student/Invoke-Student.ps1` | The Student: text corpus, pronunciations, syllabus and training |
| `phonemizer/Invoke-EnglishPhonemizer.ps1` | The English phonemizer and its compiled driver |
| `tools/Invoke-KokoroPrecomputedDecoder.ps1` | The lowered host port of stock Kokoro: front end, decoder and generator reference |

Kernels and jobs under `src/` are being folded into the Hexagon file. Result records, one per measurement, are in
[`docs/results`](docs/results).

## Published comparisons

Speed is audio duration divided by synthesis time. Each row keeps its published device and timing scope; these are
reference points, not a matched ranking. The other projects' figures were checked on October 10, 2026.

| Build | Device | Timed scope | Speed |
|---|---|---|---:|
| Kokoro-Hexagon, depth-first ([record](docs/results/generator-source-on-dsp-sm8550-20261024.md)) | SM8550 | Harmonic source and generator from x and F0; DSP only; 1.625 s audio | **41.0×** |
| Kokoro-Hexagon, decoder and generator ([record](docs/results/stock-end-to-end-sm8550-20261027.md)) | SM8550 | Decoder, harmonic source and generator from the aligned encoding, F0 and N; voice-base normalization; DSP only; 11.775 s audio | 37.4× |
| [laishere/kokoro-coreml](https://github.com/laishere/kokoro-coreml#ios), comparison `484907d` | iPhone 16 Pro | Warm phonemes-to-PCM chain; six passages; G2P and load excluded | 16.9× mean |
| [Soniqo speech-swift](https://github.com/soniqo/speech-swift/blob/main/docs/benchmarks/ios-coreml.md) | iPhone 16 Pro | Core ML Kokoro, warm release benchmark | 12.5× |
| [kokoro-offline-tts-android](https://github.com/cedgeremek/kokoro-offline-tts-android#real-device-demo) | S24 Ultra / SM8650 | QNN HTP generator; separately reports 306 ms warm request-to-first-audio | 3.78× |

The kokoro-coreml figures cover phonemes to PCM, including the text encoder and predictors. Ours cover the DSP stages
only: the front end (stock port or Student) is not yet timed on the phone.

## Provenance

This repository's code is released under the Apache-2.0 license (`LICENSE`, `NOTICE`). Kokoro-82M is developed by
hexgrad and released under the Apache-2.0 license. PowerShell and .NET are developed by Microsoft and released under the
MIT license. We acknowledge both with respect; this project is not affiliated with or endorsed by either.

This repository contains no Kokoro weights, voices or model-derived data. Model inputs come from the upstream Kokoro
release, pinned by hash; everything generated from them stays in the ignored `build/` directory and is not distributed.

All code in this repository, including the Hexagon instruction encoder, the DSP kernels, the phonemizer and the text
front end, is written independently in PowerShell. It does not copy, translate or port code from other Kokoro
implementations.
