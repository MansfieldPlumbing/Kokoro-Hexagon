# Kokoroku

**It's Kokoro. It's Hexagon. It's Pwsh.**

**Offline neural speech synthesis on Qualcomm Hexagon — with machine code emitted directly from PowerShell.**

Kokoroku is an independent implementation of [Kokoro-82M](https://github.com/hexgrad/kokoro) for Qualcomm's Hexagon DSP. Instead of handing a model to PyTorch, ONNX Runtime, QNN, or a GPU delegate, it reads the original model checkpoint, prepares the weights, constructs HMX/HVX instructions, schedules the work, and emits the ELF library itself.

Its generator runs depth-first, keeping small activation windows close to the matrix hardware rather than materializing whole-utterance intermediate tensors. The result is a speech-generation engine written *for* the DSP, not a wrapper around a general-purpose inference runtime.

**Measured on Snapdragon 8 Gen 2 (SM8550): approximately 107× real-time DSP generator throughput**, with exact PCM equivalence to the project's integer layer-by-layer reference. No Adreno GPU is used. HMX is a dedicated matrix accelerator on the Hexagon DSP.

> **Project status:** Active systems research and reproducible hardware experiments. This repository is not yet a turnkey Android TTS library or a polished end-user release.

## Measured performance

The qualified November 19, 2026 **`section-front-pack`** candidate generated **11.775 seconds of 24 kHz speech** with the harmonic source on the DSP:

| Measurement | Result | Boundary |
| --- | ---: | --- |
| DSP generator | **106.93–107.02× real time** | **110.027–110.119 ms** warm median |
| DSP generator RTF | **~0.00935** | Generator only; lower is better |
| Host-visible invocation | **80.4–80.8× real time** | **145.721–146.407 ms** |
| Waveform correctness | **Exact PCM** | 26 confirmation runs plus 5 runs with a second seed |

The benchmark starts with supplied acoustic representation and controls; it **does not include text normalization, phonemization, the stock linguistic front end, or the decoder**. Exact PCM means byte-for-byte agreement with the *integer layer-by-layer generator reference under the same weights and supplied normalization*, **not** bit identity with upstream PyTorch's floating-point output.

The qualified candidate is preserved as a **reproducible experimental patch**, not silently substituted for the repository's default generator. Faster diagnostic variants exceeding 120× bypass learned source residuals or change activation arithmetic and **do not preserve the same audio**; they are not equivalent-quality benchmark claims.

Read the [November 19 throughput report](docs/results/generator-depth-first-throughput-sm8550-20261119.md) for candidate/control comparisons, SHA-256 checks, per-run timing, negative results, and reproduction steps.

## What makes it different

- **PowerShell is the development environment.** It reads the original `.pth` checkpoint, constructs typed instruction records, packs weights, and emits native Hexagon ELF code. No C/C++ compiler, LLVM, QNN, or ONNX Runtime is needed for the device generator path.
- **Direct HMX/HVX execution.** HMX performs matrix convolutions; HVX handles activation transforms, AdaIN, Snake, harmonic synthesis, and spectral operations. Four HVX hardware threads cooperate with the matrix engine.
- **Depth-first scheduling.** Convolutions operate on 32-frame tiles and maintain bounded history rings. Intermediate activations can remain in VTCM instead of repeatedly traversing full-length DDR tensors.
- **Explicit machine-level behavior.** Instruction encoding, VLIW packet grouping, DMA, memory layout, synchronization, and weight residency are implemented and investigated in the repository.
- **Reference-driven verification.** Emitted kernels are checked against reference arithmetic, a Qualcomm simulator where applicable, and actual SM8550 execution. Schedule-only changes must reproduce the same integer-reference PCM.

The absence of a conventional ML runtime does **not** mean an absence of hardware acceleration: HMX and HVX are the accelerators.

## Architecture

```text
                         Text
                          |
             English phonemizer / CoreCLR
                          |
          Stock linguistic front end (CPU)
             or procedural Student (WIP)
                          |
        Phonemes / durations / F0 / N / style
                          |
                 Decoder (Hexagon)
                          |  acoustic x
        +-----------------+------------------+
        |                                    |
   Harmonic source                  Depth-first generator
   and seeded noise                HMX convolution / HVX
        |                                    |
        +-----------------+------------------+
                          |
                Inverse spectral tail
                          |
                      24 kHz PCM
```

The **stock front end** remains the established input path. The procedural **Student** is an independent research effort to replace increasingly large parts of the learned linguistic and acoustic conditioning. The decoder and generator use supplied normalization coefficients to avoid a whole-utterance normalization dependency.

The generator has three kernel-width branches (`3`, `7`, `11`), each progressing through dilation pairs (`1`, `3`, `5`). Its backward schedule staggers the dependencies so each pair advances by one output tile while carrying only the necessary history. Scheduling, weight traffic, and intermediate-buffer lifetimes are first-class parts of the implementation.

## Reproduce the generator experiment

Start with the repository's pinned PowerShell development environment and the required original model/reference assets. The commands below reproduce the **emitted generator library** for the November 19 exact-PCM candidate; a complete phone benchmark also requires the recorded fixture, diagnostic host, and authorized SM8550 device.

```powershell
git clone https://github.com/MansfieldPlumbing/Kokoroku.git
Set-Location Kokoroku

# Read project status without accessing the phone.
pwsh -NoProfile -File ./Invoke-KokoroDevelopment.ps1

# Run repository verification.
pwsh -NoProfile -File ./Invoke-KokoroDevelopment.ps1 Verify

# Reconstruct the exact-PCM experiment in a detached worktree.
New-Item -ItemType Directory -Path build -Force | Out-Null
$tools = (Resolve-Path tools/experiments/generator-throughput-20261119).Path
$tree  = Join-Path (Resolve-Path build) 'repro-front-pack'
& "$tools/New-ExperimentCheckout.ps1" -Variant section-front-pack -Destination $tree
& "$tools/Export-ExperimentGenerator.ps1" -Checkout $tree -OutputDirectory "$tree/build/emission"
```

The emitted library is `libkokoro_generator_tail_skel.so`. For the complete run procedure, including expected PCM SHA-256 and timing controls, follow [the experiment report](docs/results/generator-depth-first-throughput-sm8550-20261119.md). `Verify` is not a substitute for on-device qualification. Development/reference tooling may use additional dependencies; the **device generator** does not use PyTorch, QNN, or ONNX Runtime.

## Current research

**Qualified or demonstrated**

- Depth-first Hexagon generator with DSP-side harmonic source and exact integer-reference output.
- On-phone SM8550 benchmarking, matrix instruction observations, simulator comparisons, and byte-level correctness checks.
- A decoder path using bounded chunks and supplied AdaIN coefficients.
- PowerShell-authored ELF emission and hardware-specific scheduling experiments.

**Under development or not yet qualified**

- A procedural Student replacing stock front-end and potentially decoder computations.
- A fourth, weightless output phase, with procedural high-frequency air and 48 kHz realization.
- Native Opus output and its end-to-end DSP timing.
- A streamlined public build/distribution and broader device qualification.

The current **48 kHz FM-air examples are offline auditions**, derived from the measured 24 kHz baseband. They are *not* evidence that native 48 kHz generation or Opus encoding has already reached the reported DSP throughput.

## Repository map

| Location | Purpose |
| --- | --- |
| [`Invoke-KokoroDevelopment.ps1`](Invoke-KokoroDevelopment.ps1) | Main development, verification, emission, and device-run entry point |
| [`Invoke-HexagonDevelopment.ps1`](Invoke-HexagonDevelopment.ps1) | Hexagon instruction representation, encoding, packets, and ELF emission |
| [`src/jobs/Kokoro.Generator60x16Run.ps1`](src/jobs/Kokoro.Generator60x16Run.ps1) | Generator schedules, weights, buffers, and source/residual sections |
| [`src/jobs/Kokoro.DecoderRun16.ps1`](src/jobs/Kokoro.DecoderRun16.ps1) | DSP decoder |
| [`phonemizer/Invoke-EnglishPhonemizer.ps1`](phonemizer/Invoke-EnglishPhonemizer.ps1) | English phonemizer |
| [`student/Invoke-Student.ps1`](student/Invoke-Student.ps1) | Procedural Student research |
| [`tools/experiments/generator-throughput-20261119`](tools/experiments/generator-throughput-20261119) | Reconstructible optimization candidates and per-invocation timing |
| [`docs/results`](docs/results) | Measurements, failures, and hardware investigations |

## Research integrity

Every throughput number needs a **device, input duration, timing boundary, implementation, and audio-quality contract**. Generator-only measurements cannot be ranked directly against full text-to-speech timings on other systems. A faster variant that changes the waveform is reported as such, not folded into the exact-PCM result.

Kokoroku is an independent project built around the [upstream Kokoro model](https://github.com/hexgrad/kokoro); it is not an official Qualcomm or Kokoro release. Hardware behavior attributed to HMX is derived from documented external measurements unless explicitly verified otherwise.
