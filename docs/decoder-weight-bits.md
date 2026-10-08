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
The decoder runs once per breath group at 65 frames, so its 31 MB of W8 weights cost about 2-3 ms of DMA per group at
10-15 GB/s [unverified rate on the phone]; W4 would save about half of that. Proposed: W8 per output channel for the decoder
(W4 only if listening shows the 16 dB difference is inaudible and a measured DMA time makes it matter). Not yet decided by
the team.
