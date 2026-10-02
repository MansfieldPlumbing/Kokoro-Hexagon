# Bounded ALBERT FP32 reference, 2026-09-26

The repository now has PowerShell correctness references for the ALBERT input
embedding sum and layer normalization, embedding-to-hidden projection,
multi-head self-attention with key mask and residual normalization, and the
`gelu_new` feed-forward and residual normalization. A composition repeats the
shared ALBERT layer as specified by Kokoro's pinned configuration. A bounded
linear primitive covers the following `bert_encoder` projection. These are
model computations, not Hexagon lowering or live speech.

Behavioral sources: `kokoro/model.py` and `kokoro/modules.py` at
`dfb907a02bba8152ca444717ca5d78747ccb4bec`; Transformers
`models/albert/modeling_albert.py`, `configuration_albert.py`, and
`activations.py` at `8ac2b916b042b1f78b75c9eb941c0f5d2cdd8e10`.
The stock checkpoint was verified against `lib/manifest.json` before
reading tensors. No Python, QNN, ONNX, or C# implementation is involved.

Executable gates:

- `Test-KokoroAlbertEmbeddings.ps1`: analytic embedding and projection
  arithmetic, input bounds, stock tensor shapes, and finite stock output.
- `Test-KokoroAlbertAttention.ps1`: analytic attention, residual norm, key
  mask, stock tensor shapes, and finite stock-weight output.
- `Test-KokoroAlbertFeedForward.ps1`: analytic residual and `gelu_new` branch,
  stock tensor shapes, and finite stock-weight output.
- `Test-KokoroAlbertEncoder.ps1`: repeated-layer composition and one connected
  stock-weight ALBERT layer from token IDs to hidden output.
- `Test-KokoroBertEncoderProjection.ps1`: analytic and stock-weight linear
  projection shape and finite output.

These gates do **not** yet compare full 12-layer ALBERT output numerically
against an independent oracle, nor do they establish practical whole-model
runtime. Duration, text-encoder, F0/N, source, decoder, and final waveform
remain absent from the owned phoneme-to-PCM path. No audible speech claim
follows from this receipt.
