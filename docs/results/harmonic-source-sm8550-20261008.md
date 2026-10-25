# Harmonic source and STFT on the DSP, SM8550, 2026-10-08

Stock Kokoro `dfb907a02bba8152ca444717ca5d78747ccb4bec` istftnet.py SineGen, SourceModuleHnNSF and TorchSTFT.transform, from the
captured frame-rate f0 (130 frames) to har, hello-world sentence (af_heart, seed 17, 39,000 samples, 7,801 frames), one DSP job
(`Kokoro.HarmonicSource16Run.ps1`, kernel `KokoroHarmonicSource16Run`):

- scalar: per-sample phase Psi in Q32 turns from f0 (Q16 Hz), the closed form of SineGen's interpolated cumulative phase
  (`Kokoro.HarmonicSource16.ps1`: P_0 for 150 samples, then per segment P_k + (n + 1/2) f0_(k+1) / 24000, then P_(L-1); a
  sign mask where stock's `% 1` adds half a turn); voiced, sign and noise-amplitude masks per sample;
- HVX, 64 samples per block: the nine harmonics as `vmpyie` phase products (top 16 bits as turns), the tail's sine
  polynomial, sum_h 0.1 w_h sin, voicing, noise (0.003 or 0.1/3 times z = sum_h w_h g_h), bias, tanh as an odd polynomial;
  the merged source in Q15, written with its reflect padding;
- the STFT and CORDIC of `Kokoro.HarmonicStft16Run.ps1` on that signal in VTCM, to har's planes.

The noise draws g are SineGen's own (captured); the product will draw z on the DSP (one Gaussian per sample, the same
distribution). Fixture `tools/New-KokoroHarmonicSource16Fixture.ps1`; its closed form with the job's integer inputs matches
stock's merged source at 61.86 dB (build-time check; the residual is stock's float32 phase rounding).

Skel SHA-256 `AC053525353F63FE56B24EACCCF805D14105A600328C43AE5210D309C644BD30` (20,392 code bytes); instruction bytes match SDK
6.4.0.2 `hexagon-llvm-mc`. Scored by `tools/Test-KokoroHarOutput.ps1`.

| vs stock | Result |
| --- | ---: |
| merged source (m_source output 0) | **60.64 dB** |
| har magnitude | **64.62 dB** |
| har phase (magnitude-weighted rms) | 6.4e-4 rad |
| DSP region median (3 runs, identical output) | **3.95 ms** |

Faults found while building: the noise amplitude in the high halfword came from a signed difference replicated across halves
(odd voiced samples got unvoiced noise; found by a per-harmonic regression of odd versus even samples, fixed with a select);
the window body's row registers overlapped the seventh source vector once the signal moved to a 108-byte offset (30.8 dB; the
STFT-only job isolated it).

Next: har's phase-major layout for the 10x front, and the source as the first section of the whole-generator job.
