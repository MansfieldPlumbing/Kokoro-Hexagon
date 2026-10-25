# Kokoro-Hexagon

Text to speech on the Hexagon DSP of a Snapdragon phone, built on Kokoro-82M's frozen generator, with every DSP
instruction emitted by PowerShell. PowerShell reads the checkpoint, packs the weights, and writes the HMX and HVX
machine code and the ELF itself. No C or C++, LLVM, QNN or ONNX Runtime is involved in the product path.

## Design

```text
Text → phonemizer (CoreCLR, phone CPU) → Student (phone CPU) → x, F0 and AdaIN coefficients
     → Hexagon: harmonic source → generator, depth-first in spans → PCM → AAudio
```

- **The Student** replaces everything in Kokoro up to and including the decoder. It produces the generator's inputs:
  `x` (512 channels per generator tick), F0, and every AdaIN site's coefficients from a controller stream. Kokoro's
  front end, predictors and decoder do not run. The Student is a procedural learning system of typed objects, not a
  neural network ([student/AGENTS.md](student/AGENTS.md)).
- **The generator** runs depth-first: each 32-frame tile passes through all of a section's stages while it stays in
  VTCM.
  - The 256-channel section streams its weights per stage over a block of tiles.
  - The 128-channel section keeps its weights resident and runs one tile per HVX thread.
  - Each section's front (LeakyReLU, transposed convolution, the add of the source) feeds its first stage.
  - The tail ends in an inverse STFT to PCM.
- **The source** (harmonic source, STFT, `noise_convs`, `noise_res`) runs on the DSP from F0 and seeded noise. Each
  `noise_res` is a depth-first section of its own.
- **Spans.** The job runs in spans; each span runs every stage over the tiles its upstream stage has finished.
  Whole-length tensors stay in DDR, and each section's VTCM state is saved between spans. VTCM therefore does not
  grow with the length of the input. Uniform middle spans run as one loop, so the code size does not either.
- **Arithmetic.** Integer kernels throughout: 16-bit activations carried as two byte planes, int8 weights with
  per-channel scales. HMX runs the convolutions; HVX runs AdaIN, Snake, the source and the transforms, on four
  hardware threads.

Every schedule change is proved against the layer-by-layer generator, which stays in the repository as the
reference: given the same integer weights and inputs, the depth-first job must produce byte-identical PCM.

## Measured on SM8550

| Measurement | Result | Record |
|---|---:|---|
| Generator with its source on the DSP, from x and F0 to PCM, 1.625 s of speech | **61.75 ms, 26.3× real time**; PCM byte-identical to the layer reference | [source on the DSP](../Pwsh-Development/docs/kokoro-hexagon/results/generator-source-on-dsp-sm8550-20261024.md) |
| The same job's source part (harmonic source, STFT, `noise_convs`, `noise_res`) | about 23.2 ms of the 61.75 ms | same |
| Generator sections and tail with the source supplied, 24.4 s of speech in 31 spans | 438.13 ms, 1.11 MB library, 7.6 MB VTCM | [span loop](../Pwsh-Development/docs/kokoro-hexagon/results/generator-span-loop-sm8550-20261023.md) |
| Stock decoder, harmonic source and generator, layer by layer, one dispatch, 2.125 s of speech | 113.6 ms, 18.7× real time | [phase-major pool](../Pwsh-Development/docs/kokoro-hexagon/results/generator16-phase-major-pool-sm8550-20261012.md) |
| Phonemizer on the phone, warm median per sentence | 57.8 µs (challenge set), 96.6 µs (held out) | [phonemizer](../Pwsh-Development/docs/kokoro-hexagon/results/phonemizer-polish-sm8550-20261008.md) |

Times are DSP times of warm runs. The generator rows take the generator's inputs from captured stock Kokoro runs, so
text processing and the Student are not included.

## Status

| | |
|---|---|
| Depth-first generator, both sections, joints, tail, any length up to 1,048,576 frames (source supplied) | Measured; byte-identical to the layer reference |
| Source branches on the DSP, connected to the depth-first generator | Measured; byte-identical; limited to about 2 s because the harmonic source and the `har` layouts still run over the whole input |
| A source without `noise_convs` and `noise_res` (gain and offset on the upsampled signal) | Measured and rejected: about 0 dB PCM SNR against the layer reference ([record](../Pwsh-Development/docs/kokoro-hexagon/results/generator-source-boundary-sm8550-20261024.md)) |
| The harmonic source in spans; weight DMA overlapped with computation; the 128-channel source on the resident schedule | Next |
| Student producing x, F0 and the controller stream from unseen text | In progress |
| Phonemizer, Student and generator together on the phone, streaming PCM to AAudio | Not yet built |
| Time to first audio, end to end | Not yet measured |
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
compares them section by section and in PCM. Its joints are:

| Joint | Scope |
|---|---|
| `Section` | One section |
| `Front` | The 256-channel front and section |
| `Whole` | The whole generator with supplied sources |
| `WholeSource` | The whole generator with its source on the DSP |
| `Spans` | Long input, compared across span sizes |

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
| `Invoke-HexagonDevelopment.ps1` | Hexagon instruction records, encoder, kernels and emission |
| `src/jobs/Kokoro.Generator60x16Run.ps1` | The generator job: layer reference, depth-first schedules, spans, fronts, source sections |
| `student/Invoke-Student.ps1` | The Student: text corpus, pronunciations, syllabus and training |
| `phonemizer/Invoke-EnglishPhonemizer.ps1` | The English phonemizer and its compiled driver |
| `tools/Invoke-KokoroPrecomputedDecoder.ps1` | The lowered host port of stock Kokoro used as the syllabus |

Kernels and jobs under `src/` are being folded into the Hexagon file. Result records are kept outside the repository,
under [`../Pwsh-Development/docs/kokoro-hexagon`](../Pwsh-Development/docs/kokoro-hexagon).

## Published comparisons

Speed is audio duration divided by synthesis time. Each row keeps its published device and timing scope; these are
reference points, not a matched ranking. The other projects' figures were checked on October 10, 2026.

| Build | Device | Timed scope | Speed |
|---|---|---|---:|
| Kokoro-Hexagon, depth-first ([record](../Pwsh-Development/docs/kokoro-hexagon/results/generator-source-on-dsp-sm8550-20261024.md)) | SM8550 | Harmonic source and generator from x and F0; DSP only; 1.625 s audio | **26.3×** |
| Kokoro-Hexagon, layer by layer ([record](../Pwsh-Development/docs/kokoro-hexagon/results/generator16-phase-major-pool-sm8550-20261012.md)) | SM8550 | Stock decoder, harmonic source and generator; DSP only; 2.125 s audio | 18.7× |
| [laishere/kokoro-coreml](https://github.com/laishere/kokoro-coreml#ios), comparison `484907d` | iPhone 16 Pro | Warm phonemes-to-PCM chain; six passages; G2P and load excluded | 16.9× mean |
| [Soniqo speech-swift](https://github.com/soniqo/speech-swift/blob/main/docs/benchmarks/ios-coreml.md) | iPhone 16 Pro | Core ML Kokoro, warm release benchmark | 12.5× |
| [kokoro-offline-tts-android](https://github.com/cedgeremek/kokoro-offline-tts-android#real-device-demo) | S24 Ultra / SM8650 | QNN HTP generator; separately reports 306 ms warm request-to-first-audio | 3.78× |

The kokoro-coreml figures cover phonemes to PCM, including the text encoder and predictors. Ours cover the generator
only: in this design the Student replaces Kokoro's text encoder, predictors and decoder, and it is not yet timed.

## Provenance

Kokoro-82M is developed by hexgrad and released under the Apache-2.0 license. PowerShell and .NET are developed by
Microsoft and released under the MIT license. We acknowledge both with respect; this project is not affiliated with
or endorsed by either.

This repository contains no Kokoro weights, voices or model-derived data. Model inputs come from the upstream Kokoro
release, pinned by hash; everything generated from them stays in the ignored `build/` directory and is not distributed.

All code in this repository, including the Hexagon instruction encoder, the DSP kernels, the phonemizer and the text
front end, is written independently in PowerShell. It does not copy, translate or port code from other Kokoro
implementations.
