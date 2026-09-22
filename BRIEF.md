# Kokoro-QNN — review brief

Status as of 2026-09-22. This brief is for external review. Evidence lives in
`docs/` (`FIRST-LIGHT.md`, `DESIGN.md`, `SCOREBOARD.md`) and in the source.

## Goal

Run all of Kokoro-82M (text-to-speech) on the Qualcomm Hexagon NPU (HTP),
driven through the QNN C API directly (no ONNX Runtime on the device), faster
and smaller than the current published reference, and release the result on
Hugging Face under Apache-2.0.

Reference to beat: kokoro-offline-tts-android v1.30 on an S24 Ultra (SM8650,
Hexagon V75, fp16, ONNX Runtime + QNN EP): generator RTF 0.29 mean, first PCM
~950 ms p50, ~1.4 GB APK, energy not measured. Our target device is one
generation older: Galaxy S23 (SM8550, Hexagon V73).

## Where it stands

- **First light (device receipt).** The whole Kokoro decoder, including the
  iSTFT, runs on HTP from a PowerShell runspace inside an Android app, and the
  phone plays the audio. Audio SNR is 24.0 dB against the full-length PyTorch
  decoder, equal to the fp32 CPU run of the same design (24.2 dB), so HTP adds
  no measurable error.
- **Speed.** Generator 4.69 s → 1.373 s warm mean over 20 runs for a 3.27 s phrase (RTF 0.419, fp16),
  from a burst performance vote, 8 MB VTCM, the iSTFT in the graph, native
  InstanceNorm and precomputed per-voice gamma/beta.
- **Still on the host CPU:** text → phonemes, ALBERT, the text encoder,
  duration/F0/N prediction, the harmonic source (`SineGen`), and the forward
  STFT of the harmonic source.

## Design decisions and their evidence

1. **Static capacity with length-masked normalization, not sliding windows.**
   Kokoro's `AdaIN1d` normalizes over the whole utterance, so 64-frame windows
   (the Piper/Melo pattern) score 5 dB; one masked window per phrase scores
   24.2 dB against full length.
2. **Random ops leave the graph.** `SineGen`'s noise and phase run on the host
   and enter as an input.
3. **QNN pass pipeline**, each pass checked for exactness in fp32, plus a gate
   (static shapes, device-proven op allowlist):
   - `Pow(x,2)` → `Mul(x,x)`: `Pow` computes wrong on HTP V73 (layer probe:
     variance −10 dB vs 61 dB with `Mul`).
   - Depthwise `ConvTranspose1d` → polyphase and `Resize` → expand/reshape:
     the upsampling block broke on HTP (3.7 dB → 58.5 dB).
   - fp16-safe variance, time lengths padded to a multiple of 8 (length
     19,201 fails finalize), stage masks as inputs, shape-plumbing fold
     (3,098 → 1,674 nodes, bit-exact).
4. **Measured bottleneck: elementwise volume, not convolutions.** A QNN graph
   dump shows ~1,100 elementwise ops against 51 convs; quantizing only the
   convs to int16 gave no speedup. The last generator stage works on
   128 × 19,200 tensors (4.9 MB fp16 each), larger than default VTCM.
5. **QNN cannot quantize the elementwise chain.** A bisect shows convs and
   InstanceNorm compile in int16; adding quantized `Mul/Add/Sub/Div` crashes
   `HtpPrepare` (access violation). Per-op int8 costs 12.5 dB log-mel; per-op
   int16 2.28 dB.

## Planned architecture: fused table-lookup kernel

A custom HVX/HMX kernel (Hexagon SDK 6.4.0.2, toolchain 19.0.02, HexKL) that
replaces each resblock's norm + Snake + conv chain:

1. Stats pass (read-only, streaming): per-channel sums → 128 `rsqrt`s.
2. Per-channel 256-entry table implementing masked norm + Snake (32 KB per
   block, resident in VTCM). For int16 storage, index by the high 8 bits and
   interpolate with the low 8 bits.
3. int8 weights on HMX, int16 activations as two int8 limbs, exact int32
   accumulation, one requantization per block.
4. Zero-copy shared memory (DMA-BUF registered with QNN), double-buffered
   between CPU and HTP with completion fences.

CPU emulation of this design against float:

| Scheme | Log-mel error | Waveform SNR |
| --- | --- | --- |
| Per-op int8 (QNN QDQ) | 12.5 dB | 7.0 dB |
| Per-op int16 (QNN QDQ) | 2.28 dB | 24.1 dB |
| Fused int8 tables | 1.48 dB | 24.3 dB |
| Fused int16 | 0.20 dB | 40.4 dB |

Weights: layer-wise post-training rounding (GPTQ-style) plus bias correction,
no end-to-end training; quantization knobs (clip ranges, limb counts, wider
layers) chosen by a hill climber scored on the device.

## Questions for reviewers

1. **Kernel integration:** is a QNN custom op package the right way to run
   the fused kernel inside the same context as QNN's convolutions, or is a
   separate FastRPC call between two QNN graphs simpler and fast enough on V73?
2. **VTCM planning:** with 8 MB on V73, is keeping ~640 KB of tables resident
   while QNN's own convolutions also use VTCM realistic, or will QNN's
   allocator contend with a custom kernel? Is VTCM sharing needed?
3. **Norm barrier:** is there a better exact formulation of per-utterance
   InstanceNorm for streaming than a separate statistics pass per norm?
4. **Numerics:** any known HTP V73 lowering problems beyond `Pow`, depthwise
   `ConvTranspose`, `Resize` and odd lengths that the gate should ban?
5. **Quantized finalize crash:** has anyone seen `HtpPrepare` (QAIRT 2.46)
   crash on quantized elementwise ops, and is there a known workaround or a
   configuration that avoids it?
6. **Front end on HTP:** for the BiLSTM duration predictor at a static token
   capacity, is unrolling over time the recommended approach on HTP, or does
   QNN's native LSTM op handle masked sequences well?
7. **Anything we are measuring wrongly:** the quality metric is SNR and
   log-mel error against the float model plus listening; the speed metric is
   graphExecute wall time with a burst vote. What should be added?

## Layout

```
lib/manifest.json   pinned inputs (SHA-256)
src/export/         host-side export, passes, gate, compile, quantization
src/runspace/       device-side PowerShell (QNN ABI, context loading, runner)
tools/              host drivers (context metadata, device jobs, speak)
docs/               design, first light, scoreboard
```
