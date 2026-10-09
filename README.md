# Kokoro-Hexagon

Kokoro-82M text-to-speech on Android with the whole model on the Hexagon DSP.
PowerShell reads the stock checkpoint, quantizes and packs the weights, and
emits Hexagon machine code directly: HMX for convolutions and matrix
multiplies, HVX for the rest, integer throughout (16-bit activations, W8x2
weights, per-channel scales). The ARM CPU turns text into phonemes, drives
the DSP and plays PCM through AAudio.

See [AGENTS.md](AGENTS.md) for the build contract and `docs/results/` for
device receipts (each with numbers, artifact hashes and commit).

| Path | Contents |
|---|---|
| `src/hexagon` | Hexagon instruction encoder, DMA copy and hardware probes (the ELF writer is `tools/Emit-HexagonProbe.ps1`) |
| `src/kernels` | HMX/HVX kernel body generators (convolution, AdaIN, Snake, combine, STFT, harmonic source, decoder pieces, ALBERT attention) |
| `src/jobs` | DSP job assemblies: decoder, generator stages and tail, harmonic source, resblock runners |
| `src/models` | Checkpoint readers and weight conversion |
| `src/runspace` | Native binding, AAudio, dspqueue layout, device harnesses |
| `tools` | Fixture builders (from stock PyTorch captures), emission checks, device runners, scorers |
| `phonemizer` | Text to Kokoro token IDs (Zira distillation, CoreLib-only); imported from PSPerception, see below |
| `lib` | Pinned inputs (`manifest.json`) and the stock Kokoro config |

Generated files go in the ignored `build/`.

## Current state, 2026-10-08

Measured on SM8550, hello-world sentence (af_heart, 1.625 s of audio), against
stock PyTorch Kokoro at `dfb907a0`; scales calibrated on two other sentences.
Every row is a run on the phone, three runs with identical output, bytes
checked against the SDK 6.4.0.2 assembler.

| Job | SNR vs stock | DSP time | Receipt |
|---|---:|---:|---|
| **Whole generator with the harmonic source and STFT in one job**, from captured decoder output, f0 and noise draws (stock against itself with the source in float64: 40.83 dB) | **37.24 dB PCM** | **95.57 ms** | [generator-whole-source](docs/results/generator-whole-source-sm8550-20261008.md) |
| Harmonic source + STFT alone, f0 to har | 64.62 dB (har magnitude) | 3.95 ms | [harmonic-source](docs/results/harmonic-source-sm8550-20261008.md) |
| Whole generator in one job (10x half, LeakyReLU(0.1) into ups[1] on the DSP, 60x half, tail), from captured decoder output and har | **42.05 dB PCM** | **79.71 ms** | [generator-whole](docs/results/generator-whole-sm8550-20261008.md) |
| Generator 60x half (noise_convs[1], noise_res[1], ups[1], resblocks.3-5, mean) + tail (LeakyReLU, conv_post, exp/sin, iSTFT) in one job, from captured ups[1] input and har | **42.71 dB PCM** | **46.48 ms** | [generator-front-stage-tail](docs/results/generator-front-stage-tail-sm8550-20261008.md) |
| resblocks.3-5 + mean + tail, from captured resblocks.3 input | 45.70 dB PCM | 32.12 ms | [generator-stage16-tail](docs/results/generator-stage16-tail-sm8550-20261008.md) |
| Tail alone | 46.03 dB PCM | 3.06 ms | [generator-tail16](docs/results/generator-tail16-sm8550-20261008.md) |
| Generator 10x half (LeakyReLU(0.1), ups[0], noise_convs[0], noise_res[0], resblocks.0-2, mean) in one job, from captured decoder output and har | **58.56 dB** | **31.67 ms** | [generator-10x-half](docs/results/generator-10x-half-sm8550-20261008.md) |
| resblocks.0-2 + mean (256 channels) | 64.14 dB | 23.24 ms | [generator-resblocks012](docs/results/generator-resblocks012-16bit-sm8550-20261008.md) |
| noise_res[0] (256 channels) | 74.81 dB | 7.74 ms | same receipt |
| noise_res[1] (128 channels) | 54.87 dB | 11.00 ms | [noise-res1](docs/results/noise-res1-16bit-sm8550-20261008.md) |

The 60x half plus tail is RTF 0.029 for that part of the model. PCM from these
jobs plays on the phone speaker as "hello world".

The whole generator, its harmonic source and STFT included, runs as one job in
95.57 ms for 1.625 s of audio (generator RTF 0.059) from the decoder output and f0.
Next: the decoder (W4A8 per layer
where the error allows), the prosody and duration predictors, the text encoder
and ALBERT. Whole-model RTF, time to first audio, and SM8635 results are not yet
measured.

## Phonemizer

Text to Kokoro token IDs, distilled from Windows SAPI Zira (contextual
pronunciation choices such as noun/verb `record`) into a compact PSD1 and a
CoreLib-only assembly, with the selection logic compiled alongside the data.
Developed in PSPerception and imported here at a pinned commit (see [phonemizer/README.md](phonemizer/README.md)); it now
builds under `build/phonemizer` from pinned inputs and all its Windows gates pass. On SM8550 the driver loads in
the phone app in 15 ms, takes 25 ms on its first call and 39 µs warm per sentence, with token IDs identical to
Windows ([phonemizer-driver](docs/results/phonemizer-driver-sm8550-20261008.md)). Only 22 of the 73 challenge
sentences are complete: inflected forms, numbers, units, dates and acronyms, and unresolved heteronyms still fail.

Direction: Moby lexicon and Zira-distilled choices, polished with hand-written rules (stress on content words, US flaps,
function-word weak forms, morphology, numbers). Misaki is not used.
