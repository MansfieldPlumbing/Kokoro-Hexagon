# Connected acoustic branches, 2026-09-26

`Invoke-KokoroAcousticBranches.ps1` now carries one admitted token sequence
through the bounded PowerShell ALBERT reference, the stock 768-to-512
projection, the style-conditioned duration branch, and a single alignment
map. The same token IDs enter the stock text encoder; its channels are
gathered by that map. The aligned duration features enter the F0/N branch.
The 256-element voice row is split exactly as in Kokoro's
`forward_with_tokens`: first 128 elements for decoder style, last 128 for
duration and F0/N style.

Source identity: Kokoro `dfb907a02bba8152ca444717ca5d78747ccb4bec`,
`kokoro/model.py` (`KModel.forward_with_tokens`) and `kokoro/modules.py`
(`ProsodyPredictor`, `TextEncoder`, `DurationEncoder`). The ALBERT reference
also traces Transformers `8ac2b916b042b1f78b75c9eb941c0f5d2cdd8e10`.

Gate: `pwsh -NoProfile -File tools/Test-KokoroAcousticBranches.ps1
-CheckpointPath <pinned checkpoint>` passed using the digest-verified stock
checkpoint. The gate used three boundary-delimited tokens, speed 100 to keep
the scalar duration within its bound, one ALBERT repeat, and one layer in
each configurable encoder. It checked a one-frame-per-token map, style-half
selection, aligned text dimensions, doubled F0/N time dimension, and finite
values. The complete component gates were also executed in the test.

This is a structural and finite-output gate, not an independent numerical
differential of the connected model. It does not establish normal-speed or
full-utterance execution, decoder synthesis, PCM, audible speech, or device
performance. No Python, QNN, ONNX, or external model runtime ran in the gate.
