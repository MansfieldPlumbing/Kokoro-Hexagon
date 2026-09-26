# Stock AdaIN residual block differential, 2026-09-26

Status: **64-frame differential passed; short-shape discrepancy remains**.

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
| 64 | 189 | 5.4 ms | 52.99 dB | 0.0601 | yes |

The 64-frame SNR exceeds the harness's 20 dB threshold and passes the
same-weight, same-input differential before block lowering. It does not prove
all lengths, all styles, or full speech. The historical 62.10 dB receipt used
a different full-length reference and was not used to pass this gate.

Stagewise QNN outputs at eight frames agreed with PowerShell through the
first complete residual pass (57.57 dB SNR). The next AdaIN and Snake outputs
agreed at 53.60 and 52.61 dB, then the first dilation-3 Conv1D fell to
2.40 dB. At 16 frames, that same convolution scored 4.05 dB. At 64 frames,
it scored 53.86 dB; the full block scored 52.99 dB. A dilation-1 alternative
for the short fixture also failed, and sampled fused static weights applied
on the host matched the PowerShell Conv1D output within 1.81e-8. This
localizes the observed short-shape discrepancy to the QNN graph/backend
execution of that dilated convolution or an as-yet-unidentified interface
detail. It does **not** establish the backend's internal cause. Keep 8 and 16
frames as regression fixtures and separately validate any product short-
utterance behavior against stock semantics.

The device runner restored the diagnostic app's pre-test startup scripts,
receipt, and four r0 files; a post-test byte comparison matched all seven
backups. The backups remain in private app storage. The additional reference
stage files remain in the diagnostic app's r0 directory but have a different
length from the restored original input and therefore do not activate the
stagewise trace on that original fixture. A copy of the repository's generic
native-binding module was also staged because the installed diagnostic app
did not have it; that added file remains there. No product APK, model
assembly, or speech path was changed by this test.

Gates run: `Test-KokoroAdaIn.ps1`, `Test-KokoroAdaInStyle.ps1`,
`Test-KokoroAdaInConv1d.ps1`, `Test-KokoroAdaInResBlock1.ps1`,
`Test-KokoroAdaInCheckpoint.ps1`, script parsing, fixture shape and finite
output, checkpoint digest, and post-test restoration comparison.
