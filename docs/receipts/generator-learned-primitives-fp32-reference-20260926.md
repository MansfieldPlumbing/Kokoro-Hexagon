# Learned generator primitives, 2026-09-26

The repository's existing bounded PowerShell FP32 `AdaINResBlock1`
reference (three AdaIN/Snake/dilated-convolution residual pairs) remains
unchanged. This milestone adds weight-normalized transposed convolution for
both generator upsamplers and ordinary strided convolution for the two
source-spectrum injections. These are separate verified primitives; the
complete learned generator is not yet composed or numerically gated.

Source identity: Kokoro `dfb907a02bba8152ca444717ca5d78747ccb4bec`,
`kokoro/istftnet.py` (`AdaINResBlock1`, `Generator`), and pinned PyTorch
`2b3ec34829036a65cd9d1398ea72a0167dc37470` for transposed-convolution
weight layout and weight normalization.

Executable gates (the new upsampler and noise-convolution gates verify the
stock checkpoint digest):

- `pwsh -NoProfile -File tools/Test-KokoroAdaInResBlock1.ps1`:
  existing independent analytic three-pass composition and missing-parameter
  rejection — pass. This is not a stock-weight numerical gate.
- `pwsh -NoProfile -File tools/Test-KokoroWeightNormTransposeConv1d.ps1
  -CheckpointPath <pinned checkpoint>`: analytic scatter/stride and both
  stock upsamplers, producing 20 and 120 frames — pass.
- `pwsh -NoProfile -File tools/Test-KokoroNoiseConv1d.ps1
  -CheckpointPath <pinned checkpoint>`: analytic stride/padding and both
  stock spectrum convolutions, producing 20 and 121 frames — pass.

The second spectrum path has 121 frames because centered STFT includes its
edge frame; the learned feature path has 120 frames and the stock generator
reflection-pads one frame before adding the source path. The frame count is
verified, but the addition and subsequent residual stack are not yet gated.
No independent PyTorch numerical differential, full-generator run, PCM, or
speaker output is claimed.
