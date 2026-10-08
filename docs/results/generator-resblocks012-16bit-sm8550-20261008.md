# Generator resblocks.0-2 at 16 bits (256 channels) on SM8550 — 2026-10-08

Stock Kokoro `dfb907a02bba8152ca444717ca5d78747ccb4bec` `generator.resblocks[0..2]` (AdaINResBlock1, 256 channels,
kernels 3, 7, 11) and their mean, hello-world sentence (af_heart, seed 17, 1,300 frames), from the captured
resblocks.0 input. `Kokoro.Generator60x16Run.ps1 -Channels 256` (layout, records and tile strides scaled with the
channel count; the 128-channel skels are byte-identical) under the generic tail harness; fixture
`tools/New-KokoroGenerator60x16Fixture.ps1 -Blocks 0,1,2` (now channel-count general; calibrated on two other
sentences); stage dumps scored with `tools/Test-KokoroStage16Dump.ps1`.

Two faults found on the phone:
- `Kokoro.PlaneCombine.ps1` residual mode at eight blocks overlapped its ratio vectors (v20+b) with the group 3 shift
  vectors (v16+b) and setup temporaries: stage 0 scored 68.06 dB, stage 1 5.77 dB with blocks 6-7 correct. Eight-block
  residual combines now keep ratios in v16..v23 and shifts in v8..v15.
- resblocks.1 stage 5 channel 78: a conv2 output peaks beyond the residual stream it is added to; the residual scale
  now also covers conv2 output peaks (2 channels raised), within the turns-gain bound.

Skel SHA-256 `55595802A9E38C0A6554AE233A996DB4E60EE41F923F4D483D49A3C9C098BC32`; instruction bytes match SDK 6.4.0.2.
Fixture: tables.bin 553B66E25E10C68C; weights.bin 24A1FFCF53BD723A.

| Blocks | SNR vs stock (mean) | Max abs error | DSP region median (3 runs, identical) | Per audio second |
| --- | ---: | ---: | ---: | ---: |
| resblocks.0-2 + mean, 256 ch | **64.14 dB** | 0.0218 | **23.24 ms** | 14.3 ms |