# Direct AdaIN and complete generator block: S23

Date: 2026-09-28. Physical SM-S911U / SM8550. Diagnostic preview host;
`libcdsprpc.so` transport. This is not a synthesizer, a resident product
transport, a causal model, or an audible-speech result.

## Source and scope

- Kokoro source: `dfb907a02bba8152ca444717ca5d78747ccb4bec`,
  `kokoro/istftnet.py:34-78` (`AdaINResBlock1`).
- Checkpoint revision: `f3ff3571791e39611d31c381e3a41a3af07b4987`;
  SHA-256 `496DBA118D1A58F5F3DB2EFC88DBDC216E0483FC89FE6E47EE1F2C53F18AD1E4`.
- Voice: pinned `af_heart`, row selected for seven phonemes; first 128 values.
  SHA-256 `0AB5709B8FFAB19BFD849CD11D98F75B60AF7733253AD0D67B12382A102CB4FF`.
- Region: `decoder.module.generator.resblocks.3`, 128 channels, 64 frames,
  kernel size 3; first convolutions have dilations 1,3,5, second convolutions 1.
- Two deterministic synthetic activation fixtures: stock style and style with
  coordinates 3 and 41 changed by +0.01 and -0.02. Neither is a captured
  full-model acoustic activation or evidence of improved voice quality.

`New-KokoroAdaInResBlockFixture.ps1` prepares fixtures on the PC. It folds
weight normalization and precomputes all six style projections. The reference
is `Invoke-KokoroAdaInResBlock1.ps1`, using the original weight-normalized
convolutions and stock Snake function. No ONNX, QNN or Python is used here.

`Kokoro.AdaInResBlock.ps1` directly emits one callable DSP region containing
six full-time AdaIN, Snake and convolution stages plus three residual adds.
No intermediate tensor crosses the host boundary between stages. The packed
weights/control input is 1,195,008 bytes; diagnostic scratch is 103,424 bytes;
input and final output are 32,768 bytes each. This harness still transfers the
packed input and returns scratch; persistent weights and zero-copy are not proved.

AdaIN uses population variance, epsilon 1e-5, the documented reciprocal-root
seed plus three Newton iterations. Snake uses pi range reduction and a
degree-17 sine polynomial. These are declared numerical implementations,
not assertions of bit-exact identity with the stock reference.

## Physical correctness and timing

| Implementation | Stock maximum error | Changed-style maximum error | Stock / changed-style SNR |
|---|---:|---:|---:|
| Scalar DSP block | 0.000041485 | 0.000047803 | 121.59 / 120.96 dB |
| HVX QFloat with FP32 conversion | 0.000059366 | 0.000061035 | 118.19 / 118.32 dB |

The unchanged whole-block threshold was maximum absolute error <=0.001.
HVX versus the preceding scalar DSP implementation had maximum errors
0.000045776 and 0.000059843, respectively. HVX uses four vectors to accumulate
128 output channels, preserving tap/input reduction order, explicitly converting
each QFloat operation to FP32. The internal time-major convolution output is
transposed on DSP before the next full-time normalization.

Four physical runs used scalar/vector/vector/scalar order. Each run executed
each fixture seven times; all 56 invocations passed and repeated output hashes
were identical within each case/version. Excluding invocation zero of each
case leaves twelve samples per table row:

| Order | Version | Median invoke ms | Min–max ms |
|---:|---|---:|---:|
| 1 | Scalar | 407.751 | 406.198–410.098 |
| 2 | HVX | 15.419 | 13.856–17.664 |
| 3 | HVX | 15.437 | 14.079–17.887 |
| 4 | Scalar | 407.596 | 406.359–409.698 |

The approximately 26.4x ratio is for this small block and this diagnostic
invocation path, including marshalling/transport, not DSP-only timing or
whole-model real-time factor. Power/thermal state was not controlled.

## Artifact identities and local evidence

- Scalar ELF: `06B787D2BBF9493AF66B87F4C77BB42DE85765AACB6E500BDEC2CF96CF863693`;
  6,444 code bytes, 12,480 ELF bytes.
- Passing HVX ELF: `09399E025D5168BD9C8CA37C9A25CA0A5F386FFFE59A693659EFCA4CA56C0CCC`;
  7,712 code bytes, 12,480 ELF bytes.
- Both directly emitted instruction streams matched the independent SDK
  assembler byte-for-byte; zero imports and relocations. Assembler SHA-256:
  `fc64c65aca06186106a73ba93e65ddf7c906bf4905b786dc748d3f034401ea27`.
- Fixtures: `build/adain-block-direct-001/fixture-002/fixture.json`.
- Scalar runs: `build/adain-device-d3bb252ace5c444cb94dc023bffcfbc6`,
  `build/adain-device-d8446b9623d0455eb78252e102060ff5`.
- HVX runs: `build/adain-device-8f2b52eabaaa4ce49a8dbc3615bd050f`,
  `build/adain-device-89dbc083cb1842298fabe4b8ad055bd2`.

Each run contains comparison, raw diagnostic timing and startup-restoration
results. App startup files were backed up, restored and hash-checked after
every deployment, including rejected candidates. Nothing was deleted.
Fresh-process final emission reproduced both exact ELF hashes, with nineteen
invalid-operand rejections. Ten affected PowerShell sources passed AST parsing;
`Test-ProductionClosure.ps1` and `git diff --check` passed. The closure test
is source-policy lint, not verification of an assembled product APK.

Reproduce with new build paths (one attached diagnostic device):

```powershell
& tools/New-KokoroAdaInResBlockFixture.ps1 -OutputDirectory build/block-reproduce-fixture
& tools/Test-HexagonEmission.ps1 -Kernel KokoroAdaInResBlock -AdaInVectorConvolution -OutputDirectory build/block-reproduce-hvx
& tools/Invoke-KokoroAdaInDirectProbe.ps1 -ResBlock -RepeatCount 7 -ArtifactDirectory build/block-reproduce-hvx/KokoroAdaInResBlock -FixtureDirectory build/block-reproduce-fixture
```

The first command runs the bounded PC oracle and is not a device benchmark.
Omit `-AdaInVectorConvolution` and choose a different artifact directory for
the scalar comparator. No pre-existing result directory should be overwritten.

## Rejected candidates and precision boundary

The first HVX candidate (`06961B7...`) returned the input unchanged and failed
the block comparison. A follow-up vector load/store canary passed, while a
direct IEEE-result vector-add canary failed (`006AD0E...`, return 35).
Do not infer a chip-wide cause or overturn historical receipts from this alone.
Those older artifacts need their own controlled investigation before reuse.

The documented QFloat-result variant initially failed an overly strict bitwise
canary: scalar expected bits 1045561432 versus vector bits 1045561433, exactly
one FP32 ULP. The positive pinned-bias canary now admits one ULP, consistent
with the documented different rounding; the original whole-block tolerance
was not loosened. The complete block then passed. Failed candidates and their
receipts remain under `build/adain-block-hvx-001` through `-005` and associated
device-result directories; only `-006` is the passing vector candidate.

ISA basis: Qualcomm [V73 HVX PRM, 80-N2040-54 Rev. AB](https://docs.qualcomm.com/bundle/publicresource/80-N2040-54.pdf),
section 5.6 and pages 154, 250, 262 for QFloat arithmetic/conversion;
[V73 PRM, 80-N2040-53 Rev. AB](https://docs.qualcomm.com/bundle/publicresource/80-N2040-53.pdf),
page 470 for the scalar inverse-square-root seed.

## Standalone AdaIN gate and next boundary

The separate 128x64 AdaIN kernel also passed six numerical fixtures, seven
input/domain rejection cases and unsupported-method rejection. Its ELF hash
is `D9C48A3A547070FD95F0A7C412C051036D22F4F9E386074252B8A4E42A7E21F7`.
Largest numerical error was 0.000003815; the following stock Snake consumer
passed on PC with maximum error 0.000007630. Evidence:
`build/adain-device-d67b6c80bcee47988d051939210994f8`.

Next: broaden deterministic activation/voice/shape coverage, gate the next
generator consumer, then compose further source-verified regions into the
same DSP program. The current vector option remains opt-in. No live text
mutation, sparse resident-control update, audio quality, ALBERT-to-PCM path,
queue transport or causal streaming claim follows from these tests.
