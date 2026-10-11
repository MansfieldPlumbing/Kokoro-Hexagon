# Kokoro-Hexagon

PowerShell-authored text-to-speech for Android, with Kokoro's decoder, harmonic
source and generator running together on the Hexagon DSP. PowerShell reads the
checkpoint, packs the weights, and emits the Hexagon machine code and ELF directly.
HMX handles convolutions and matrix multiplies; HVX handles the remaining model math.

## First audible network-free synthesis on SM8550

**“I can eat a peach for hours.” — October 10, 2026**

| Measurement | Result |
|---|---:|
| Speech | **2.125 seconds**, 51,000 PCM samples at 24 kHz |
| Median DSP execution | **148.495 ms** |
| DSP synthesis speed | **14.3× real time** |
| PCM SNR against the matching reference | **31.29 dB** |
| Clipped samples | **0** |
| VTCM allocation | **7.75 / 8 MiB** |

The connected synthesis job produced an entire sentence on the S23's SM8550 and
played it through the phone speaker using AAudio. All three runs produced identical
PCM.

This is measured, audible speech faster than real time. Windows prepared the
front-end inputs for this run; the phone executed the decoder, harmonic source,
generator and PCM playback. The 148.495 ms measures DSP execution. Median host
invoke time was 179.790 ms. Complete text-to-audio latency and time to first audio
will be measured once the resident front end is connected.

The exact emitted library, inputs, output and device receipt are banked
and protected by the `network-free-peach-sm8550` ratchet. See the
[baseline receipt and artifact manifest](docs/results/bank-front-end-sm8550-20261010.md).

## How it works

The active system is a network-free Kokoro variant. A compiled phonemizer, a unit
bank and PowerShell-learned prosody tables replace ALBERT, the text encoder and
predictor LSTMs at playback. Stock Kokoro supplies offline training captures and the
numerical reference for the decoder and generator.

The Android integration follows this path:

```text
Text → phonemizer → unit selection + prosody → packed decoder inputs
     → Hexagon decoder → harmonic source + generator → PCM → AAudio
```

The front end and dispatch run on ARM; synthesis math runs on Hexagon. The DSP
path uses integer kernels, 16-bit activations, W8x2 weights and per-channel scales.
Our build emits its own instructions and ELF without C/C++, LLVM or QNN. Python
and PyTorch are used only for stock Windows reference captures and evaluation.

The phonemizer has already run independently in the Android host: 57.8 µs warm per
sentence on SM8550, with token IDs identical to Windows. Its challenge corpus
completed 73/73 sentences and its held-out corpus 149/153. See the
[phonemizer documentation](phonemizer/README.md) and
[phone receipt](docs/results/phonemizer-polish-sm8550-20261008.md).

## Phone integration comes next

The next delivery is fresh text entered on the phone producing speech with Windows
disconnected. The accepted synthesis quality is sufficient to begin integration.

1. Give the generator a runtime frame count, retaining the existing normalization
   for the first short resident sentence.
2. Compile the selector and persist the learned prosody tables with an indexed local
   bank and deployment calibration checked on holdouts.
3. Connect phonemization, selection, packing, DSP execution and AAudio in the APK
   host, retaining resources between requests.
4. Extend to bounded frame streaming, then measure warm and cold latency, time to
   first audio and end-to-end real-time factor on SM8550 and SM8635 separately.

The model-less APK host and verified local model/bank payload ship separately.
Training and Zira remain offline. No per-utterance teacher capture or recalibration
belongs in the resident playback path. In-process stages pass typed objects and
binary buffers; user text is data, never executable PowerShell.

### Frame chunking as temporal tiling

The first sentence fit after a manual scratch-size adjustment: reducing the
convolution batch from 22 to 14 tiles saved 512 KiB, lowering requested VTCM from
8.25 to 7.75 MiB. The same complete 85 decoder frames ran with four HVX workers.
This was an unsplit utterance; general frame streaming remains to be implemented.

Streaming will use arbitrary decoder-frame cuts, including cuts inside phonemes.
Full linguistic context drives prosody upstream. Measure the largest stage handoff,
carried state and simultaneously live buffers, then choose a static frame-chunk
size and memory schedule that fit the VTCM grant. Bind producer outputs directly to
consumers in the native layout, retain live activations and reuse dead storage.

Carry convolution edge context, acoustic conditioning, harmonic phase and noise
state across cuts. Preserve native STFT/iSTFT overlap-add and give each PCM sample
one owner. Execution boundaries must introduce no pauses, duplicated samples or
arbitrary audio crossfade. Test smaller chunks and shifted cut points against the
same uninterrupted reference.

Supplied AdaIN coefficients have already reduced decoder chunk execution from
about 13.4 to 2.9 ms with exact parity against the supplied-moments path. Extending
that mechanism to the generator and producing its controls on the phone follow
the first resident sentence. See the [AdaIN design](docs/adain-control-stream-design.md),
[roadmap](docs/ROADMAP.md) and [current handoff](docs/handoff-20261010.md) for the
implementation order. A general multidimensional tiler and the 17× speed target
are subsequent work.

## Development

Start with PowerShell 7.4 or later and the project entrypoint:

```powershell
pwsh -NoProfile -File ./Invoke-KokoroDevelopment.ps1
pwsh -NoProfile -File ./Invoke-KokoroDevelopment.ps1 Verify
```

The default command reports the current commit, next step and available commands
without accessing a phone. `Verify` checks the repository and runs the same gates
as CI. Build dependencies are pinned in `lib/manifest.json`; generated artifacts
belong under ignored `build/`. Follow [AGENTS.md](AGENTS.md) for the build contract.

With the preserved baseline and an authorized SM8550 connected:

```powershell
pwsh -NoProfile -File ./Invoke-KokoroDevelopment.ps1 Run -Case network-free-peach-sm8550 -Runs 3
pwsh -NoProfile -File ./Invoke-KokoroDevelopment.ps1 Ratchet -Case network-free-peach-sm8550
```

`Run` replays the frozen input; `Ratchet` checks it against the accepted baseline.
`Speak` currently prepares a selected bank sentence on Windows and runs it on the
phone. The resident fresh-text path is the integration work above. Keep measurements
from different phone models separate, including phones with the same SoC.

The preserved `data/unit-bank/` is frozen evidence. Experiments use `build/unit-bank/`;
restore a missing working copy from the preserved copy and verify its manifest.
`Verify` does not check bank integrity. The Drive archive remains unverified until
an extracted copy passes the bank manifest check.

## Published comparisons

Checked October 10, 2026. Speed is audio duration divided by synthesis time.
Each row retains its published device and timing scope; these are comparison
points, not a matched ranking.

| Build | Device | Timed scope | Speed |
|---|---|---|---:|
| [Kokoro-Hexagon network-free baseline](docs/results/bank-front-end-sm8550-20261010.md) | S23 / SM8550 | Connected decoder, source and generator; DSP only; 2.125 s audio | **14.3×** |
| [laishere/kokoro-coreml](https://github.com/laishere/kokoro-coreml#ios), comparison `484907d` | iPhone 16 Pro | Warm phonemes-to-PCM chain; six passages; G2P and load excluded | **16.9× mean**, 19.8× on the 8.07 s passage |
| [Soniqo speech-swift](https://github.com/soniqo/speech-swift/blob/main/docs/benchmarks/ios-coreml.md) | iPhone 16 Pro | Core ML Kokoro, warm release benchmark | **12.5×** (RTF 0.08) |
| [kokoro-offline-tts-android](https://github.com/cedgeremek/kokoro-offline-tts-android#real-device-demo) | S24 Ultra / SM8650 | QNN HTP generator; separately reports 306 ms warm request-to-first-audio | **3.78×** (generator RTF 0.2644) |
| [Morph developer report](https://www.reddit.com/r/TextToSpeech/comments/1sc32wb/kokoro_tts_running_oniphone_cpuonly_20x_realtime/) | iPhone 17 Pro | CPU; modified model with a trained replacement stage; reproducible benchmark protocol pending | **20× claimed** |

17× is our next speed milestone. Leadership claims require matched measurements
with the same inputs and stage coverage. The
[six-passage protocol](docs/speed-target.md) defines the stock comparison inputs;
network-free variant results are labeled separately.

## Source and evidence

| Location | Contents |
|---|---|
| `src/hexagon` | Instruction encoding, DMA and hardware probes |
| `src/kernels` | HMX/HVX convolution, AdaIN, Snake, source and transform kernels |
| `src/jobs` | Connected DSP jobs and their memory layouts |
| `src/models` | Checkpoint reading and weight conversion |
| `src/runspace` | Native bindings, dispatch and AAudio |
| `phonemizer` | Compiled text-to-token front end |
| `tools` | Emission, packing, reference evaluation and device runners |
| `docs/results` | Hardware receipts with artifact hashes and timing scope |

Earlier stock-input speech reached 31.99 dB PCM in 106.8 ms for 1.625 seconds of
audio through the connected decoder and generator on SM8550
([receipt](docs/results/decoder-generator-sm8550-20261009.md)). The whole generator
with its harmonic source reached 37.24 dB PCM in 95.57 ms
([receipt](docs/results/generator-whole-source-sm8550-20261008.md)). These remain
separate reference results alongside the bank-front-end baseline.

The [roadmap](docs/ROADMAP.md) records delivery priorities; the newest
[handoff](docs/handoff-20261010.md) owns the numbered implementation steps.
