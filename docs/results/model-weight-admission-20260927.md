# Model weight admission and synthesis handoff, 2026-09-27

The PowerShell readers `Read-KokoroAcousticWeights.ps1`,
`Read-KokoroDecoderWeights.ps1`, and `Read-KokoroGeneratorWeights.ps1`
admit the pinned `kokoro-v1_0.pth` into named tensor maps for the existing
acoustic, decoder, and generator stages. Each checks the exact checkpoint
length and SHA-256 before parsing, then exact tensor names, shapes, FP32
storage, contiguous strides, and finite values. The three maps contain
171, 72, and 303 tensors respectively. The checkpoint is in ignored
`build/cache/`, not the repository history or APK.
`Test-KokoroWeightCoverage.ps1` accounts for all 548 checkpoint entries:
546 map into the consumed computation; the other two are ALBERT pooler
weight and bias. Kokoro's `CustomAlbert.forward` returns only
`last_hidden_state` (`kokoro/modules.py:180-183` at the pinned revision).
The pinned Transformers source
`8ac2b916b042b1f78b75c9eb941c0f5d2cdd8e10`,
`src/transformers/models/albert/modeling_albert.py:720-729`, forms
`pooler_output` from `sequence_output` after the encoder and does not feed
it back into `last_hidden_state`. Thus those two tensors do not enter the
stock speech output path; they remain in the source checkpoint for identity.

Source identity: Kokoro `dfb907a02bba8152ca444717ca5d78747ccb4bec`,
`kokoro/model.py` and `kokoro/istftnet.py`; stock checkpoint revision
`f3ff3571791e39611d31c381e3a41a3af07b4987`; model digest and config
in `lib/manifest.json` and `lib/kokoro-v1_0.config.json`.

Executable gates passed:

```powershell
pwsh -NoProfile -File tools/Test-KokoroAcousticWeights.ps1 -CheckpointPath build/cache/kokoro-v1_0.pth
pwsh -NoProfile -File tools/Test-KokoroDecoderWeights.ps1 -CheckpointPath build/cache/kokoro-v1_0.pth
pwsh -NoProfile -File tools/Test-KokoroLearnedGenerator.ps1 -CheckpointPath build/cache/kokoro-v1_0.pth
pwsh -NoProfile -File tools/Test-KokoroWeightCoverage.ps1 -CheckpointPath build/cache/kokoro-v1_0.pth
pwsh -NoProfile -File tools/Test-KokoroPhonemeToPcmContract.ps1
```

`Invoke-KokoroPhonemeToPcm.ps1` now connects the full configured acoustic
branches, decoder prelude/core, harmonic source, learned generator, and PCM
head for admitted token IDs and a voice row. The contract gate validates
its AST and rejection of invalid boundary tokens and incomplete weight maps.
`Read-KokoroVoiceRow.ps1` also verifies the pinned `af_heart.pt` artifact
and selects stock row `phoneme_count - 1`; its row-shape and bounds gate passes.
`Test-KokoroPhonemeToPcmFull.ps1` defines the pending complete stock-layer
execution gate and writes output PCM only under ignored `build/` after a pass.
No completed stock-weight forward has been recorded yet. The older reduced-layer
acoustic fixture was deliberately stopped during a slow scalar rerun and is
not a new pass. No listening, device execution, numerical parity, latency,
or speech claim follows from this handoff. The next promotion gate is a
bounded same-input stock numerical differential through the complete chain.
