# Kokoro-Hexagon

Kokoro-82M speech synthesis running on the Hexagon DSP of a Snapdragon phone, with
every DSP instruction emitted by PowerShell. PowerShell reads the checkpoint, packs
the weights, and writes the HMX/HVX machine code and ELF itself. No C or C++, LLVM,
QNN or ONNX Runtime is involved in the product path.

## Measured on SM8550 (Galaxy S23), October 12, 2026

**"I can eat a peach for hours." 2.125 seconds of speech, 51,000 samples at 24 kHz**

| Measurement | Result |
|---|---:|
| Decoder + harmonic source + generator, one DSP dispatch | **99.593 ms** |
| DSP synthesis speed | **21.3× real time** |
| Host invoke including dispatch, warm | 138.739 ms (15.3×) |
| Runtime AdaIN statistics | **none** |
| Clipped samples, playback xruns | 0, 0 |

Medians of five warm runs on one FastRPC handle; the speech was played through
the phone speaker with AAudio. Inputs are captured decoder inputs for the sentence,
so text processing is not included. Implementation `8dd428b`, receipt `541aa1e`.

## Synthesis without runtime normalization statistics

Kokoro's decoder and generator normalize activations with AdaIN at 58 sites, which
ordinarily measures each utterance's mean and variance at run time. That
measurement makes every stage wait for the whole utterance before it can continue.

We replaced it with fixed per-channel constants computed offline from a seven-
utterance corpus, with no retraining. The sentence above was excluded from the
corpus.

| Variant | DSP time | Listening |
|---|---:|---|
| Stock statistics, our DSP path | 113.6 ms | Close to the float reference (31.3 dB PCM SNR) |
| Constants in the generator only | — | Clear; output level about 7 dB lower |
| **Constants in decoder and generator** | **99.6 ms** | Intelligible; nasal, congested quality |
| Decoder normalization removed (control) | — | Unintelligible |

The generator, which carries most of the computation, tolerates fixed constants
almost transparently. The remaining degradation sits in the ten decoder sites; those
are where the front end's control streams will act. Without per-utterance
statistics, every remaining operation is local in time, which is the basis for
streaming synthesis at any text length.

## How it works

```text
Text → custom CoreCLR phonemizer (ARM) → typed phonemes and prosody
     → Hexagon: [decoder] → harmonic source + generator → PCM → AAudio
```

The architecture is flexible: it runs with or without the decoder. The front end
has been replaced by a custom phonemizer that runs on CoreCLR.

- **Emission.** PowerShell job builders describe each DSP job as an instruction
  stream. Our encoder, lowered to IL through PSLowering, encodes the complete
  3.7 MB decoder-and-generator library in 6.2 seconds.
- **Arithmetic.** Integer kernels throughout: 16-bit activations carried as two
  int8 planes, W8 weights, per-channel scales. HMX runs the convolutions; HVX runs
  AdaIN, Snake, the harmonic source and the transforms, using up to four hardware
  threads.
- **Front end.** A custom phonemizer running on CoreCLR replaces Kokoro's front
  end. Compiled, it runs in 57.8 µs per sentence on the phone.

## Status

| | |
|---|---|
| DSP synthesis, decoder through PCM | Measured on SM8550 |
| Custom CoreCLR phonemizer front end, on the phone | Measured |
| Running with or without the decoder | Supported |
| Streaming at any length (time-major schedule) | Next |
| Time to first audio, end to end | Not yet measured |
| SM8635 | Not yet run |

## Published comparisons

Checked October 10, 2026. Speed is audio duration divided by synthesis time. Each
row keeps its published device and timing scope; these are reference points, not a
matched ranking.

| Build | Device | Timed scope | Speed |
|---|---|---|---:|
| Kokoro-Hexagon | S23 / SM8550 | Decoder, harmonic source and generator; DSP only; 2.125 s audio | **21.3×** |
| [laishere/kokoro-coreml](https://github.com/laishere/kokoro-coreml#ios), comparison `484907d` | iPhone 16 Pro | Warm phonemes-to-PCM chain; six passages; G2P and load excluded | 16.9× mean |
| [Soniqo speech-swift](https://github.com/soniqo/speech-swift/blob/main/docs/benchmarks/ios-coreml.md) | iPhone 16 Pro | Core ML Kokoro, warm release benchmark | 12.5× |
| [kokoro-offline-tts-android](https://github.com/cedgeremek/kokoro-offline-tts-android#real-device-demo) | S24 Ultra / SM8650 | QNN HTP generator; separately reports 306 ms warm request-to-first-audio | 3.78× |

The kokoro-coreml figures cover phonemes to PCM, including the text encoder and
predictors; ours do not yet. A leadership claim requires matched inputs and stage
coverage.

## Development

PowerShell 7.4 or later:

```powershell
pwsh -NoProfile -File ./Invoke-KokoroDevelopment.ps1
pwsh -NoProfile -File ./Invoke-KokoroDevelopment.ps1 Verify
```

The default command reports repository state and available commands without
touching a phone. `Verify` runs the same checks as CI. Dependencies are pinned by
hash; generated artifacts stay under the ignored `build/` directory. Phone commands
run only against an attached, authorized device, and results from different phone
models are kept separate.

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
