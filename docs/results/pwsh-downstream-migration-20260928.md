# Pwsh downstream migration result — 2026-09-28

## Result

The repository-shape migration from the local Kokoro host fork to a pinned
Pwsh base plus a separate Kokoro engine is complete.

- Pwsh is pinned at commit
  `ba84d1921c272699b45e75e21360a454fb647f7c`; its admitted `setup.ps1` and
  manifest passed exact length and SHA-256 verification and PowerShell parsing.
- Active Kokoro build and validation scripts do not read `setup-kokoro.ps1`.
- The downstream identity is `Dev.MansfieldPlumbing.Kokoro.Model.dll`.
- The model store derives its content filename from the signed managed assembly
  identity instead of the legacy `Kokoro-Hexagon.dll` name.
- The retained fork is historical material only and is not an active build,
  validation, packaging, or runtime input.

## Verified artifact

The existing consolidated FP32 artifact passed the clean-process assembly and
signed-store gates after the migration:

- bytes: `327809536`
- SHA-256:
  `682356E5EE8F913CD69E259C0AA309F567F81F36B2BC714867286856994CA6C3`
- tensors: `548`
- voice: `Kokoro.Voices.af_heart.f32`
- graph SHA-256:
  `1AD914D60E464F0D990C66C5121E6E4E32F111AEEA0FE3567F9B9452F9A02D12`
- `SynthesisReady`: `false`

The model-store tests also passed signature verification, bounded admission,
content-addressed installation, atomic activation, fresh-process loading,
tamper rejection, and managed-native payload rejection.

## Boundary

This result proves the repository and artifact ownership migration. It does not
prove a packaged Pwsh APK with the extension store, full Kokoro graph lowering,
direct Hexagon inference, PCM delivery, audible speech, quality, or latency.
Those remain explicit product gates in `ROADMAP.md`.
