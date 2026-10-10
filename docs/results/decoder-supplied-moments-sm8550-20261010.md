# Decoder chunks with supplied AdaIN moments, SM8550, 2026-10-10

Hello world decoder (65 asr frames, `build/decoder16-fixture-20261009m4d`, stock capture
`stock-decoder-capture-20261008c`), `KokoroDecoder16Run` with capacity 65 and the frame count read at run time.
Code at `c3c1d2f` (`Add-KokoroDecoder16JobSteps -Moments`). 3 runs per job; DSP time is the median region time.

| Run | Against one pass on the DSP | Against stock | DSP time |
| --- | ---: | ---: | ---: |
| Whole utterance, accumulated moments, exported | (reference) | 41.54 dB | 14.632 ms |
| Whole utterance, its own exported moments supplied | bit-exact | 41.54 dB | 14.417 ms |
| Two chunks [0,41) and [24,65), own moments | 12.21 dB | 12.24 dB | 13.459 + 13.407 ms |
| Two chunks [0,41) and [24,65), whole-utterance moments supplied | 61.97 dB | 41.50 dB | 13.312 + 13.389 ms |

Chunks are stitched at the middle of their 17-frame overlap (output frame 65 of 130). The comparison is over the decoder
output (512 channels, 130 frames), decoded with the fixture's `DecoderScales`.

- Supplying the moments takes the chunk error from 12.21 dB to 61.97 dB against the one pass; against stock the chunks
  lose 0.04 dB. The decoder's chunking error is the AdaIN statistics.
- The supplied path is exact: the whole utterance with its own exported records reproduces the one pass byte for byte.
- A 41-frame chunk takes 13.4 ms against 14.4-14.6 ms for 65 frames, so most of a decoder job's time does not scale with
  frames. The decoder streams its 31.7 MB of W8 weights through VTCM on every job; that this is the fixed cost is
  inferred from the timings, not measured. Chunk size, or weights kept across chunks, decides the per-chunk cost.
- Not covered: the generator's AdaIN sites (still accumulated per job), moments from the bank or the linguistic stream
  instead of a one-pass export, and carried edge state instead of overlap.

| Artifact | SHA-256 |
| --- | --- |
| Skel, Export | `5F16A17AFED973C08DBB421475D60534A65AC278480006F02ADED5B76E39E1AE` |
| Skel, Supplied | `7F50631FB4C009E5B6D6E1CABA771C40D7492C27B6F965ADA13F3D2E58E1D8DC` |
| weights.bin | `6FFC16BAB7C7CE6E4CD6FC3734624A21BE4B2E9FDBC9ABE38124505C1CFD96EE` |
| tables.bin | `2E7C571FCCE45DCF9C123877D3C39EB8D1709517C376DE9B4E45E869CAA3E0BF` |
| activations.bin (whole) | `C6097410FF6B0B945910DF1B6995A473053725B4F7A253A2A43543801C04D823` |
