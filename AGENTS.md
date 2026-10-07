# Kokoro-Hexagon

The machine-wide rules in `C:\Dev\AGENTS.md` apply.

## Mission

The fastest, most efficient Kokoro-82M text-to-speech on Android: stock Kokoro
weights, authored in PowerShell, with the model math running on the Hexagon
DSP (HMX and HVX) through machine code this project emits itself.

The scoreboard is end-to-end real-time factor and time to first audio on the
SM8550 and SM8635 phones, against the best other Kokoro build on the same phone.

## How it is built

- PowerShell 7 is the language. It reads the checkpoint, quantizes and packs
  the weights, and emits Hexagon machine code and ELF directly. No C, C++ or
  C# product code; no LLVM, QNN, ONNX Runtime or Python in the build or on the
  phone. The one exception is the minimal native bootstrap that starts CoreCLR
  on Android.
- The whole model runs on Hexagon, from phonemes to PCM: ALBERT, the duration
  and prosody predictors, the decoder, the generator, the harmonic source and
  iSTFT. The graph is not split between CPU and DSP. The ARM CPU only turns
  text into phonemes, drives the DSP, and plays PCM through AAudio.
- PowerShell does not run the model at inference time; the compiled model DLL
  and a small host do.
- HMX runs convolutions and matrix multiplies. HVX runs the rest: AdaIN,
  Snake, residuals, the harmonic source, iSTFT.
- Integer from the start: W8A8, and W4A8 per layer where the error allows,
  with per-channel scales. There is no FP32 or FP16 DSP stage to quantize later.
- Dispatch: one FastRPC setup, then dspqueue for every job.
- Activations keep one HMX-native layout from the decoder through the iSTFT.
  HVX work (AdaIN, Snake, residuals, source, STFT/iSTFT) reads and writes that
  layout, so no stage spends time converting layouts between operators.
- The model is stock Kokoro, every stage. Changing its architecture (for
  example replacing AdaIN) is the owner's decision.

## Order of work

1. Speech before speed. Make every stage correct on the DSP, get audible
   speech on both phones, then optimize.
2. Render one breath group at a time, and render the next one while the
   current one plays. Stock Kokoro already runs each text chunk independently
   (`KPipeline` splits at punctuation, at most 510 phonemes, voice style
   `pack[len(ps)-1]`), so AdaIN statistics computed over each group are stock
   behavior. Fold AdaIN's style terms into per-channel scale and offset when a
   voice loads. Accumulate each group's mean and variance in the epilogue of
   the conv that produces it, and apply them as one fused multiply-add.

## Use what already exists

- Search before building or reverse engineering: Kokoro source and ports,
  published Hexagon projects (llama.cpp `ggml-hexagon`, integer-HMX work),
  papers, and ONNX and QNN graphs, contexts and profiles. Then the owner's
  earlier work in `C:\Dev\Kokoro-QNN-old` (read-only, with the owner's OK for
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
3. For new instruction forms, use version-matched SDK assembler output to
   establish the encoding, compare emitted bytes, then check the same emitted
   bytes in the V73 simulator. SDK tools are validation references only.
4. Use stock checkpoint weights and stock PyTorch captures on Windows for
   numerical comparison. Synthetic fixtures establish instruction semantics;
   real captures establish propagated model error. Keep those checks distinct.
5. Run the checked artifact on each target phone, selected by SoC, and record
   correctness and measured timing with artifact hashes. Keep SM8550 and
   SM8635 evidence separate. Advance to the next connected region once the
   current correctness gate passes; do not optimize an isolated throughput
   result while real-model correctness remains unproved.
6. Continue in this order: real generator resblocks.3 with per-channel W8A8
   HMX convolution and HVX AdaIN/Snake in the same native layout; the complete
   generator in one DSP job with DMA ping-pong; ALBERT, predictors, and decoder;
   then stock phoneme-to-PCM speech played through AAudio on both phones.

Render independent stock breath groups with exact full-group AdaIN statistics,
retaining chunk-length voice-style selection. Render the next group while the
current one plays. Preserve stock equations and the integer whole-DSP contract.
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
