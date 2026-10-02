# Learned generator composition, 2026-09-27

`src/models/Invoke-KokoroLearnedGenerator.ps1` composes the configured
two-stage `Generator.forward` after the harmonic STFT. Its input contract is
batch-one decoder features, the 22-channel harmonic spectrum, style, and
named weight vectors. `Invoke-KokoroGenerator.ps1` connects the F0-driven
harmonic prelude to this learned stage. It applies leaky ReLU, the 10x and 6x weight-normalized
transposed convolutions, source convolutions and AdaIN residual blocks, the
left reflection pad on stage two, three parallel AdaIN residual blocks per
stage, their average, post projection, and the existing 20/5 inverse-STFT
PCM head. Parameter names follow the stock checkpoint's generator suffixes.

Source identity: Kokoro `dfb907a02bba8152ca444717ca5d78747ccb4bec`,
`kokoro/istftnet.py` (`Generator.__init__` and `Generator.forward`), and
`lib/kokoro-v1_0.config.json`. Each primitive retains its own source and
shape gate. This composition contains no QNN, Python, ONNX, LLVM, or Roslyn
execution path.

Executable gate:

```powershell
pwsh -NoProfile -File tools/Test-KokoroLearnedGenerator.ps1
```

Result: pass. The gate exercises both stages with bounded synthetic tensors,
zero and nonzero projection paths, 61 spectral frames and 300 PCM samples
from one input frame, a deterministic two-F0-frame harmonic-source-to-PCM
path with 600 samples, finite PCM, and rejection of an absent required weight.
The same gate with `-CheckpointPath build/cache/kokoro-v1_0.pth` also passes:
the checkpoint matches the pinned length and SHA-256, and all 303 declared
generator tensors satisfy exact shape, FP32 dtype, contiguous stride, and
finite-value checks. `Read-KokoroGeneratorWeights.ps1` supplies the named
arrays without a Python or PyTorch runtime.
The existing `Test-KokoroSineSource.ps1`, `Test-KokoroNoiseConv1d.ps1`, and
`Test-KokoroWeightNormTransposeConv1d.ps1` also pass with this verified
checkpoint. The transposed-convolution check is a slow scalar reference,
not a device-performance measurement.

It does not compare numerical output against a stock-weight oracle, connect
the acoustic branches to the decoder and generator, measure a normal-length
phrase, run on a phone, or establish audible speech. Those are separate
promotion gates.
