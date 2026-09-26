# Stock AdaIN residual block differential, 2026-09-26

Status: **failed; direct lowering remains gated**.

`tools/New-KokoroAdaInR0Fixture.ps1` verified the checkpoint against
`lib/manifest.json`, loaded generator resblock 3 parameters with the
repository's PowerShell checkpoint reader, and computed the full three-pass
PowerShell FP32 reference. The input is deterministic, 128-channel, and all
frames are valid. The style vector is zero. This is a small numerical fixture,
not speech or a claim about normal voice conditioning. `tools/Prepare-Resblock.ps1`
prepared QNN static tensors from the same pinned checkpoint and style file.
The inputs, reference outputs, and static tensors remain only in ignored
`build/` directories.

The isolated `src/runspace/R0Emit.ps1` graph finalized and executed on the
physical S23 diagnostic app. Its all-one mask removes the valid-frame mask
difference; its QNN graph still uses its historical FP16-headroom AdaIN
formulation. These measurements do not establish which implementation is
correct:

| Frames | QNN operations | Warm mean | SNR vs PowerShell FP32 | Maximum absolute error | Finite output |
| ---: | ---: | ---: | ---: | ---: | --- |
| 8 | 189 | 3.5 ms | 0.20 dB | 9.942 | yes |
| 16 | 189 | 3.8 ms | 2.88 dB | 14.24 | yes |

The SNR is far below the harness's 20 dB pass threshold. The historical
62.10 dB receipt used a different full-length reference; it cannot certify
this PowerShell implementation. The next test is a stagewise differential:
expose and compare the first AdaIN output, Snake output, and first Conv1D
output on the same small fixture. Stop at the first disagreement and check
the corresponding pinned source contract. Do not lower this block yet.

The device runner restored the diagnostic app's pre-test startup scripts,
receipt, and four r0 files; a post-test byte comparison matched all seven
backups. The backups remain in private app storage. A copy of the repository's
generic native-binding module was also staged because the installed
diagnostic app did not have it; that added file remains there. No product APK,
model assembly, or speech path was changed by this test.

Gates run: `Test-KokoroAdaIn.ps1`, `Test-KokoroAdaInStyle.ps1`,
`Test-KokoroAdaInConv1d.ps1`, `Test-KokoroAdaInResBlock1.ps1`,
`Test-KokoroAdaInCheckpoint.ps1`, script parsing, fixture shape and finite
output, checkpoint digest, and post-test restoration comparison.
