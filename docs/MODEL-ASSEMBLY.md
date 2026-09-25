# Kokoro model assembly

`model.ps1` is the canonical device graph contract. The build parses it without executing the model, lowers it to a two-node tensor DAG, hashes the canonical DAG, and persists that identity and its control schema into `Kokoro-Hexagon.dll`.

## Build from source

From a verified checkout on Windows with PowerShell 7.4 or newer:

```powershell
./setup-kokoro.ps1 -Step 4 -KeepIntermediates -AcceptWritePlan
```

The build verifies the pinned source specifications and package catalog hashes before producing the assembly outside the repository:

```text
../Build/Kokoro-Hexagon/arm64-v8a/managed/by-name/Kokoro-Hexagon.dll
```

No Python environment is involved in this managed assembly build. Python remains host-only export tooling when weights or tensor graph shapes change.

## Verify on Windows

The model surface can be loaded and checked before an Android appliance is installed:

```powershell
./tools/Test-WindowsModelAssembly.ps1
```

The verifier loads the assembly, calls `ModelGraphSHA256()` and `ModelControls()`, independently lowers the checked-out `model.ps1`, and requires the graph identities to match.

The current controls are the deployed context boundaries:

```text
asr, F0_curve, N, style, gb, har8, mask, mask8, capacity
```

`F0_curve` and `har8` are coupled: a pitch change requires a coherent harmonic source. `style` and `gb` are also coupled because `gb` is the precomputed per-voice AdaIN table. These are tensor controls, not yet a stable public prosody API.

## Completeness boundary

The current assembly proves a portable, source-identified model control surface. It does not yet contain the admitted text normalizer and phonemizer, large weights, QNN contexts, or DSP libraries. Text-to-phoneme lowering must pass a differential corpus gate before it becomes part of the persisted assembly API. The Android appliance remains responsible for the HTP bindings, resident buffers, typed transport, and audio output.
