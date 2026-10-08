# 16-bit generator stage and tail in one DSP job, SM8550 — 2026-10-08

Stock Kokoro `dfb907a02bba8152ca444717ca5d78747ccb4bec` resblocks.3-5, their mean, and the tail (LeakyReLU, conv_post,
exp/sin, iSTFT), from the captured resblocks.3 input of the hello-world sentence (af_heart, seed 17, 7,801 frames,
1.625 s) to PCM. `Kokoro.Generator60x16Run.ps1 -Tail`: the stage as in `generator60x-16bit-holdout-sm8550-20261008.md`
(holdout scales), then `Add-KokoroGeneratorTail16JobSteps` (`Kokoro.GeneratorTail16Run.ps1`) reading the final tensor
from the DDR workspace. Fixture `tools/New-KokoroGeneratorStageTailFixture.ps1` (holdout stage + tail fixtures).
Played through AAudio by `src/runspace/KokoroGeneratorTailProbe.ps1`.

Skel SHA-256 `7D1FD0957E2DA2083CABFCC6ECC5F8DC648E07467D44334E6CD952DF2EFB0117`; instruction bytes match SDK 6.4.0.2
`hexagon-llvm-mc`. The refactored standalone tail and the stage without `-Tail` emit byte-identical skels
(`2503BEAA…`, `3697161D…`). Fixture: activations.bin 921C991011C3DF33; expected-pcm-f32.bin 8B8B478B59D2A21D; tables.bin A431D27AD11B0E5C; weights.bin E88B947F4C6CF3BD.

## Result (3 runs, identical PCM, XRunCount 0)

| Job | PCM SNR vs stock | Max abs error | DSP region median |
| --- | ---: | ---: | ---: |
| Tail alone (stock stage output) | 38.07 dB | 0.0147 | 2.97 ms |
| **Stage + tail** | **37.67 dB** | 0.0164 | **32.90 ms** |

PCM SHA-256 `0370FD0C8F4D415435711ADC2990FD0A17D66AB8C3485FBFA7A3ED1F7EEF3682`. 32.90 ms for 1.625 s of audio
(real-time factor 0.020 for this part of the generator). The tail is the precision limit, not the stage.