# Whole generator in one DSP job, SM8550, 2026-10-08

Stock Kokoro `dfb907a02bba8152ca444717ca5d78747ccb4bec` istftnet.py Generator.forward from the captured decoder output
(generator input, 512 x 130) and har (STFT of the stock harmonic source) to PCM, hello-world sentence (af_heart,
seed 17, 1.625 s), in one job: the 10x section (LeakyReLU(0.1), ups[0], noise_convs[0], noise_res[0], add,
resblocks.0-2 and mean at 256 channels), then LeakyReLU(0.1) of the 10x mean straight into the ups[1] input planes in
VTCM, the 60x section (noise_convs[1], noise_res[1], ups[1], reflection pad, add, resblocks.3-5 and mean at 128
channels) and the tail (LeakyReLU, conv_post, exp/sin, iSTFT). Nothing between decoder output and PCM comes from a
capture except har.

`Kokoro.Generator60x16Run.ps1 -Whole` (kernel `KokoroGeneratorWhole16Run`): the two sections are bound in turn, each
with its own inputs, weights, records and DDR workspace placed after the previous one's, bodies emitted per section
(labels suffixed `_c256` / `_c128`), one HVX worker pool, VTCM shared (the larger section's 7,208,960 B). Fixture
`tools/New-KokoroGeneratorWholeFixture.ps1` from the 10x fixture and a 60x front fixture built with
`-UpInputScaleFixture` (ups[1] takes the 10x stage's output scales, since LeakyReLU keeps each channel's scale);
all scales calibrated on two other sentences.

Skel SHA-256 `6D52191A46DB3033DAE321E43E5410B0C2524E37FD25CBFD075A61A1EF6EC647` (1,956,376 code bytes); instruction
bytes match SDK 6.4.0.2 `hexagon-llvm-mc`. The six earlier kernels built by the same emitter (front + stage + tail,
10x half, stage + tail, two resblock jobs, 60x stage) emit byte-identical skels after the change.
Fixture: activations.bin BD5E3790D6F246AA; weights.bin AAD3FA75CE084349; tables.bin 537D4EA9534125EE;
expected-pcm-f32.bin 8B8B478B59D2A21D.

## Result (3 runs, identical PCM, played through AAudio, XRunCount 0)

| Job | PCM SNR vs stock | Max abs error | DSP region median | Per audio second |
| --- | ---: | ---: | ---: | ---: |
| 10x half alone (receipt `generator-10x-half-sm8550-20261008.md`) | (58.56 dB at the 10x mean) | | 31.67 ms | |
| 60x half + tail alone, from captured ups[1] input | 42.71 dB | 0.0141 | 46.48 ms | 28.6 ms |
| **Whole generator, from captured decoder output and har** | **42.05 dB** | 0.0139 | **79.71 ms** | **49.1 ms** |

PCM SHA-256 `3EB9C3EBC36D3A7AE06818479C77C55B907E7D28C200CE7810E9CC7DB0FB0F76`. Generator RTF on SM8550: 0.049.

Fault found while building: the admission wrapper bakes its config tile count from the frames it is built with
(`Kokoro.ResBlockRun.ps1:152`); built with the 10x section's frames it rejected the job (AEE_EBADPARM). It is now
built with the last section's frames, which single-section kernels already used.

Still not on the DSP: the harmonic source and its STFT (har), and everything before the generator.
