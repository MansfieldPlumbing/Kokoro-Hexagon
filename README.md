# Kokoro-Hexagon

Kokoro-82M speech synthesis running on the Hexagon DSP of a Snapdragon phone, with
every DSP instruction emitted by PowerShell. PowerShell reads the checkpoint, packs
the weights, and writes the HMX/HVX machine code and ELF itself. No C or C++, LLVM,
QNN or ONNX Runtime is involved in the product path.

## Measured on SM8550, October 12, 2026

**"I can eat a peach for hours." 2.125 seconds of speech, 51,000 samples at 24 kHz**

| Measurement | Result |
|---|---:|
| Decoder + harmonic source + generator, one DSP dispatch | **113.6 ms** |
| DSP synthesis speed | **18.7× real time** |
| PCM SNR against stock Kokoro (float) | 31.3 dB |
| Clipped samples | 0 |

Median of three warm runs on one FastRPC handle; the output was played through the
phone speaker with AAudio. Inputs are captured decoder inputs for the sentence, so
text processing is not included. The ratchet case `decoder-generator-bank-input-sm8550`
runs this job on the phone and accepts only this PCM (SHA-256 `E6456751…74054`).

## How it works

```text
Text → custom CoreCLR phonemizer (ARM) → typed phonemes and prosody
     → Hexagon: [decoder] → harmonic source + generator → PCM → AAudio
```

- **Emission.** PowerShell job builders describe each DSP job as an instruction
  stream. Our encoder, lowered to IL through PSLowering, encodes the complete
  decoder-and-generator library.
- **Arithmetic.** Integer kernels throughout: 16-bit activations carried as two
  int8 planes, W8 weights, per-channel scales. HMX runs the convolutions; HVX runs
  AdaIN, Snake, the harmonic source and the transforms, using up to four hardware
  threads.
- **Front end.** A custom phonemizer running on CoreCLR replaces Kokoro's front
  end: 57.8 µs per sentence on the phone, 96.6 µs on held-out sentences.
- **Decoder.** The architecture runs with or without it, ahead of the generator.

## Status

| | |
|---|---|
| DSP synthesis, decoder through PCM | Measured on SM8550 |
| Custom CoreCLR phonemizer front end, on the phone | Measured |
| Fixed normalization constants instead of runtime AdaIN statistics | Experimental: 99.6 ms, below the quality floor |
| Student supplying the generator's inputs and AdaIN coefficients | Rebuilding: resumable corpus, replayable typed normalization and carried grammar state; acoustic learning pending |
| Streaming at any length (time-major schedule) | Next |
| Time to first audio, end to end | Not yet measured |
| SM8635 | Not yet run |

## Development

PowerShell 7.7.0-preview.5, the version CI pins:

```powershell
pwsh -NoProfile -File ./Invoke-KokoroDevelopment.ps1
pwsh -NoProfile -File ./Invoke-KokoroDevelopment.ps1 Verify
```

The default command reports repository state and available commands without
touching a phone. `Verify` runs the same checks as CI. Dependencies are pinned by
hash; generated artifacts stay under the ignored `build/` directory. Phone commands
run only against an attached, authorized device, and results from different phone
models are kept separate.

Machine-specific locations come from environment variables: `KOKORO_ADB` (or `adb`
on `PATH`) for phone commands, `KOKORO_PYTHON` for stock reference captures,
`KOKORO_STOCK_SOURCE` for the pinned Kokoro source, and `HEXAGON_SDK_TOOLS` for the
optional assembler check.

## Layout

Each subsystem is one file of declared records and steps, reached through
`Invoke-KokoroDevelopment.ps1`:

| File | Subsystem |
|---|---|
| `Invoke-HexagonDevelopment.ps1` | Hexagon instruction records, encoder, kernels and emission |
| `student/Invoke-Student.ps1` | The Student: text corpus, pronunciations, syllabus and training |
| `phonemizer/Invoke-EnglishPhonemizer.ps1` | The English phonemizer and its compiled driver |
| `tools/Invoke-KokoroPrecomputedDecoder.ps1` | The lowered host port of stock Kokoro used as the syllabus |

Kernels and jobs under `src/` are being folded into the Hexagon file.

## Published comparisons

Checked October 10, 2026. Speed is audio duration divided by synthesis time. Each
row keeps its published device and timing scope; these are reference points, not a
matched ranking.

| Build | Device | Timed scope | Speed |
|---|---|---|---:|
| Kokoro-Hexagon | SM8550 | Decoder, harmonic source and generator; DSP only; 2.125 s audio | **18.7×** |
| [laishere/kokoro-coreml](https://github.com/laishere/kokoro-coreml#ios), comparison `484907d` | iPhone 16 Pro | Warm phonemes-to-PCM chain; six passages; G2P and load excluded | 16.9× mean |
| [Soniqo speech-swift](https://github.com/soniqo/speech-swift/blob/main/docs/benchmarks/ios-coreml.md) | iPhone 16 Pro | Core ML Kokoro, warm release benchmark | 12.5× |
| [kokoro-offline-tts-android](https://github.com/cedgeremek/kokoro-offline-tts-android#real-device-demo) | S24 Ultra / SM8650 | QNN HTP generator; separately reports 306 ms warm request-to-first-audio | 3.78× |

The kokoro-coreml figures cover phonemes to PCM, including the text encoder and
predictors; ours do not yet.

## Provenance

Kokoro-82M is developed by hexgrad and released under the Apache-2.0 license.
PowerShell and .NET are developed by Microsoft and released under the MIT license.
We acknowledge both with respect; this project is not affiliated with or endorsed
by either.

This repository contains no Kokoro weights, voices or model-derived data. Model
inputs come from the upstream Kokoro release, pinned by hash; everything generated
from them stays in the ignored `build/` directory and is not distributed.

All code in this repository, including the Hexagon instruction encoder, the DSP
kernels, the phonemizer and the text front end, is written independently in
PowerShell. It does not copy, translate or port code from other Kokoro
implementations.
