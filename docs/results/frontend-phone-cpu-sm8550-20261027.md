# Stock front end on the phone's CPU, SM8550 (2026-10-27)

Kokoro-Hexagon `44e7ba8`. The host port's front end (`tools/Invoke-KokoroPrecomputedDecoder.ps1`, Library mode:
ALBERT, `bert_encoder`, the predictor and the text encoder; `Invoke-OfflineSpeech -SkipDecoder`) run in the app's
PowerShell runspace on the phone's CPU. Its numeric kernels use the portable `Vector128` / `Vector256` operations
(`29452e8`) and were compiled on the host with PSLowering `bb0f67a2` and loaded with `-CompiledAssembly` (`44e7ba8`);
the text encoder's library was compiled the same way. Phonemes come from our phonemizer on the host. Voice `af_heart`,
8 worker threads.

Runtime on the phone: Arm64, .NET 11.0.0-rc.1.26425.128, 8 processors; `Vector128` hardware-accelerated, `Vector256` not.
Loading the port took 1,994 ms.

| Phonemes | Frames (audio) | First run | Three warm runs |
| ---: | ---: | ---: | --- |
| 43 | 114 (2.85 s) | 6,074 ms | 1,475, 1,203, 1,123 ms |
| 76 | 189 (4.73 s) | 1,969 ms | 1,849, 1,892, 1,777 ms |
| 193 | 471 (11.78 s) | 4,797 ms | 4,801, 4,780, 4,853 ms |

The warm front end takes about 410 ms per second of audio on the long sentence. The decoder and generator take 26.7 ms
per audio second on the DSP (`stock-end-to-end-sm8550-20261027.md`).

## Outputs against the host

For the two sentences fingerprinted on the Windows host, the token ids, durations, F0 and N are bit-identical on the
phone. The text encoding (and the aligned encoding built from it) differs: those come from the separately compiled text
encoder library; the size of the difference is not measured here.

| Output | 43 phonemes | 76 phonemes |
| --- | --- | --- |
| Token ids, durations, F0, N | identical | identical |
| Text encoding, aligned encoding | differ | differ |

## Time per stage

A second run recorded the port's per-stage entries (`FrontEndStage` and `TextEncoderTotal`, the same entries as
`frontend-host-stages-20261027.md`) for the last of three runs per sentence, with the phonemizer also running on the
phone. Its phonemes equal the host's for all three sentences; its warm median is 0.131 ms (76 phonemes) and 0.326 ms
(193 phonemes). 193 phonemes (195 tokens, 471 frames):

| Stage | ms | Share |
| --- | ---: | ---: |
| ALBERT | 2,954.8 | 61 % |
| `bert_encoder` | 8.3 | 0 % |
| DurationEncoder layers 0, 1, 2 (LSTM, AdaLayerNorm) | 187.3, 173.8, 177.6 | 11 % |
| Duration LSTM and projection | 182.5 | 4 % |
| Shared LSTM (alignment included) | 409.9 | 9 % |
| F0 blocks, N blocks | 104.2, 111.2 | 4 % |
| Text encoder (CNN and BiLSTM) | 503.9 | 10 % |

ALBERT's 73 linear layers take 1,551 ms of its 2,955 ms (`ffn` 439.6, `ffn_output` 420.9, `dense` 188.1, `query`
159.9, `key` 169.6, `value` 163.9, the embedding mapping 8.6); attention, softmax, LayerNorm, GELU and the adds take the
rest. The five predictor LSTMs take 1,120 ms: 172 to 184 ms each over 195 token steps and 407 ms for the shared LSTM
over 471 frame steps. The stages sum to 4,813.5 ms of the run's 4,820 ms.

## Not measured

- The size of the text-encoding difference and its effect on the decoder's output.
- `Vector256` is not hardware-accelerated on this CPU, so the 256-bit workers run in software; which kernels use it is
  not broken out here.

Receipts: `build/frontend-phone-*` (receipt.clixml, phonemes.txt, Run.ps1), `build/frontend-profile-*` (receipt.clixml
with the stage entries).
