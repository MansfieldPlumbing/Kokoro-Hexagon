# Kokoro managed assemblies

`New-KokoroDecoderGraph.ps1` is the current parsed two-node decoder contract.
The build does not execute it as a script. It lowers the AST to a graph hash
and control schema persisted in the managed Android host assembly. Its inputs
are precomputed acoustic tensors; it does not implement phoneme-to-PCM speech.

From a verified checkout with PowerShell 7.4 or newer, the existing host build
and its Windows identity test are:

```powershell
./setup-kokoro.ps1 -Step 4 -KeepIntermediates -AcceptWritePlan
./tools/Test-WindowsModelAssembly.ps1
```

The current internal controls are `asr`, `F0_curve`, `N`, `style`, `gb`, `har8`,
`mask`, `mask8`, and `capacity`. They are coupled tensor boundaries, not a
stable public prosody API. The test matches the saved host assembly's graph
hash to an independent lowering of the checked-out source.

Separate validation artifacts now exist outside Git:

- `Kokoro.Phonemes.dll` persists the pinned phoneme ID and voice-row methods;
  the tested voice variant embeds the raw `af_heart` rows.
- `Kokoro.Weights.FP32.dll` and `Kokoro.Weights.FP16.dll` contain indexed,
  hash-checked tensor resources. All 548 resources load on Windows. The FP16
  payload has only sampled weight-error evidence, not audio-quality evidence.

These three artifacts have **not** been joined into the final model DLL. They
do not contain the full Kokoro computation, a text-to-phoneme adapter, a
QNN-free Hexagon path, or live speech. The checkpoint reader is host-side
build tooling; the released app must load only verified model resources and
must not read the checkpoint or historical QNN contexts.
