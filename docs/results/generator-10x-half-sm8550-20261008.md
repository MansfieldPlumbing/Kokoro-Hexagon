# Generator 10x half in one DSP job, SM8550 — 2026-10-08

Stock Kokoro `dfb907a02bba8152ca444717ca5d78747ccb4bec` istftnet.py Generator.forward, i = 0, from the captured decoder
output (generator input, 512 x 130) and har to the 10x mean (input of the second LeakyReLU), hello-world sentence
(af_heart, seed 17): LeakyReLU(0.1) on the DSP, ups[0] as ten polyphase HMX convs (512 -> 256, frame shifts -1..1) with
an HVX phase-pair interleave, noise_convs[0] as one HMX conv over phase-major har (132 of 256 inputs), noise_res[0],
the add, resblocks.0-2 and their mean (256 channels). `Kokoro.Generator60x16Run.ps1 -Channels 256 -Front`; fixture
`tools/New-KokoroGeneratorFront10x16Fixture.ps1` with the 256-channel stage and noise_res[0] fixtures (scales
calibrated on two other sentences). The polyphase ups[0] and phase-major noise_convs[0] reproduce stock at 131.7 and
133.5 dB from stock floats (build-time check). Har is still the captured STFT of the stock harmonic source.

Skel SHA-256 `9220EDBB0E11F757224F4872DADCE5E2F279DFC4F854F247F805BD749446336F`; instruction bytes match SDK 6.4.0.2
`hexagon-llvm-mc`. Fixture: activations.bin 9ABE633DC7BF1DDC; tables.bin 9553362F3D1895AA; weights.bin E9C1110E84A59DB7.

| Job | SNR vs stock (10x mean) | Max abs error | DSP region median (3 runs, identical) |
| --- | ---: | ---: | ---: |
| **10x half** | **58.56 dB** | 0.0503 | **31.67 ms** |

Fault found while building: a 512-channel tile advance (32 KB) overflowed the conv's addi immediate; it now uses a
register add (other channel counts unchanged, verified by skel SHA-256).