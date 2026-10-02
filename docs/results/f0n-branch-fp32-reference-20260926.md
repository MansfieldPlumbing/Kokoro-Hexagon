# F0/N bounded FP32 reference, 2026-09-26

The PowerShell reference now implements the stock `ProsodyPredictor.F0Ntrain`
topology from aligned 640-channel predictor features: a bidirectional shared
LSTM, separate three-block F0 and N AdaIN residual heads, and separate
one-channel projections. The middle block in each head uses a depthwise
weight-normalized transposed convolution on the residual path, nearest-neighbor
upsampling on the shortcut, and a learned 1x1 channel projection. This is a
bounded correctness reference, not a lowered device implementation or audio.

Source identity: Kokoro `dfb907a02bba8152ca444717ca5d78747ccb4bec`,
`kokoro/modules.py` (`ProsodyPredictor`) and `kokoro/istftnet.py`
(`AdainResBlk1d`, `UpSample1d`); PyTorch
`2b3ec34829036a65cd9d1398ea72a0167dc37470`,
`torch/nn/modules/rnn.py` (LSTM gates) and
`torch/nn/utils/parametrizations.py` (weight normalization).

Executable gates:

- `pwsh -NoProfile -File tools/Test-KokoroDepthwiseTransposeConv1d.ps1` —
  analytic stride/padding/output-length check: pass.
- `pwsh -NoProfile -File tools/Test-KokoroF0NAdaInResBlock.ps1
  -CheckpointPath <pinned checkpoint>` — analytic equal-channel,
  upsample, and channel-changing shortcuts plus stock-weight shape/finite
  gates for F0 blocks 0 and 1: pass.
- `pwsh -NoProfile -File tools/Test-KokoroF0NBranch.ps1
  -CheckpointPath <pinned checkpoint>` — digest-verified stock tensors and
  two-frame F0/N output shape/finite gate: pass.

The stock checkpoint was read by the repository's PowerShell checkpoint
reader; no Python, QNN, ONNX, or external model runtime was used. These gates
do not establish numerical parity with an independent model execution, full
utterance length support, the preceding duration connection, decoder output,
PCM, or audible speech. No speaker test was claimed.
