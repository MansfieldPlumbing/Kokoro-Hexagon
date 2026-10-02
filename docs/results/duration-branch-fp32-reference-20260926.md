# Style-conditioned duration branch, 2026-09-26

The PowerShell FP32 reference now composes Kokoro's three alternating
bidirectional LSTM and AdaLayerNorm blocks in `DurationEncoder`, a separate
predictor bidirectional LSTM, the 512-to-50 duration projection, and the
frame-to-token gather. It accepts 512-channel token features plus a 128-value
style vector and returns token durations and aligned 640-channel predictor
features. The source contract is pinned `kokoro/modules.py` and
`kokoro/model.py` at `dfb907a02bba8152ca444717ca5d78747ccb4bec`.

`Test-KokoroDurationAdaLayerNorm.ps1` tests normalization and style
re-concatenation. `Test-KokoroDurationEncoder.ps1` exercises the three
stock-weight layers. `Test-KokoroDurationBranch.ps1` exercises an analytic
zero-parameter composition and a two-token composition using the verified
stock checkpoint's encoder, predictor LSTM, and duration-projection weights.
The gate checks shapes, finite output, and bounded alignment; it does not
compare the branch numerically with an independent stock oracle.

This branch starts from supplied token features, not admitted phonemes. A
full ALBERT-to-duration gate, text encoder, F0/N, harmonic source, remaining
decoder, and waveform are still required before PCM or speaker playback.
