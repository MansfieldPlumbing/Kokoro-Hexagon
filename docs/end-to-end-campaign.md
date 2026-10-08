# End-to-end audio campaign

Goal: stock Kokoro-82M phonemes to PCM on the phone speaker, whole graph on Hexagon
(`AGENTS.md`). Input is a phoneme token sequence, the voice pack and speed; the text front
end (track 3) meets this campaign at that interface and is not on its critical path.

Stock order, hexgrad/kokoro `dfb907a02bba8152ca444717ca5d78747ccb4bec`
(`model.py` `KModel.forward_with_tokens`, `modules.py`, `istftnet.py`):

| # | Stock module | Work | DSP state (2026-10-07) |
| --- | --- | --- | --- |
| 1 | `bert` (`CustomAlbert`, plbert config) | embeddings, shared ALBERT layer repeated, attention + FFN, LayerNorm | attention probes (3-token fixtures); no full layer |
| 2 | `bert_encoder` | Linear hidden -> 512 | linear tile probe |
| 3 | `predictor.text_encoder` (`DurationEncoder`) | bidirectional LSTMs with `AdaLayerNorm` | none |
| 4 | `predictor.lstm`, `duration_proj` | BiLSTM, linear, sigmoid sum, round | none |
| 5 | alignment | `repeat_interleave` of token frames by duration | none (index expansion) |
| 6 | `predictor.F0Ntrain` | shared BiLSTM, F0 and N `AdainResBlk1d` stacks, 1x1 projections | none |
| 7 | `text_encoder` (`TextEncoder`) | embedding, 3 x (conv, LayerNorm, LeakyReLU), BiLSTM | none |
| 8 | `decoder` front | `F0_conv`, `N_conv`, `asr_res`, `encode` and 4 `decode` `AdainResBlk1d` (last upsamples) | none |
| 9 | `generator` source | `f0_upsamp`, `SourceModuleHnNSF` (harmonic sine generator, linear, tanh), STFT of the source, `noise_convs`, `noise_res` | none |
| 10 | `generator` upsampling | `ups[0]`, `ups[1]` transposed convs, LeakyReLU | none |
| 11 | `generator.resblocks` 0-2 | 256-channel `AdaINResBlock1` x 3 and mean | 256-channel integer pieces in simulator |
| 12 | `generator.resblocks` 3-5 | 128-channel `AdaINResBlock1` x 3 and mean | resident stage on SM8550, exact vs simulator; 34.68 ms with 4 HVX threads |
| 13 | `generator` tail | LeakyReLU, reflection pad, `conv_post`, exp/sin, iSTFT | 8-bit tail on both phones, PCM through AAudio |

## Order

Each step replaces one stock PyTorch capture input with DSP output, so every step ends
with PCM from the phone speaker and an SNR against stock:

1. Generator (9-13) in one DSP job from captured decoder output: speech from the generator.
   The stock source is random per call (`SineGen._f02sine` `torch.rand` initial phase of
   harmonics 1..8, `SineGen.forward` `torch.randn` noise): captures record those draws and
   the DSP comparison consumes them; the shipped job draws its own.
2. Decoder (8): from captured `asr`, F0, N.
3. Prosody (3-6) and text encoder (7): from captured ALBERT output.
4. ALBERT (1-2): from phoneme tokens. Phonemes to speaker.
5. Breath-group pipelining on the phone: render group n+1 while group n plays.

Speed work after each step uses the measured levers: HVX worker threads (3.09x on the
AdaIN + Snake body), 16-bit data width (phase-turns body, 2.1x fewer HVX instructions),
fused passes. SM8635 needs the 4 MiB tiled path for long groups.
