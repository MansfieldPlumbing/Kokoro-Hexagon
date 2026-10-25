# Decoder and whole generator in one DSP job on SM8550, 2026-10-09

Stock decoder front, then the whole generator with its harmonic source and STFT, in one DSP job: captured `asr`,
`F0_curve`, `N_curve` (decoder) and f0 plus SineGen's noise draws (source) to PCM. hexgrad/kokoro
`dfb907a02bba8152ca444717ca5d78747ccb4bec`; hello world (af_heart, seed 17), 1.625 s of audio.

- Job: `Kokoro.Generator60x16Run.ps1 -Whole -Source -Decoder` (emitter kernel `KokoroDecoderGenerator16Run`), skel SHA-256
  `DF755C418441D5A351F4984A902CD4AA97D9EB20979D1391EB579B9DB7709DE8` (2,032,812 code bytes); instruction bytes match SDK 6.4.0.2
  `hexagon-llvm-mc`. Without `-Decoder` the same emitter still produces the whole-generator skel `D4B6A4B1...` of
  `generator-whole-source-sm8550-20261008.md`, byte for byte.
- Fixture: `tools/New-KokoroGeneratorWholeFixture.ps1 -SourceFixture ... -DecoderFixture build/decoder16-fixture-20261009m4d`
  (the generator parts of the 2026-10-08 whole-source fixture, the decoder fixture of `decoder-sm8550-20261009.md`).
- VTCM 7,634,944 bytes (the decoder's layout); weights 69,683,200 bytes, of which the decoder's W8 are 31,688,704.

## SM8550

| | |
| --- | --- |
| Runs | 3/3 passed, PCM identical (SHA-256 `69F79772...`) |
| PCM against stock float | 31.99 dB, max abs error 0.029, 0 clipped samples (`tools/Measure-KokoroPcmSnr.ps1`) |
| DSP time | median 106.756 ms (2,049,710 ticks at 19.2 MHz); 139-170 ms per invoke with dispatch |
| Real-time factor of the DSP part | 0.066 (106.8 ms for 1.625 s) |
| Played | yes, through AAudio, 39,000 frames, no underruns |

Reference points: the generator alone from captured decoder output reached 37.24 dB in 95.57 ms (stock against itself
with only the source in float64: 40.83 dB). The decoder adds 11.2 ms here (14.4 ms alone) and its 41.5 dB output error
costs about 5 dB at the PCM. Not yet measured: the predictors, text encoder and ALBERT on the DSP; speed work on the
decoder (one HVX thread, weight DMA not overlapped); SM8635.

Known boundary issue: the generator's input scales (calibrated on two generator sentences) clip the stock decoder output on
19 values of the decoder calibration sentences and 1 of hello world; recalibrating that boundary needs the generator's SNR
measured again.
