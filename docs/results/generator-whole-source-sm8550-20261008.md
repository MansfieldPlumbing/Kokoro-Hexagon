# Whole generator with the harmonic source in one DSP job, SM8550, 2026-10-08

Stock Kokoro `dfb907a02bba8152ca444717ca5d78747ccb4bec` istftnet.py Generator.forward, from the captured decoder output
(512 x 130), the frame-rate f0 (130 frames) and SineGen's noise draws (as z = sum_h w_h g_h) to PCM, hello-world sentence
(af_heart, seed 17, 1.625 s), one job: `Kokoro.Generator60x16Run.ps1 -Whole -Source` (kernel `KokoroGeneratorWholeSource16Run`):
the harmonic source and STFT (`Kokoro.HarmonicSource16Run.ps1`) write har's 60x planes to the DDR workspace, a scalar gather
(`Kokoro.HarPhaseMajor16.ps1`) writes the 10x front's phase-major planes, then the 10x half, the 60x half and the tail as in
`generator-whole-sm8550-20261008.md`, both fronts reading har from the workspace. Nothing between the decoder output and PCM
comes from a capture. Fixture `tools/New-KokoroGeneratorWholeFixture.ps1 -SourceFixture`.

Skel SHA-256 `D4B6A4B1FAF7E9617240D997E6156FE66CF7DA194B94ACD12A29BE68E299A645` (1,980,060 code bytes); instruction bytes match
SDK 6.4.0.2 `hexagon-llvm-mc`. The whole-generator kernel without the source still emits its earlier skel (`6D52191A...`).

## Result (3 runs, identical PCM, played through AAudio, XRunCount 0)

| Job | PCM SNR vs stock | Max abs error | DSP region median | Generator RTF |
| --- | ---: | ---: | ---: | ---: |
| Whole generator, captured har (`generator-whole-sm8550-20261008.md`) | 42.05 dB | 0.0139 | 79.71 ms | 0.049 |
| **Whole generator with the harmonic source** | **37.24 dB** | 0.0137 | **95.57 ms** | **0.059** |

PCM SHA-256 `6C00B06163F2F40F9CD4C33FAB2BAEBC489E56705A3992BF0D60FCE02162FC4A`.

## Where the 4.8 dB goes

Stock against itself: the stock generator with only m_source evaluated in float64 (same captured inputs, SineGen's random draws
replayed, PyTorch 2.14.0, stock modules only) agrees with the stock float32 PCM at **40.83 dB** (max 0.0061). Stock's own float32
phase rounding in the source (about 0.002 rad at the ninth harmonic) reaches the PCM through the phase of near-zero STFT bins,
which noise_convs weights regardless of magnitude. That floor and the generator's own 42.05 dB combine to about 38.4 dB; the
measured 37.24 dB is within about 1 dB of it. Matching stock more closely here means matching its float32 rounding, not the math.

The extra 15.86 ms is mostly the scalar phase-major gather (about 1M scalar instructions) and the source's scalar phase stage;
both are to move to HVX.
