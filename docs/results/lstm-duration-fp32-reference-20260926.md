# LSTM and duration FP32 references, 2026-09-26

`Invoke-KokoroBidirectionalLstm.ps1` implements one batch-one, single-layer
bidirectional LSTM with PyTorch's `i, f, g, o` gate order, independent forward
and reverse state, zero initial state, and concatenated output. Its behavior
follows `torch/nn/modules/rnn.py` at
`2b3ec34829036a65cd9d1398ea72a0167dc37470` and Kokoro's usage in
`kokoro/modules.py` at `dfb907a02bba8152ca444717ca5d78747ccb4bec`.
The reference is bounded and written in PowerShell; it is not a device
implementation.

`Invoke-KokoroDurationPrediction.ps1` connects the stock 512-to-50 duration
projection to `New-KokoroDurationMap.ps1`, which performs sigmoid, bin sum,
speed division, rounding, minimum-one clamp, and frame-to-token expansion as
specified by pinned `kokoro/model.py`. This consumes an LSTM output; it does
not yet compute the style-conditioned duration encoder that feeds the LSTM.

The pinned checkpoint digest was verified before tensor reads. Executable
gates `Test-KokoroBidirectionalLstm.ps1`,
`Test-KokoroDurationPrediction.ps1`, and `Test-KokoroDurationMap.ps1` pass
analytic cases, stock tensor shapes, and finite stock-weight output. These
tests are not an independent stock numerical differential, a full duration
prediction from phonemes, or a PCM/speaker result.
