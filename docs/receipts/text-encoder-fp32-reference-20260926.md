# Text encoder FP32 reference, 2026-09-26

`Invoke-KokoroTextEncoder.ps1` implements the stock batch-one `TextEncoder`
from `kokoro/modules.py` at `dfb907a02bba8152ca444717ca5d78747ccb4bec`:
token embedding, three channel-first weight-normalized Conv1D blocks with
channel LayerNorm and LeakyReLU (slope 0.2), followed by a bidirectional
LSTM. Dropout is inactive in eval mode. The model-neutral convolution uses
PyTorch's pinned weight-normalization contract at
`2b3ec34829036a65cd9d1398ea72a0167dc37470`.

`Test-KokoroWeightNormConv1d.ps1` passes an analytic center-tap test and
matches the pre-existing AdaIN-specific convolution reference.
`Test-KokoroTextEncoder.ps1` passes a bounded analytic composition and a
two-token stock-weight shape/finite gate after verifying the pinned
checkpoint. The output layout is channel-first `[512, tokens]`, ready for
the already-gated frame-to-token gather when the full branches are joined.

This does not establish full-length numerical parity, text-to-phoneme
admission, F0/N, decoder execution, PCM, or audible speech.
