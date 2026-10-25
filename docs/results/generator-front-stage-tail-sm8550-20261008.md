# Generator 60x half and tail in one DSP job, SM8550 — 2026-10-08

Stock Kokoro `dfb907a02bba8152ca444717ca5d78747ccb4bec` istftnet.py Generator.forward from the captured ups[1] input
(leaky output of the 10x half) and har (STFT of the harmonic source) to PCM, hello-world sentence (af_heart, seed 17,
1.625 s): noise_convs[1], noise_res[1], ups[1] (polyphase: three 256-output HMX calls), reflection pad, add,
resblocks.3-5 and their mean, LeakyReLU, conv_post, exp/sin, iSTFT. `Kokoro.Generator60x16Run.ps1 -Front -Tail`
(front bodies `Kokoro.GeneratorFront16.ps1`); fixtures `tools/New-KokoroGeneratorFront16Fixture.ps1` (front),
`-Module noise_res` stage fixture, holdout stage and tail fixtures, joined by
`tools/New-KokoroGeneratorStageTailFixture.ps1`; all scales calibrated on two other sentences.
The polyphase form of ups[1] with the reflection reproduces stock at 130.8 dB from stock floats (build-time check).

Skel SHA-256 `AC284A96BF57B53C291F295024A5A4FFC51560602844D7D69A8B4D9A69D7F810` (1,071,884 code bytes); instruction
bytes match SDK 6.4.0.2 `hexagon-llvm-mc`. VTCM 7,208,960 B. Fixture: activations.bin 4AD5C2BEEA393227; expected-pcm-f32.bin 8B8B478B59D2A21D; tables.bin 9A60D76E5CC12432; weights.bin 5565B6AADE024249.

## Result (3 runs, identical PCM, played through AAudio, XRunCount 0)

| Job | PCM SNR vs stock | Max abs error | DSP region median | Per audio second |
| --- | ---: | ---: | ---: | ---: |
| Stage + tail (from captured resblocks.3 input) | 45.70 dB | 0.0152 | 32.12 ms | 19.8 ms |
| **Front + stage + tail (from captured ups[1] input, har)** | **42.71 dB** | 0.0141 | **46.48 ms** | **28.6 ms** |

PCM SHA-256 `C63BA87047A1AFA3E48B68337245610EAB97D48CD855BE22DE9B8053560A486A`. Not yet on the DSP: the 10x half
(resblocks 0-2, ups[0], noise_convs[0], noise_res[0]), the harmonic source and its STFT, and everything before the
generator.

Fault found while building: the noise_res block (index -1) matched the default `-StopAfterStage -1` at its last
stage and ended the job early; the stop checks now apply to stage blocks only.