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

## Not measured

- The size of the text-encoding difference and its effect on the decoder's output.
- Time per front-end stage on the phone (on the host, ALBERT is about 71 % at 510 phonemes:
  `frontend-host-stages-20261027.md`).
- `Vector256` is not hardware-accelerated on this CPU, so the 256-bit workers run in software.

Receipt: `build/frontend-phone-*` (receipt.clixml, phonemes.txt, Run.ps1).
