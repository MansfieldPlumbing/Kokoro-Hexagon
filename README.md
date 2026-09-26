# Kokoro-Hexagon

Kokoro-Hexagon is a PowerShell-authored speech-model project targeting Qualcomm
Hexagon. The intended release is a small, model-less Android appliance plus a
separately verified, weight-bearing managed model DLL. The project is not yet
an end-to-end synthesizer; see [ROADMAP.md](ROADMAP.md) for checked evidence and
the remaining gates.

## Current status

- A PowerShell checkpoint reader extracts the pinned Kokoro-82M tensors without
  importing PyTorch. All 548 FP32 tensors have been embedded in and read back
  from a managed DLL on Windows. An FP16 payload candidate has passed the same
  integrity test. These DLLs contain weights, not executable speech inference.
- A separately emitted phoneme DLL validates the pinned 114-character
  vocabulary, 510-phoneme limit, boundary IDs, and one voice's length-selected
  style rows. Text-to-phoneme conversion is not implemented in the product.
- `New-KokoroDecoderGraph.ps1` is a parsed two-node decoder scaffold that starts
  from prepared acoustic tensors. The full phoneme-to-PCM graph and its
  QNN-free device execution path are not implemented. No live Kokoro speech
  from these DLLs has been claimed.
- Physical SM8550 and SM8635 devices have passed a directly emitted V73 HVX
  kernel test, not a complete synthesis test. Historical decoder playback
  used QNN contexts and is retained only as reference evidence.
- The signed model-less NativeActivity/CoreCLR/SMA APK built with the managed
  namespace `Dev.MansfieldPlumbing.Kokoro` is 40,967,479 bytes and has launched
  on both physical devices. It contains no model and does not prove speech.
  See `docs/receipts/model-less-appliance-kokoro-namespace-20260925.md`.

The immediate target is one admitted phoneme string to audible PCM on both
devices through the same owned model path. Utterance boundaries will use a
measured short pause; the project does not synthesize inhalation sounds.

## Architecture boundary

`setup-kokoro.ps1` is an unofficial, separately maintained fork of Pwsh's
`setup.ps1`. This fork independently builds the model-less Kokoro APK; it is
not an official Pwsh build and does not track current Pwsh work automatically.
Kokoro's PowerShell sources separately own model lowering, weights, direct
Hexagon emission, and speech integration. The active `C:\Dev\Pwsh` checkout is
neither an input nor an output; Kokoro files never belong there.

```text
Kokoro model build: pinned Kokoro inputs -> Kokoro PowerShell AST/lowering
                                        -> verified model DLL + direct DSP code
Kokoro host build:  setup-kokoro.ps1 (unofficial Pwsh fork) -> model-less APK
Device:             verified model DLL -> owned Hexagon execution -> PCM -> AAudio
```

The release gate is a model-less base APK smaller than 40 MiB. After install,
the appliance obtains one or more model DLLs using a signed release manifest,
or accepts the same manifest and DLL over the offline AOA channel. The model
store verifies compatibility, length, SHA-256, managed assembly identity, and
manifest signature before atomically changing the active-model pointer. Model
DLLs ultimately include graph and hot paths, not just compressed tensors.

QNN, ONNX Runtime, Python, PyTorch, and LLVM are oracle/reference or historical
benchmark material, not production build or runtime dependencies. Do not feed
their compiled contexts or libraries into the release. Existing `src/export/`
and `src/runspace/Qnn.*` paths are not the product pipeline.

## Source map

| Path | Role |
| --- | --- |
| `ROADMAP.md` | Canonical gates and checked status. |
| `New-KokoroDecoderGraph.ps1` | Current parsed, two-node decoder contract; incomplete. |
| `setup-kokoro.ps1` | Unofficial Pwsh-builder fork for the model-less APK/managed host; does not synthesize speech. |
| `src/runspace/Native.Binding.psm1` | QNN-independent native export binding used by AAudio and direct probes. |
| `src/runspace/Model.Store.psm1` | Signed, transactional private-storage model admission and activation. |
| `lib/manifest.json` | Pinned model and historical reference provenance. |
| `src/text/` | Pinned phoneme admission and voice-row expression source. |
| `src/weights/`, `src/runspace/Torch.Checkpoint.psm1` | Host-side tensor extraction and FP16 conversion. |
| `tools/Build-WeightAssembly.ps1` | FP32/FP16 validation DLLs outside Git. |
| `docs/receipts/` | Narrow, dated measurements; historical QNN receipts are not product gates. |

The checked Windows validation commands are below. Set `KOKORO_MODEL_DIR` to
the directory containing the pinned checkpoint and voice pack; set the two DLL
variables to paths emitted by `tools/Build-PhonemeContractAssembly.ps1` and
`tools/Build-WeightAssembly.ps1` outside Git.

```powershell
$voicePath = Join-Path $env:KOKORO_MODEL_DIR 'voices\af_heart.pt'
$phonemeDll = $env:KOKORO_PHONEME_DLL
$weightDll = $env:KOKORO_WEIGHT_DLL
pwsh -NoProfile -File .\tools\Test-PhonemeExpression.ps1 -VoicePath $voicePath
pwsh -NoProfile -File .\tools\Test-PhonemeContractAssembly.ps1 -AssemblyPath $phonemeDll -VoicePath $voicePath
pwsh -NoProfile -File .\tools\Test-WeightAssembly.ps1 -AssemblyPath $weightDll
pwsh -NoProfile -File .\tools\Test-ModelContract.ps1
pwsh -NoProfile -File .\tools\Test-NativeBinding.ps1
pwsh -NoProfile -File .\tools\Test-ModelStore.ps1
pwsh -NoProfile -File .\tools\Test-ProductionClosure.ps1
```

These validate contracts and embedded data; they are not a `Speak` command.
Generated DLLs, APKs, audio, and raw logs are not committed. The independent
appliance build defaults to the ignored `build/` directory; its signing-key
and package-cache defaults remain outside the repository.

## Licensing

Repository code is Apache-2.0; see [LICENSE](LICENSE), [NOTICE](NOTICE), and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Kokoro-82M's pinned source,
weights, and voices carry their own Apache-2.0 notice. Historical Qualcomm
materials are not included in the product release.
