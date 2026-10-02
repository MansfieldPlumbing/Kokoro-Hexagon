# Host verification and original-source differentials, 2026-10-01

Status: **host checks pass; connected stock-FP32 decoder parity remains open**.
No device was attached or operated. No speech, device execution, performance,
or backend promotion is established by this result.

The evidence is a local working-tree observation based on HEAD
`0a03be39e4305fb5bc1723adc4bbc046af941e55` plus the preserved pending changes.
The initial pending files were copied and compared before edits. Generated
evidence stays under `build/host-readiness-20261001T205638Z/`.

## Host gates and artifacts

- The host suite completed 82 gates without failures: analytic/reference
  checks, bounded stock-weight admission/shape checks, source-policy checks,
  and managed-container/store/session checks. These are not 82 independent
  stock numerical differentials. A final synthetic suite also passed 48 gates.
- The ALBERT attention wrapper now omits an absent key mask when invoking the
  extracted core. The unmasked attention and encoder tests pass, and the
  masked attention byte-hash regression remains unchanged.
- The new short-convolution gate passes 27 impulse fixtures over 8, 16, and
  64 frames, dilations 1, 3, and 5, and three impulse positions, for all three
  host convolution implementations.
- Six direct-emission cases match the pinned SDK assembler: probe, AdaIN,
  complete AdaIN residual block, linear tile, three-token ALBERT softmax, and
  three-token ALBERT attention. The assembler is an oracle only. Legacy affine
  and convolution-tile checks needing a prepared QNN weight manifest were
  not completed.
- A fresh model container and the version built with non-enumerating resource
  reads have identical SHA-256 values. The resource-read change does not alter
  the serialized DLL. Its synthesis-ready flag remains false.
- The complete generator bundle contains 252 tensors after folding 51
  weight-normalization pairs. Its 78,630,016-byte data file matches its
  manifest digest. This admits a build-time weight bundle, not a synthesizer.
- Three emitted-library/fixture pairs are recorded in `device-plan-final.json` for
  separate SM8550 and SM8635 physical diagnostics. No physical gate passed
  in this session.

## Independent original-source checks

The oracle uses Torch `2.14.0+cpu`, source commit
`08187d9e0fba026dc8217405802ab5381dc88d90`, with Python 3.14.0. This records
the actual interpreter; it does not claim the historical Python 3.14.7 pin.
The isolated dependency lock contains URL/hash pins, and 14,975 installed
dependency files were verified against their installation records. Five
native source contracts were acquired at the actual Torch commit and checked
against Git blob identities and SHA-256 digests.

Numerical class definitions come from Kokoro
`dfb907a02bba8152ca444717ca5d78747ccb4bec` and Transformers
`8ac2b916b042b1f78b75c9eb941c0f5d2cdd8e10`. The archive members are checked
against pinned Git blob identities before their selected AST definitions are
executed. The original no-kernels decorator fallback is used; no Hub kernel is
loaded. Torch/Python are confined to `tools/reference/` and ignored evidence.

The stock checkpoint, configuration, and `af_heart` pack retain the exact
lengths and digests in `lib/manifest.json`. Decoder conditioning uses voice
row 6 and its first 128 values. These are bounded fixtures, not an admitted
complete utterance.

Each independent numerical gate declared maximum absolute error `1e-4` and
minimum SNR 80 dB before comparison. Limits were not relaxed after failures.

| Comparison | Maximum absolute error | SNR (dB) | Result |
| --- | ---: | ---: | --- |
| ALBERT Q/K/V projections, three tokens | 9.5367e-7 | 141.03 | Pass |
| Complete ALBERT attention, three tokens | 1.9073e-6 | 137.79 | Pass |
| ALBERT encoder, all 12 repeats, three tokens | 7.8678e-6 | 108.75 | Pass |
| Generator residual block, 8 frames | 1.5259e-5 | 122.48 | Pass |
| Generator residual block, 16 frames | 2.6703e-5 | 122.18 | Pass |
| Generator residual block, 64 frames | 4.0054e-5 | 122.61 | Pass |
| Historical zero-style r0 fixture, 8 frames | 1.8597e-5 | 115.62 | Pass |
| Historical zero-style r0 fixture, 16 frames | 1.3709e-5 | 122.28 | Pass |
| Decoder prelude encode input | 4.7684e-7 | 143.62 | Pass |
| Decoder prelude ASR residual | 7.4506e-8 | 133.23 | Pass |
| Connected decoder before generator, two frames | 8.8956e-3 | 60.77 | Fail |

Twelve additional spectral comparisons pass: real and imaginary STFT output,
round trip, and inverse from identical spectra, for 40-, 41-, and 45-sample
signals. Their maximum error is at most 3.5763e-7. This verifies the small
TorchSTFT fixtures, not learned-generator waveform synthesis.

The historical short r0 fixtures now independently agree with original stock
source. This supports their PowerShell oracle outputs. It does not establish
the cause of the historical QNN backend discrepancy or pass a device gate.

## Decoder precision boundary

All five decoder blocks pass independently when given identical input:
maximum errors range from 8.9407e-7 to 1.0490e-5 and SNR from 98.74 to
128.68 dB. In the connected comparison, the propagated decode-1 output first
exceeds the absolute-error limit at 1.0084e-4; decode-2 and decode-3 also fail.
The full connected result is unchanged by enabling the trace output.

As a separate precision diagnostic, the original decoder evaluated in FP64
agrees with the reference at maximum error 3.7672e-5 and 108.10 dB SNR.
Same-input FP64 block diagnostics reach 139.10--146.05 dB. The PowerShell
references store FP32 tensors but use double accumulations/statistics. The
controlled precision comparison demonstrates sensitivity in this short
fixture. FP64 diagnostics do not replace the failed stock-FP32 gate.

The final independent receipt has 33 checks: 29 pass and four fail. The four
failures are the connected decoder and three propagated stages of that same
precision-sensitive chain. Stock-FP32 connected parity, complete learned
generator parity, full phoneme-to-PCM equivalence, and audible direct-DSP
speech remain open. Do not infer an operator-layout or padding defect from
this result or promote the connected decoder by changing its tolerance.

## Evidence and controls

Use `gates/receipt.json`, `synthetic-final/receipt.json`,
`torch-oracle/torch-differential.json`, `model-reproduction.json`,
`bundles/generator/manifest.json`, and `device-plan-final.json` under the evidence
root. Failed preliminary attempts are preserved separately. Source snapshots
and hashes describe local working-tree evidence, not an immutable release.

Checked controls: AST admission and bounded inputs (SSDF/NISTIR 8397), pinned
source/package/model integrity (SI-7/SP 800-161), project and reference-path
isolation (AC-6/CM-7), and backup/change control (CM-3). No push, deployment,
history rewrite, or synthesis promotion occurred. The historical QNN internal
cause and all physical execution/speech claims remain unverified.
