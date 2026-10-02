# Demucs artifact audit and Kokoro compiler lessons

Date: 2026-09-27

## Scope

This receipt audits published six-stem Demucs artifacts to recover what the
completed implementation proved. The ONNX graph and TensorRT benchmark are
historical inspection surfaces only. They are not the implementation method,
and they are not build, compiler, or runtime dependencies of Kokoro-Hexagon.

The Kokoro product path remains PowerShell/SMA-authored model recovery and
direct Hexagon emission. No ONNX or TensorRT stage is proposed for that path.

## Pinned evidence

- Demucs repository: `MansfieldPlumbing/Demucs_v4_TRT` at
  `5fbc61f648ad22a98e884c85e0441b430fbc03d8`.
- ONNX LFS object: SHA-256
  `4bef152b260bb7ac65daabd591a673195f6c9b0e9eeb330bce6e834530388b0d`,
  246,148,867 bytes. The audited object matched both values and passed the
  ONNX checker.
- TensorRT engine LFS pointer: SHA-256
  `7aac0a5c6ccf21a1a43229f257440894767dc312e78c93c1296542e83d4e1164`,
  165,113,860 bytes. Engine claims below are limited to the checked-in
  `trtexec_benchmark_sm86.txt` receipt; the engine was not loaded locally.

## ONNX graph findings

The graph has one static FP32 input `[1,2,343980]`. The TensorRT receipt binds
the output as `[1,6,2,343980]`, ordered by the pinned host as drums, bass,
other, vocals, guitar, and piano. The chunk is 7.8 seconds at 44.1 kHz;
`htdemucs_6s` denotes six sources, not six seconds.

The ONNX graph contains 4,616 nodes, 525 initializers, and 1,522 Constant
nodes. It contains no `DFT` or `STFT` operator. The transform is lowered to
ordinary real-valued operations:

- Forward real bank: `Conv`, weight shape `[2049,1,4096]`, stride 1024.
- Forward imaginary bank: `Conv`, weight shape `[2049,1,4096]`, stride 1024.
- Inverse bank: `ConvTranspose`, weight shape `[4098,1,4096]`, stride 1024.
- The forward weights match Hann-windowed cosine and negative-sine Fourier
  bases normalized by `sqrt(4096)` to approximately `1e-7` in sampled rows.
- The three Fourier-bank constants occupy 134,283,264 bytes, about 54.55% of
  the ONNX file.

The exported artifact therefore proves that the completed Demucs graph had
already exposed the Fourier transform as ordinary real convolutional math.
This finding is derived exclusively from the project's own pinned artifact;
no external comparison is part of that implementation claim.

The public export source declares dynamic axes, but the audited artifact has a
static input. The source also depends on an exact modified Demucs package that
the repository does not pin. Those are provenance gaps until a build receipt
identifies the package revision and export command that produced the LFS
object.

## TensorRT receipt findings

The pinned SM86 receipt records TensorRT 10.15.1 on an RTX 3090:

- 157 MiB loaded engine.
- 403.305 MiB execution-context device memory.
- 4,616 ONNX nodes represented by 1,036 printed engine layer names.
- The two forward Fourier convolutions appear as one fused layer name,
  `/Conv_1 || /Conv`; the inverse remains `/ConvTranspose`.
- Mean latency 120.210 ms, median latency 117.238 ms, and mean GPU compute
  118.724 ms.
- Mean transfers total about 1.486 ms, or about 1.24% of mean latency.
- The raw 7.8-second chunk ratio is approximately 64.9 times real time.
  At 25% overlap, each invocation advances 5.85 seconds, yielding an
  approximately 48.7-times-real-time engine ceiling before file I/O and host
  overlap work.

The layer report is names-only and does not prove individual tactics or
precision. The repository describes FP16, but this receipt alone does not
establish the engine's precision choices. The large enqueue time also warrants
detailed profiling before attributing overhead to a specific cause.

## Kokoro compiler lessons

The applicable compiler lesson is:

1. Close the complete semantic graph at the intended product boundary.
2. Lower framework-level operations into typed primitive equations.
3. Fold fixed constants and specialize stable dimensions.
4. Fuse adjacent operations for the target and keep tensors resident.
5. Make the host submit compiled work rather than interpret operators.
6. Preserve an executable differential gate for each promoted region.

For Kokoro the corresponding closure is not an ONNX waveform wrapper. It is a
PowerShell/SMA-authored compiled function from admitted phonemes, a selected
voice row, and bounded mutation state to PCM. SMA owns validation, source
recovery, specialization, and direct Hexagon emission; the admitted model
artifact and direct Hexagon code own runtime math.

Demucs does not support deleting normalization unconditionally. Its graph
contains 74 `InstanceNormalization` and 26 `LayerNormalization` nodes and is
still aggressively fused. The immediate Kokoro target is therefore to remove
AdaIN as a runtime framework abstraction while retaining its stock equation:

`y = G_v * ((x - mean(x)) / sqrt(var(x) + epsilon)) + B_v`

For a fixed admitted voice row, SMA can precompute the style projection into
voice-specific `G_v` and `B_v` constants, remove the runtime style projection,
and fuse the full-span reductions, normalization, affine, and any algebraically
legal neighboring work into emitted kernels. The input-dependent mean and
variance remain part of the exact baseline.

Replacing those live statistics with dictionary- or state-predicted values is
a separate, intentionally non-stock model variant. It must not be described as
equivalent merely because its state mutation is inexpensive.

## First discriminating smoke test

Use one already admitted decoder AdaIN block, one voice row, and a bounded
pinned input fixture.

1. Compute the existing FP32 stock oracle result.
2. Precompute that voice row's style projection into `G_v` and `B_v`.
3. Run the same block with fixed `G_v` and `B_v` while preserving the exact
   full-span mean and variance. This must meet the existing numerical gate.
4. Lower the reductions, normalization, affine, Snake, and next legal
   convolution region as one directly emitted Hexagon kernel. Compare the
   same input and weights before promotion.
5. Add a typed dictionary/state delta only to `G_v` and `B_v`; measure the
   tensor delta and audible effect as a non-stock conditioning experiment.
6. In a separate experiment, substitute predicted mean and variance. Compare
   against the exact fused baseline. Reject or version the variant if it fails
   the declared tensor and audio gates.

This sequence separates the proven optimization from the model change. It can
show whether state mutation is useful without contaminating the stock Kokoro
baseline or requiring a complete scalar phoneme-to-PCM run.

## Source locations

- `python/export_demucs_v4_pytorch_onnx.py` and `src/Program.cs` at the pinned
  Demucs revision.
- `src/demucs_v4_trt.cpp` and `trtexec_benchmark_sm86.txt` at the pinned Demucs
  revision.
- `ROADMAP.md` lines 150-205, 300-333, and 404-440 for the current Kokoro
  oracle, lowering, and full-span AdaIN gates.
