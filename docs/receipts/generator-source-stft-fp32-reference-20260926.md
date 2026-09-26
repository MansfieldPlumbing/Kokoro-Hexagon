# Generator source and STFT reference, 2026-09-26

The bounded PowerShell reference now implements Kokoro's nine-harmonic
`SineGen` source, voiced/unvoiced noise amplitudes, learned harmonic merge,
and the configured 20-point, hop-5, centered Hann STFT and iSTFT. Supplied
random draws permit reproducible correctness gates; omitted draws use fresh
uniform and Gaussian samples. The source is not a replacement for the learned
generator and does not independently produce Kokoro speech.

Source identity: Kokoro `dfb907a02bba8152ca444717ca5d78747ccb4bec`,
`kokoro/istftnet.py` (`SineGen`, `SourceModuleHnNSF`, `TorchSTFT`, `Generator`)
and the pinned model config (upsample rates 10 and 6, iSTFT hop 5,
FFT length 20). PyTorch `2b3ec34829036a65cd9d1398ea72a0167dc37470`,
`torch/functional.py` (centered reflect STFT defaults) and
`aten/src/ATen/native/SpectralOps.cpp` (inverse FFT, overlap-add,
window-squared normalization, centered trim).

Executable gates:

- `pwsh -NoProfile -File tools/Test-KokoroStft.ps1`: periodic-Hann DC/bin
  checks and a 40-sample forward/inverse round trip at 147.7 dB SNR — pass.
- `pwsh -NoProfile -File tools/Test-KokoroSineSource.ps1
  -CheckpointPath <pinned checkpoint>`: analytic phase interpolation and
  voicing, digest-verified stock merge weights, deterministic 600-sample
  source, 121-frame spectrum, and source/STFT inverse above 90 dB SNR — pass.

At the configured 300× upsample, the source's random phase added at
full-rate sample zero is discarded by subsequent half-pixel linear
downsampling. The reference retains that source behavior; it does not
substitute a more conventional oscillator phase rule. The current gates do
not establish an independent PyTorch numerical differential, learned
generator output, final model PCM, or audible speech.
