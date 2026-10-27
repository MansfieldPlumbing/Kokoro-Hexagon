# Host stock front end timed per stage

Kokoro-Hexagon port `tools/Invoke-KokoroPrecomputedDecoder.ps1`, `-Mode FrontEnd` (each stage's total recorded as
`FrontEndStage` beside the per-operator entries), on the Windows host. Same captures and method as
`frontend-host-port-stock-20261027.md`; every boundary again agreed with stock to float32 rounding (none flagged).

## Result

510 phonemes (capture `5-decoder`: 512 token ids, 1,121 duration frames, 2,242 ticks, 28.0 s of speech), the last of
the run's twelve captures, so weights and compiled kernels were warm:

| Stage | ms | Share |
| --- | ---: | ---: |
| ALBERT | 42,304 | 71% |
| `bert_encoder` | 84 | 0% |
| DurationEncoder layers 0, 1, 2 (LSTM, AdaLayerNorm) | 2,212, 2,246, 1,807 | 11% |
| Duration LSTM and projection | 1,732 | 3% |
| Shared LSTM (alignment included) | 4,474 | 8% |
| F0 blocks, N blocks | 411, 607 | 2% |
| Text encoder (CNN and BiLSTM) | 3,321 | 6% |
| **Total** | **59,197** | |

ALBERT at 510 phonemes:

| Part | ms |
| --- | ---: |
| `ffn`, `ffn_output` (12 repeats) | 4,663, 5,112 |
| `query`, `key`, `value`, `dense` (12 repeats) | 2,001, 1,738, 1,707, 1,758 |
| All 73 linear layers | 16,999 |
| Attention scores and softmax, LayerNorm, GELU, adds (the rest) | about 25,300 |

The five predictor LSTMs take 12,390 ms together: 1,721 to 2,206 ms each over 512 token steps, and 4,464 ms for the
shared LSTM over 1,121 frame steps.

At 270 phonemes ALBERT took 16,437 ms; from 270 to 510 phonemes it grows 2.6 times for 1.9 times the tokens, the
quadratic share of attention. The other stages grow about in proportion to their steps.

The 510-phoneme total took 31.5 s in the previous run of the same mode (`frontend-host-port-stock-20261027.md`) and
59.2 s here, so absolute host times vary between runs by up to 1.9 times; the shares are the result.

## Observations

- **ALBERT is the stage to speed up first:** 71% of the front end, and most of it outside the linear layers, in the
  attention and the element-wise operations, which the port computes with scalar loops.
- **The LSTMs are second:** 21% together, with the shared LSTM, which steps at the frame rate, the largest.
- **Everything else is under 10%:** the text encoder 6%, the F0 and N blocks 2%, `bert_encoder` under 1%.

Receipt: `build/precomputed-decoder-20261014/FrontEnd-20261027-064255080/frontend-profile.clixml` (and
`frontend.clixml` for the comparison).
