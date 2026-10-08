# Harmonic-source STFT on the DSP, SM8550, 2026-10-08

Stock Kokoro `dfb907a02bba8152ca444717ca5d78747ccb4bec` istftnet.py: har = [|X|, angle(X)] of TorchSTFT.transform (n_fft 20,
hop 5, periodic Hann, centre with reflect padding) of the merged harmonic source, hello-world sentence (af_heart, seed 17,
39,000 samples, 7,801 frames), from the captured merged source (m_source output 0, int16 in the merge unit) to har's two
byte planes in the 60x front's layout, one DSP job (`Kokoro.HarmonicStft16Run.ps1`, kernel `KokoroHarmonicStft16Run`):

- frame windows on HVX (`Kokoro.StftWindow16.ps1`: unaligned rows by `valign`, row pairs by `vshuff` Rt = -2; semantics from
  the HVX PRM pseudo-code, V75 HTML in SDK 6.4.0.2, confirmed on V73 by this run),
- the STFT as one HMX plane conv (64 -> 64, centre tap; Re_k and Im_k share one unit per bin) and the 64-channel combine,
- magnitude and angle by CORDIC on HVX (`Kokoro.StftPolar16.ps1`, 16 iterations, shifts and adds only; x < 0 rotated by
  +-pi so Im = 0, Re < 0 gives +pi as torch.angle of a +0 imaginary part).

Fixture `tools/New-KokoroHarmonicStft16Fixture.ps1` (har scales computed as the 60x front fixture computes them, on two other
sentences); the folded STFT reproduces stock har at 92.14 dB magnitude, 2.0e-5 rad phase (build-time check). Stock source
internals come from a new capture (`tools/reference/capture_stock_generator.py` now records SineGen's random draws); its 636
earlier tensors are bit-identical to the 2026-10-06 capture.

Skel SHA-256 `F2BD728EEE810BDBC18AE570C026D5B3A13C9928A7ED54195A8ADD9FF96F4660` (17,792 code bytes); instruction bytes match
SDK 6.4.0.2 `hexagon-llvm-mc`. Scored by `tools/Test-KokoroHarOutput.ps1`.

| | Result |
| --- | ---: |
| har magnitude vs stock | **79.02 dB** |
| har phase vs stock (magnitude-weighted rms) | **8.4e-5 rad** (one phase LSB is 1.2e-4 rad) |
| values across the +-pi cut | 8 of 85,811 |
| DSP region median (3 runs, identical output) | **3.29 ms** |
| halfwords equal to the 60x fixture's har planes / within 2 LSB | 36.5% / 87.8% |

Faults found while building: two PowerShell case-folding collisions (`$I` / `$i` left the CORDIC loop empty, `$sh` / `$sH` in the
fixture), caught by the first run (5.83 dB) and a probe of per-frame values; an AST check for case-only name pairs now runs
over the new files. `valign`'s scalar must be r0..r7 (the emitter rejects others).

Next: har's phase-major layout for the 10x front, the source itself (f0 -> merged source) on the DSP, and both in the whole
generator job.
