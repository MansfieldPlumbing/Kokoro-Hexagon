# Kokoro downstream model assembly

The active model artifact is the IL-only
`Dev.MansfieldPlumbing.Kokoro.Model.dll`. It is built independently of the
Android host from pinned Kokoro inputs and deterministic assembly-emission
helpers extracted from the immutable Pwsh revision recorded in
`lib/manifest.json`.

The current artifact consolidates:

- all 548 verified FP32 checkpoint tensors and their index;
- the pinned 114-character phoneme vocabulary and admission limits;
- the raw `af_heart` voice rows and length-selected row contract;
- the hash and controls of the current parsed two-node decoder scaffold; and
- an explicit engine contract with `SynthesisReady = false`.

It does not contain the full ALBERT, duration, F0/noise, decoder, or waveform
execution graph and does not expose `SynthesizePhonemes`. The graph identity is
therefore a bounded incomplete contract, not evidence of phoneme-to-PCM speech.

From a verified checkout with PowerShell 7.4 or newer, build and test the
artifact with:

```powershell
./tools/Get-PwshUpstream.ps1
./tools/Get-KokoroModelInput.ps1
./tools/Build-WeightAssembly.ps1
./tools/Build-PhonemeContractAssembly.ps1
./tools/Build-KokoroEngineAssembly.ps1
./tools/Test-KokoroEngineAssembly.ps1
./tools/Test-KokoroEngineStore.ps1
```

The builders default to the ignored `build/` tree. They validate lengths,
hashes, tensor metadata, PowerShell ASTs, managed identity, IL-only format, and
resource readback. The store test uses a temporary signing key and private
directory; neither belongs in source control.

The checkpoint reader is build-time tooling only. A release appliance admits
the signed model DLL and must not read checkpoint files, QNN contexts, ONNX
exports, or the legacy `setup-kokoro.ps1` fork. Precision changes and emitted
operators require their own equivalence gates before promotion.
