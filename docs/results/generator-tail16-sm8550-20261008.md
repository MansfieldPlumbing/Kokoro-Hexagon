# 16-bit generator tail on SM8550 — 2026-10-08

Stock Kokoro `dfb907a02bba8152ca444717ca5d78747ccb4bec` LeakyReLU, conv_post, exp/sin and iSTFT
(`istftnet.py` Generator.forward, TorchSTFT.inverse), hello-world sentence (af_heart, seed 17, 7,801 frames,
39,000 samples). Input: the stock resblocks.3-5 mean quantized at the 16-bit stage's residual scales (holdout
stage fixture). Emitter `src/emit/Kokoro.GeneratorTail16Run.ps1`; fixture `tools/New-KokoroGeneratorTail16Fixture.ps1`
(conv_post and spectrum scales calibrated on two other sentences); score `tools/Measure-KokoroPcmSnr.ps1`.

Design:
- LeakyReLU on the integers (`Kokoro.LeakyRelu16.ps1`); the per-channel residual scale folds into conv_post's weights.
- conv_post as a three-group HMX plane conv, 128 -> 64, with magnitude bin k at channel k and phase bin k at 32 + k.
- `Kokoro.TailSpectrum16.ps1`: exp via 2^frac polynomial and a per-lane `vasr(Vu.w,Vv.w)` exponent shift; sin, then
  cos/sin of it, by polynomials; 16-bit Re/Im at one scale.
- The iSTFT (irfft, Hann window, overlap-add, 1/1.5) folded into one HMX conv, 64 -> 5 samples per frame, 4 taps,
  output units 2^-15 (PCM int16 directly); scalar gains on the first and last five samples. From stock float logits
  the folded form gives 124.41 dB against stock PCM (fixture check).

Skel SHA-256 `2503BEAADFFA9E7691DD290B505A4BBC91BF5B438742D2B36B6A1DA4AB21D805`; instruction bytes match SDK 6.4.0.2
`hexagon-llvm-mc` (new forms `vasr/vlsr/vasl(Vu.w,Vv.w)`, `vasr(Vu.h,Vv.h)`, `vmin/vmax(Vu.h,Vv.h)`: 192/192 encoder
cases). New forms were not run in the V73 simulator; the phone result against stock covers them.
Fixture `tables.bin` `199364EB7604FEA9…`, `weights.bin` `551D866D6DBC4879…`.

## Result (3 runs, identical PCM, played through AAudio, XRunCount 0)

| Tail | PCM SNR vs stock | Max abs error | DSP region median |
| --- | ---: | ---: | ---: |
| 8-bit tail (`tail-quantization-boundaries-20261007.md`) | about 10 dB | | 27.45 ms |
| **16-bit tail** | **38.07 dB** | 0.0147 | **2.97 ms** |

PCM SHA-256 `45B341DA421CD9255E333EEBAA1048C401A9ADB53F478ED16059A640F7BD1B94`. Heard on the phone speaker as
"hello world".

Fault found on the phone: the first run scored 11.08 dB with one click at frame 2126, the sentence's largest
magnitude logit (3.0096, just above the calibrated range): the clamped exponent put the 2^f polynomial's inner
sum at 1.0 = 32768 in Q15, which wrapped. The Horner adds now saturate.
