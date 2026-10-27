# Host port of the stock front end against stock captures

Kokoro-Hexagon port `tools/Invoke-KokoroPrecomputedDecoder.ps1`, `-Mode FrontEnd` through
`Invoke-KokoroDevelopment.ps1 PrecomputedDecoder`, on the Windows host (lowered PowerShell on CoreCLR). The receipt's
source SHA-256 is `AFAFAB74...`; the committed port differs from it only by one renamed local in the layout transpose.

## Method

- The port's ALBERT, `bert_encoder`, predictor (three DurationEncoder LSTM and AdaLayerNorm layers, the duration LSTM
  and projection, the shared LSTM and the F0 and N blocks) and text encoder run on the phonemes of each stored stock
  capture, with the capture's voice and voice-pack row (phoneme count less one), speed 1. The decoder and generator do
  not run.
- References, from stock PyTorch at hexgrad/kokoro `dfb907a0` (checkpoint `496DBA11...`), each tensor checked by SHA-256:
  - five ALBERT captures (14 to 270 phonemes): token ids, ALBERT output (`bert_dur`) and `bert_encoder` output (`d_en`);
  - seven decoder captures (11 to 510 phonemes): the predictor's F0 and N (the inputs of `F0_conv` and `N_conv`) and
    the aligned text encoding (the input of `asr_res`), which is equal in length only if every token duration's sum
    matches.
- A capture rendered from a supplied decoder input (`speak-typed-capture-check`, from the bank front end) did not run
  stock's predictor and is skipped.
- Each boundary is scored by SNR and maximum absolute error; values below 80 dB or a length mismatch are flagged.

## Result

| Boundary | Captures | SNR against stock | Maximum absolute error |
| --- | ---: | --- | ---: |
| Token ids | 5 | exact | 0 |
| ALBERT output | 5 | 111.68 to 113.66 dB | 1.4e-5 |
| `bert_encoder` output | 5 | 110.46 to 111.98 dB | 4.2e-5 |
| F0 | 7 | 123.20 to 134.37 dB | 0.0034 Hz |
| N | 7 | 127.68 to 132.74 dB | 3.2e-5 |
| Aligned text encoding | 7 | 125.51 to 126.47 dB | 3.4e-6 |

No boundary is flagged; every aligned text encoding has stock's frame count, so the predicted durations equal stock's.

Host time for the whole front end, one process with weights loaded: 1.0 s at 11 to 14 phonemes, 3.0 s at 64,
14.0 s at 270 and 31.5 s at 510 phonemes (2,242 ticks, 28.0 s of speech).

## Observations

- **The port is the stock front end:** every boundary agrees to float32 rounding, at every length up to the 510-phoneme
  limit. It can serve as the reference for a phone front end.
- **It is not fast:** at 510 phonemes it runs at about 0.9 times real time on the host. Its time grows about in proportion
  to the phoneme count (62 ms per phoneme at 510), so most of it is per-token work, not setup.

## Not yet done

- Time per stage (ALBERT, each LSTM, the F0 and N blocks, the text encoder) at 510 phonemes.
- The front end on the phone.

Receipt: `build/precomputed-decoder-20261014/FrontEnd-20261027-062002903/frontend.clixml`.
