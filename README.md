# Kokoro-Hexagon

Kokoro-82M text-to-speech on Android, authored in PowerShell, with the decoder,
harmonic source and generator running together on the Hexagon DSP. The active
network-free front end uses a phonemizer, unit bank and learned prosody tables in
place of ALBERT, the text encoder and predictors. The integrated synthesis result
below uses Windows-prepared inputs. The phonemizer has been verified independently
on the phone; the complete Android text-to-audio pipeline is not connected yet.
The stock whole-model DSP path remains the reference track.
PowerShell reads the stock checkpoint, quantizes and packs the weights, and
emits Hexagon machine code directly: HMX for convolutions and matrix
multiplies, HVX for the rest, integer throughout (16-bit activations, W8x2
weights, per-channel scales). The target Android pipeline runs phonemization,
unit selection and table-driven prosody on the ARM CPU, drives the DSP and plays
PCM through AAudio.

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

## Current state, 2026-10-10

**Network-free Kokoro on SM8550: “I can eat a peach for hours.”**

The first bank-front-end sentence ran through the connected decoder, harmonic
source, generator and PCM path on the phone and played through AAudio. Scott heard
the speaker playback and reported good sound quality. All three runs produced the
same PCM hash.

| Measurement | Result |
|---|---:|
| Audio | 2.125 s, 51,000 samples |
| Median DSP execution | **148.495 ms** |
| Real-time speed, DSP only | **14.3×** |
| PCM SNR against the matching Windows teacher | **31.29 dB** |
| Clipped samples | **0** |
| Requested VTCM / measured capacity | **7.75 / 8 MiB** |

For this integration check, the bank front end assembled inputs and capture-derived
tables on Windows; the connected synthesis job ran on SM8550. The reference is stock
PyTorch decoder/generator math driven by those same assembled inputs. These numbers
measure DSP execution, not end-to-end latency or time to first audio.

The original 22-tile convolution batch requested 8.25 MiB and failed resource
acquisition before playback. Manually reducing it to 14 tiles saved 512 KiB and fit
the same complete 85-frame sentence in 7.75 MiB. Its phrasing and inputs were
unchanged. This was a scratch-size workaround, not temporal chunking or an
automatic memory planner.

The exact library, inputs, receipt, PCM and listening verdict are preserved outside
`build/` and protected by the `network-free-peach-sm8550` ratchet case. See the
[baseline receipt](docs/results/bank-front-end-sm8550-20261010.md). Run the gate with
`pwsh -NoProfile -File ./Invoke-KokoroDevelopment.ps1 -Command Ratchet -Case network-free-peach-sm8550`.

Next: phone-resident integration of the accepted system. Give the generator runtime
frames, persist and compile the existing selector/prosody tables, and connect the
installed APK host and local payload so fresh text produces phone speech with
Windows disconnected. Start with short sentences using runtime normalization, then
bounded streaming. Learned AdaIN controls, pronunciation improvements and the 17x
speed target do not block the first resident sentence.
For streaming, test arbitrary decoder-frame cuts with carried conditioning/state
and direct activation binding. Measure the largest stage handoff and simultaneous
live memory, then try a static frame-chunk schedule that keeps the working set in
VTCM. Execution cuts need not follow phonemes, words or spoken groups.
The deferred [VTCM-aware graph tiling design](docs/vtcm-aware-graph-tiling-design.md)
records tiling across time, channels, windows and buffers while preserving graph
semantics and contiguous PCM. Changing tile size must preserve the operation being
computed; approximation error is measured separately. The newest handoff sets the order.

## Earlier stage receipts, 2026-10-08

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
The connected stock-input decoder and generator subsequently reached 31.99 dB PCM
in 106.8 ms on SM8550 ([receipt](docs/results/decoder-generator-sm8550-20261009.md)).
Stock whole-model RTF, time to first audio, and connected SM8635 speech remain unmeasured.

## Published comparisons

Checked 2026-10-10. Speed is audio duration divided by synthesis time. These runs
use different phones, inputs and timing scopes; they are context for our targets,
not a matched ranking. External results are the authors' measurements.

| Build | Device | Timed scope | Published speed |
|---|---|---|---:|
| [Kokoro-Hexagon network-free baseline](docs/results/bank-front-end-sm8550-20261010.md) | SM8550 | Connected decoder, source and generator; DSP only; 2.125 s audio | **14.3×** |
| [laishere/kokoro-coreml](https://github.com/laishere/kokoro-coreml#ios), pinned comparison `484907d` | iPhone 16 Pro | Warm phonemes-to-PCM chain; six passages; G2P and load excluded | **16.9× mean**, 19.8× on the 8.07 s passage |
| [Soniqo speech-swift](https://github.com/soniqo/speech-swift/blob/main/docs/benchmarks/ios-coreml.md) | iPhone 16 Pro | Core ML Kokoro, warm release benchmark | **12.5×** (RTF 0.08) |
| [kokoro-offline-tts-android](https://github.com/cedgeremek/kokoro-offline-tts-android#real-device-demo), earlier Android reference | S24 Ultra / SM8650 | QNN HTP generator; separately reports 306 ms warm request-to-first-audio | **3.78×** (generator RTF 0.2644) |
| [Morph developer report](https://www.reddit.com/r/TextToSpeech/comments/1sc32wb/kokoro_tts_running_oniphone_cpuonly_20x_realtime/) | iPhone 17 Pro | CPU; modified model with a trained replacement stage; no reproducible benchmark protocol established | **20× claimed** |

The 17× target is a milestone, not proof of being the fastest mobile Kokoro.
Our complete phone-resident text-to-audio and first-audio timings remain pending.
The [six-passage protocol](docs/speed-target.md) defines the stock comparison inputs.

## Phonemizer

Text to Kokoro token IDs, distilled from Windows SAPI Zira (contextual
pronunciation choices such as noun/verb `record`) into a compact PSD1 and a
CoreLib-only assembly, with the selection logic compiled alongside the data.
Developed in PSPerception and imported here at a pinned commit (see [phonemizer/README.md](phonemizer/README.md)); it now
builds under `build/phonemizer` from pinned inputs and all its Windows gates pass. On SM8550 the driver loads in
the phone app in 15 ms. With the polish pass it takes 57.8 µs warm per sentence on SM8550, with token IDs identical
to Windows; 73 of 73 challenge and 149 of 153 held-out sentences complete
([phonemizer-polish](docs/results/phonemizer-polish-sm8550-20261008.md)).

Direction: Moby lexicon and Zira-distilled choices, polished with hand-written rules (stress on content words, US flaps,
function-word weak forms, morphology, numbers). Misaki is not used.
