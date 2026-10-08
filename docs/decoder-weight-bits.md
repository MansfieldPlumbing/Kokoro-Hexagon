# Decoder weight bits, 2026-10-08

Stock Kokoro `dfb907a02bba8152ca444717ca5d78747ccb4bec`, hello-world sentence (af_heart, seed 17). The decoder (encode +
four AdainResBlk1d, ~1090 -> 1024 channels at 65 frames, the last at 512 x 130) holds 31,133,696 conv parameters.

## Per layer (activations exact): `tools/Measure-KokoroDecoderWeightError.ps1`

Each stride-1 conv on its captured input (`tools/reference/capture_stock_decoder.py`), output SNR against the stock conv:

| Weights, per output channel | Output SNR, all 16 convs |
| --- | ---: |
| W8 (absmax / 127) | 42.6 .. 50.2 dB |
| W4 (absmax / 7) | 17.1 .. 25.1 dB |
| W4, clip chosen for least weight error | 12.8 .. 25.3 dB (better on k = 3 convs, worse on several 1 x 1) |
| W4, one scale per 128 weights along (cin, k) | 19.5 .. 28.6 dB |
| W4, one scale per 64 weights | 21.2 .. 29.5 dB |
| W4, one scale per 32 weights | 21.9 .. 30.6 dB |

Group scales recover 3-6 dB per layer, about 20 dB short of W8 on every layer. On HMX a group scale also splits each
output channel's accumulation into one readout per group, which per-output-channel scales avoid.

## End to end: stock PyTorch with only the decoder's conv weights quantized

Same phonemes, voice and seed (so the generator's random draws are the same); PCM SNR against unmodified stock:

| Decoder conv weights | PCM SNR |
| --- | ---: |
| W8 all | **40.62 dB** |
| W4 all | 16.39 dB |
| W4 in the k = 3 convs, W8 elsewhere | 18.07 dB |
| W4 in decode.0-2's k = 3 convs, W8 elsewhere | 19.36 dB |

Listening copies (24 kHz mono): `build/stock-decoder-capture-20261008c/decoder-{stock,w8,w4}.wav`.

## Reading

Per-channel 4-bit weights move the waveform far from stock (16-19 dB); 8-bit weights alone already reach the ~40 dB bar.
The decoder runs once per breath group at 65 frames, so its 31 MB of W8 weights are streamed once per group. At the
37-55 GB/s DDR-to-VTCM DMA measured on SM8550 (`docs/results/dma-copy-sm8550-sm8635-20261007.md`, possibly cache-assisted)
that is about 0.6-0.9 ms; its ~2.2 GMAC of HMX work is of the same order. W4 would save at most about half the DMA
(0.3-0.5 ms per group), less the HVX unpack, and nothing if the DMA already overlaps the HMX work [estimate, not measured]. Proposed: W8 per output channel for the decoder
(W4 only if listening shows the 16 dB difference is inaudible and a measured DMA time makes it matter). Not yet decided by
the team.
