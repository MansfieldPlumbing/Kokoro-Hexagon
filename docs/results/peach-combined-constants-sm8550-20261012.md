# Peach combined constants measurement, SM8550, 2026-10-12

**peach fixture (captured decoder inputs) to PCM/speaker; front end excluded except phonemizer (0.06 ms, prior receipt)**

Implementation commit: `8dd428b76a9b8ea774b552dd0bfb188e037c0fb9`, based on
`c9ab648`. Target: SM8550 through `dev.mansfieldplumbing.kokoro`. This is the
captured peach fixture, not fresh-text synthesis. The 0.06 ms phonemizer figure
is the prior-receipt value supplied for this comparison; phonemization was not
rerun or included in the timers below. No front-end work was performed.

## Configuration and parity

`KokoroDecoderGenerator16Run` uses `ResBlockFrames=10201`,
`ResidentHvxThreads=4`, `ResidentBatchTiles=14`, `DecoderMoments=Constants`
and `GeneratorMoments=Constants`. The existing combined job now reserves the
decoder's `ConstantsParameterBytes` and passes its mode to the existing decoder
emitter. Decoder constants follow the generator's ordinary parameters; generator
constants follow the complete decoder parameters. Total parameters: 2,601,344
bytes. VTCM remains 8,126,464 bytes.

The tables are the preserved seven-capture corpus tables from
`build/generator-constants-full-corpus-20261012-143702/F`, with peach excluded
from the corpus. Combined activations and weights come from the accepted peach
fixture at `data/baselines/network-free-peach-sm8550-20261010/input`.

Fresh separate execution ran `KokoroDecoder16Run` in Constants mode, then
`KokoroGeneratorWholeSource16Run` in Constants mode using that decoder's output
and the same source inputs. Its PCM reproduced variant F's accepted hash.
The combined output and fresh separate output were then compared directly:
all 102,000 PCM bytes match. All six combined invocations produced the same PCM
hash. Each combined invocation dispatches decoder plus generator together once,
using method 2 (`0x02040100`) of the existing emitted worker.

| Artifact | SHA256 |
| --- | --- |
| Combined statistics; unchanged byte gate | `EB1B905E057FD2454AA1A555BF8F64400DD9B956C8BC23EB37EC559768A47BC5` |
| Combined constants | `2AD8D7901CE03E0113D00D2CB33B807A41FF206B4C35CEC53AAC34E43C3AA686` |
| Separate decoder constants | `4E63E1405A5486E70F316679AE143575B9C792FF8F18D09E86F47127436D2DFD` |
| Separate generator constants | `97FD245178351F91A9FD96B0DC6DC8DFDD87DE76BB4EA14CF698CBC63F840408` |
| Combined and separate PCM | `67E722EF3D6D3671ADFC8E15ADC870A9A0A5EC91C15B0A4E0F398D6B4BB66028` |
| Packed combined constants tables | `51714E59381E5D08F4B692E188AE0CBA44282218742EBF663077B8DE341D6690` |

## Timing and playback

The existing `tools/Invoke-GeneratorTailProbe.ps1` ran the combined artifact
with `-Runs 6 -Soc SM8550 -Package dev.mansfieldplumbing.kokoro`. The device
harness opens one FastRPC session/handle before its loop and invokes the same
utterance six times on that handle. Run 0 is the first call; runs 1–5 are warm.
The warm figures exclude run 0 and use medians, not means.

| Measurement | ms |
| --- | ---: |
| DSP region, median of five warm runs | 99.593 |
| Phone host invoke including dispatch, median of five warm runs | 138.739 |
| First host invoke on the newly opened handle | 150.836 |
| First-call DSP region | 100.081 |
| Connection-open time | not measured |
| AAudio write-to-start latency | not measured |

| Run | DSP region ms | Host invoke ms |
| --- | ---: | ---: |
| 0, first call | 100.081 | 150.836 |
| 1 | 100.165 | 131.387 |
| 2 | 99.653 | 139.696 |
| 3 | 99.216 | 139.381 |
| 4 | 99.593 | 135.224 |
| 5 | 98.633 | 138.739 |

DSP time is the worker's hardware-tick interval, converted at 19,200 ticks/ms.
Host invoke time is the device-side stopwatch around
`remote_handle64_invoke` through the existing managed binding; it includes
dispatch and return. It excludes app startup, connection opening, file reads,
buffer allocation and argument preparation before the call. The diagnostic tool
restarts the app between separate reference batches and tears it down after each
batch; it does not restart between these six combined invocations. This measures
handle reuse within one batch, not a persistent application across requests.
Connection-open cost is outside both first-call and warm invoke timings.

The harness played the combined PCM once through the phone speaker using the
existing AAudio path. It wrote 51,000 frames at 24 kHz mono (2.125 seconds),
completed drain and reported zero xruns. Its 2,250.8 ms playback measurement
covers writing and draining, not write-to-start latency. AAudio retains an
internal `PlaybackStartMs`, but the existing harness does not report it; no new
playback instrumentation was added.

PCM RMS is 0.0228606512, peak 0.2852172852, with zero clipped samples.
No new listening verdict was assigned. The matching F variant's listening
observation remains in the [corpus constants receipt](decoder-corpus-constants-sm8550-20261012.md).

WAV: `build/peach-combined-constants-20261012/combined-constants.wav`.

## Evidence and verification

Generated artifacts and evidence remain under
`build/peach-combined-constants-20261012/`:

- `statistics.clixml`, `combined.clixml`, `decoder.clixml`, `generator.clixml`:
  emission identities and layouts.
- `input/`: the combined binary inputs and packed tables.
- `separate-decoder-run.clixml`, `separate-generator-run.clixml`,
  `combined-run.clixml`: device receipts, including output paths and verified
  startup restoration.
- `measurement.clixml`: individual timings, warm medians, PCM metrics,
  direct byte parity and WAV path.
- `verify-mode-final.log`: passing Verify before the implementation commit.

The generator changes were staged with `git apply --cached`, containing only
the mode parameter, decoder table reservation and decoder mode argument.
The emitter change was staged by explicit path. The generator's runtime-frame
hunks remain unstaged, and other protected source files were not edited.
Verify also passed before committing this receipt. No pushes.
