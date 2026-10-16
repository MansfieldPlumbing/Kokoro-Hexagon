# Kokoro-Hexagon

Follow [the shared agent rules](../Pwsh-Development/AGENTS.md). This file holds local project requirements and entrypoints.


## Start here

Read [the Student-driven phase generator contract](docs/student-generator-contract.md)
before planning or interpreting stock-model references. It owns the active
architecture: one 300-sample clock, Student-generated input/control programs,
streamed AdaIN affines and the existing hardware Lock/bounce primitive. Stock
Kokoro is an offline teacher/reference. Do not rebuild AdaIN or trig Snake or
restore a runtime decoder/bank because an older skill or handoff assumes them.

Use `C:\Dev\Kokoro-Hexagon` on branch `main`, one task at a time. Create no
additional Kokoro-Hexagon worktree unless Scott is running two agents at once.
Retain branches as recoverable history when consolidating checkouts.

    pwsh -NoProfile -File ./Invoke-KokoroDevelopment.ps1

Run `Verify` before every commit; CI runs the same command on every push.

It prints the commit, the next step and every command, reading only the repository (no adb or phone; phone access is
only in `Run`, `Ratchet`, `Compare` and `Speak`) (stock captures, ALBERT error, emit,
kernel check, phone runs, ratchet, job inputs, search). Do recurring project work through its commands. When a
recurring operation earns a command, add it to `Invoke-KokoroDevelopment.ps1` and use it. A one-time audit or
investigation may use a small temporary solution; a scratch script alone does not justify a permanent command. Scripts under
`tools/` are being absorbed into it as they are used.

## How agents edit and run

1. Edit files with the editor tool. Never edit source through shell string replacement (ReadAllText,
   .Replace, .Contains anchors, Set-Content, sed).
2. Do recurring project work through Invoke-KokoroDevelopment.ps1 commands. Put a recurring operation in
   that entrypoint when it reduces actual delivery friction. Command length or use of temporary scratch
   alone does not justify permanent machinery. Preserve the existing phone-access boundary.
3. Number each item in a handoff's "## Next" and name its entrypoint command, or "new command `<Name>`" for a
   command the item adds. Verify checks this.

## Mission

The fastest, most efficient Kokoro-82M text-to-speech on Android, authored in
PowerShell, with the model math running on the Hexagon DSP (HMX and HVX)
through machine code this project emits itself.

The priority is the agreed Student-driven phase generator with publishable
end-to-end timing and listening evidence. Preserve stock as the offline teacher
and benchmark reference; stock whole-model publication does not gate the active
architecture. Compare matched artifacts/conditions on each phone when device
work is authorized. The current task determines the next bounded experiment.

Active path: the Student generates the frozen generator's 512-channel features,
F0/voicing and affine/phase controls on one 300-sample timeline. No runtime text
encoder, neural decoder or per-unit acoustic lookup bank. The existing bank and
stock whole-model path are read-only offline evidence. Current user tasks set
work order; historical handoffs cannot override the active contract.

## Where we stand (2026-10-09)

Historical stock-port snapshot; missing stock stages below are not an active
runtime work queue. Follow the current Student/phase contract for new work.

Kokoro-Hexagon is notable for how it is made: the model path is
authored only in PowerShell, which emits the Hexagon machine code and ELF itself. No C, C++, LLVM or QNN produces any of it.

### Benchmark comparison: published on-device Kokoro-82M results

Speed is audio length divided by synthesis time (higher is faster). Each project measured on its own device, input and
stage coverage, so read each row with its scope. Rows are what each project published; we have not rerun them.

| Build | Device | Precision | Runs on | Scope timed | Audio | Time | Speed |
| --- | --- | --- | --- | --- | ---: | ---: | ---: |
| Kokoro-Hexagon (incomplete) | SM8550 | W8 weights, 16-bit act. | Hexagon HMX + HVX | decoder + generator only, DSP time, no dispatch | 1.625 s | 106.8 ms | 15.2x |
| kokoro-coreml-ane `484907d` | iPhone 16 Pro | fp16 + int8 palettized | ANE + GPU + CPU | phonemes to PCM, warm | 1.50 s | 132 ms | 11.4x |
| kokoro-coreml-ane `484907d` | iPhone 16 Pro | fp16 + int8 palettized | ANE + GPU + CPU | phonemes to PCM, warm | 8.07 s | 407 ms | 19.8x |
| kokoro-coreml-ane `484907d` | iPhone 16 Pro | fp16 + int8 palettized | ANE + GPU + CPU | phonemes to PCM, mean of 6 passages | 1.5-28 s | | 16.9x |
| kokoro-coreml `a3f1ff2` (paper, table iphone) | iPhone 15 Pro Max | | Core ML, staged | warm median, release | 3 s | 426 ms | 6.6x |
| kokoro-coreml `a3f1ff2` (paper, table iphone) | iPhone 15 Pro Max | | Core ML, staged | warm median, release | 30 s | 3742 ms | 7.3x |
| kokoro-offline-tts-android `af85992` | S24 Ultra (SM8650) | | QNN HTP + CPU | generator | | | 3.2-3.8x |
| kokoro-ios `4d6d1d8` | iPhone 13 Pro | | MLX | warm, release build | | | 3.3x |

What Kokoro-Hexagon does not cover yet: ALBERT, the text encoder and the predictors on the DSP; host dispatch (139-170 ms
per synchronous invoke against 106.8 ms on the DSP); audio longer than about 2.3 s per job; SM8635. The like-for-like
run is the six kokoro-coreml-ane benchmark passages (`docs/speed-target.md`).
### Kokoro-Hexagon stages, SM8550, hello world (1.625 s), receipts in `docs/results/`

| What runs on the DSP | vs stock PyTorch | DSP time | RTF of that part |
| --- | ---: | ---: | ---: |
| Decoder + whole generator + harmonic source, one job, from asr, F0 and N | 31.99 dB PCM | 106.8 ms | 0.066 |
| Decoder alone | 41.54 dB | 14.4 ms | 0.009 |
| Whole generator with the harmonic source and STFT, from decoder output and f0 | 37.24 dB PCM | 95.57 ms | 0.059 |
| Harmonic source + STFT alone (f0 to har) | 64.62 dB | 3.95 ms | 0.002 |

Stock against itself with only the source in float64 agrees at 40.83 dB PCM, so about 40 dB is what a faithful port can
reach against stock's float32 output.

Not yet measured: the predictors, text encoder and ALBERT on the DSP; whole-model speed with dispatch; time to first
audio; audio longer than about 2.3 s (decoder and generator keep the whole sequence in VTCM); anything on SM8635.

## How it is built

- PowerShell 7 is the language. It reads the checkpoint, quantizes and packs
  the weights, and emits Hexagon machine code and ELF directly. No C, C++ or
  C# product code; no LLVM, QNN, ONNX Runtime or Python in the build or on the
  phone. The one exception is the minimal native bootstrap that starts CoreCLR
  on Android.
- The compiled Student is the runtime front end. The frozen generator is the
  only neural execution component. The source branch is computed, never stored.
- PowerShell does not run the model at inference time; the compiled model DLL
  and a small host do.
- HMX runs the frozen convolutions. Supplied AdaIN affines and the existing
  hardware phase/bounce operation replace runtime normalization and trig Snake.
  Reuse emitted residual, source and inverse-transform mechanisms.
- Keep the frozen FP16 reference. Quantized variants are separate measured
  experiments; the old integer-only constraint belongs to the historical port.
- Dispatch: one FastRPC setup, then dspqueue for every job.
- Activations keep one HMX-native layout through the generator and iSTFT.
  Elementwise phase/affine, residual, source and spectral work reads and writes that
  layout, so no stage spends time converting layouts between operators.
- The generator weights remain frozen. The Student/phase-controlled runtime
  is the agreed variant now; stock end-to-end publication is not a prerequisite.
  Preserve stock receipts and label comparison conditions accurately.

## Order of work

1. Follow the current user task and the active contract; speech/listening evidence
   precedes optimization. Do not impose stock normalization as an integration gate.
2. Carry Student and generator state across transport blocks on the 300-sample
   clock. Linguistic context does not define a new normalization or DSP clock.

## Use what already exists

- Search before building or reverse engineering: Kokoro source and ports,
  published Hexagon projects (llama.cpp `ggml-hexagon`, integer-HMX work),
  papers, and ONNX and QNN graphs, contexts and profiles. Then our earlier
  work in `C:\Dev\Kokoro-QNN-old` (read-only, once the team agrees to it for
  the task). Reverse engineer only what none of them covers.
- Read outside code at a pinned commit in `C:\Dev\.vendor`. Rewrite what is
  adopted in PowerShell and cite the project and commit.
- Check correctness by comparing each DSP stage with stock PyTorch Kokoro
  outputs captured on Windows. Do not write a second implementation of the
  model to compare against. Report int8 error against the stock FP32 output.

## Implementation workflow

1. Before writing a kernel or investigating an interface, search online for
   existing Kokoro ports, integer HMX/HVX implementations, papers, and relevant
   graphs or profiles. Start with the pinned stock Kokoro source, onnxsim HMX
   work, and ggml-hexagon. Record the useful source locations and full commits.
   Use existing results to choose the next bounded implementation step.
2. Inspect existing project emitters, weight readers, runtime code, and receipts
   before adding code. Reuse the working path. Rewrite adopted algorithms in
   PowerShell; do not introduce another model implementation or compiler as a
   prerequisite. Reverse engineer only the gaps remaining after source search.
3. For new instruction forms, establish the encoding from the version-matched
   manual and SDK assembler (or LLVM's Hexagon tables) and compare emitted
   bytes; SDK tools are validation references only. Validate behavior on the
   phone's DSP: the app is Pwsh and drives FastRPC directly, so the real
   hardware is the test. Use the V73 simulator only for a question the phone
   cannot answer (stepping a hang with no crash report, a target with no
   device), and say which question.
4. Use stock checkpoint weights and stock PyTorch captures on Windows for
   numerical comparison. Synthetic fixtures establish instruction semantics;
   real captures establish propagated model error. Keep those checks distinct.
5. Run the checked artifact on each target phone, selected by SoC, and record
   correctness and measured timing with artifact hashes. Keep SM8550 and
   SM8635 evidence separate. Advance to the next connected region once the
   current correctness gate passes; do not optimize an isolated throughput
   result while real-model correctness remains unproved.
6. Implement the current Student/frame/phase task using existing mechanisms.
   Do not restart completed stock porting milestones or restore eliminated networks.

Stock reference reproduction retains its own group/style/statistics semantics
offline. Those semantics are comparison conditions, not active runtime requirements.
Performance targets and competitor results guide investigation; only matched
phone measurements establish achieved speed and time to first audio.

## Proof

- A claim about the phone needs a run on the phone with the same artifact.
  Keep SM8550 and SM8635 results separate.
- Speech means PCM played from the phone speaker by this project's path.
- Receipts go in `docs/results/`: short, with numbers, artifact hash and commit.
- Proven so far: the emitted R0Sub0 kernel runs 2.21-2.29x faster than LLVM's
  in DSP ticks, bit exact, on both SoCs; dspqueue dispatch runs 1.94x faster
  than synchronous invoke on SM8635, with a 120 us warm median.
- Connected integer generator resblocks.3, .4 and .5 pass V73 simulation
  and 3/3 SM8550 runs each, with exact meaningful native output lanes and
  all live AdaIN coefficients. See
  `docs/results/generator-residual-branches-sm8550-20261006.md`.
  The combined worker passes full-group V73 arithmetic simulation and
  3/3 SM8550 runs: 19 stages, zero output-lane and coefficient-byte mismatches
  (see `docs/results/generator60x-combined-sm8550-20261006.md`). Whole-generator
  speech and end-to-end timing are not proved.
- The resident 128-channel stage (resblocks.3-5 and mean, 7,801 frames, 1.625 s of
  audio) runs in 31.48 ms on SM8550 with four HVX worker threads and 22-tile batches,
  output exact (86.05 ms on one thread). See
  `docs/results/generator60x-hvx-threads-sm8550-20261007.md`.
- The 16-bit version of that stage runs in 29.40 ms on SM8550 at 66.68 dB SNR against the
  stock float output (scales calibrated on the same sentence). See
  `docs/results/generator60x-16bit-sm8550-20261008.md`. With the low x low group, rounded table biases and
  scales calibrated on two other sentences (holdout): 68.76 dB in 29.84 ms. See
  `docs/results/generator60x-16bit-holdout-sm8550-20261008.md`.
- The 16-bit generator tail (LeakyReLU, conv_post, exp/sin, iSTFT as an HMX conv) plays stock-input
  hello world at 38.07 dB PCM against stock in 2.97 ms on SM8550. See
  `docs/results/generator-tail16-sm8550-20261008.md`.
- Stage and tail in one DSP job: captured resblocks.3 input to PCM at 45.70 dB in 32.12 ms on SM8550,
  heard as hello world (fine/coarse magnitude windows; 37.67 dB before).
- noise_res[1] (one 16-bit resblock, kernel 11) at 54.87 dB in 11.00 ms on SM8550. See
  `docs/results/noise-res1-16bit-sm8550-20261008.md`.
- The generator's 60x half (noise branch, ups[1], resblocks.3-5) and tail in one DSP job: captured ups[1] input
  and har to PCM at 42.71 dB in 46.48 ms (1.625 s of audio) on SM8550. See
  `docs/results/generator-front-stage-tail-sm8550-20261008.md`.
- resblocks.0-2 and their mean at 256 channels: 64.14 dB in 23.24 ms, noise_res[0] 74.81 dB in 7.74 ms, on SM8550. See
  `docs/results/generator-resblocks012-16bit-sm8550-20261008.md`.
- The generator's 10x half (LeakyReLU(0.1), ups[0], noise_convs[0], noise_res[0], resblocks.0-2, mean) in one
  DSP job from captured decoder output and har: 58.56 dB in 31.67 ms on SM8550. See
  `docs/results/generator-10x-half-sm8550-20261008.md`. See `docs/results/generator-stage16-tail-sm8550-20261008.md`.
- The whole generator in one DSP job, captured decoder output and har to PCM: 42.05 dB in 79.71 ms (1.625 s of
  audio) on SM8550, played. See `docs/results/generator-whole-sm8550-20261008.md`.
- The harmonic source and STFT on the DSP: f0 to har at 64.62 dB magnitude in 3.95 ms; with it, the whole generator
  from captured decoder output, f0 and noise draws to PCM in one job: 37.24 dB in 95.57 ms on SM8550, played (stock
  against itself with the source in float64: 40.83 dB). See `docs/results/generator-whole-source-sm8550-20261008.md`.
- The phonemizer driver with its polish pass (stress, flaps, weak forms, numbers, inflection) runs in the phone app
  on SM8550 with token IDs identical to Windows, 57.8 us warm per sentence; 73 of 73 challenge and 149 of 153
  held-out sentences complete. See `docs/results/phonemizer-polish-sm8550-20261008.md`.

## Product shape

- The APK (a model-less host, namespace `Dev.MansfieldPlumbing.Kokoro`) and
  the model DLL ship separately. A new DLL is staged in private storage,
  checked (signed manifest, length, SHA-256), activated atomically, and loaded
  on the next restart.
- User text is data. Never evaluate it as PowerShell. Bounds-check text,
  tensor shapes and offsets before use.
- Name things for what the model does (`AdaIn`, not `Normalize`).

## Repository

- Generated output (DLLs, APKs, ELF, weights, audio, ONNX, contexts, logs)
  goes in the ignored `build/` and is never committed. Signing keys and package
  caches stay outside the repository. No device identifiers in the repository.
- Scripts use approved PowerShell Verb-Noun names.
- `C:\Dev\Pwsh` is a separate upstream checkout. Never write, build or run git
  operations there; take Pwsh from GitHub at the commit pinned in
  `lib/manifest.json`.
- Ask before deleting, pushing or rewriting history.
