# Direct ALBERT embedding projection on S23

Date: 2026-09-28. Physical SM8550 / Hexagon V73. Diagnostic preview host
using `libcdsprpc.so`; this is not the resident product transport or complete
phoneme-to-PCM synthesis.

## Connected model boundary

The fixture uses the pinned stock checkpoint and admitted token IDs
`[0, 43, 0]`. `Invoke-KokoroAlbertEmbeddings.ps1` produces the three 128-value
input rows. The directly emitted kernel executes the stock
`bert.module.encoder.embedding_hidden_mapping_in` projection, 3x128 to 3x768,
including the stock bias. The expected output is produced by
`Invoke-KokoroAlbertEmbeddingProjection.ps1`.

The scalar form consumes the checkpoint's `[output,input]` weight layout. The
HVX form performs a build-time, value-preserving repack to `[input,output]`,
then accumulates 128 output channels at a time in four vectors. Every QFloat
multiply and add is explicitly converted to FP32, matching the already gated
generator-block strategy. Both forms retain the original FP32 equation.

## Emission and physical differential

- Scalar emitted library SHA-256:
  `08121EC5923CDC66307FAB5DA9775BCF18035A1DD6933336A9F8273107A82F08`.
- HVX emitted library SHA-256:
  `B9B0A1F5B08829DD9959DA856AD7111AB77577D3D132580805445931BB8048CB`.
- HVX code is 664 bytes. Its instruction bytes match the pinned independent
  SDK assembler; the ELF has zero imports and relocations.
- Scalar maximum error against the stock PowerShell oracle:
  `9.5367431640625e-7`.
- HVX maximum error against the stock PowerShell oracle:
  `1.3113021850585938e-6`.
- The admission threshold was maximum absolute error <= `1e-4`.

Each timed run used one cold invocation followed by twelve warm invocations.
The two selected runs reversed the competitor order:

| Order | Scalar warm median | HVX warm median | Invoke speedup |
| --- | ---: | ---: | ---: |
| HVX then scalar | 5.962 ms | 0.704 ms | 8.47x |
| Scalar then HVX | 5.899 ms | 0.704 ms | 8.38x |

All selected invocations passed, the library closed successfully, and the
diagnostic app startup files were restored and hash-checked after every run.
The timings include synchronous diagnostic invocation overhead and do not
measure DSP-only cycles. No queue path was used.

## Connected attention query boundary

The output of the stock embedding projection was then used as the input to the
stock `query.weight` and `query.bias` affine, 3x768 to 3x768. The scalar and
input-major HVX forms passed the same oracle at maximum errors
`4.76837158203125e-6` and `1.1920928955078125e-5`, respectively. The selected
counterbalanced results were:

| Order | Scalar warm median | HVX warm median | Invoke speedup |
| --- | ---: | ---: | ---: |
| HVX then scalar | 26.443 ms | 7.197 ms | 3.67x |
| Scalar then HVX | 26.443 ms | 7.247 ms | 3.65x |

This query result was the first physically verified affine inside the repeated
ALBERT attention layer. The following gates extend the same boundary through
key, value, and fused QKV; score/softmax, context, dense residual,
normalization, and feed-forward remain outside this physical receipt.

The separate stock key and value projections subsequently passed through the
same emitted 3x768→768 HVX artifact. Key had maximum error
`8.106231689453125e-6` and warm median 6.218 ms; value had maximum error
`5.7220458984375e-6` and warm median 6.726 ms.

Q, K, and V were then concatenated along the output-channel axis and emitted
as one 3x768→2304 job. This is an exact affine fusion: it reuses one input and
produces row-major query/key/value channel groups without changing their
equations. Two physical runs passed at maximum error
`1.1920928955078125e-5`, with warm medians 17.821 and 17.894 ms. The three
separate medians total 20.141 ms, so the fused diagnostic is approximately
11.5% lower, while also removing two host-visible invocations. This comparison
comes from separate diagnostic runs rather than a same-session counterbalanced
test and is not promoted as an end-to-end performance ratio.

## Claim boundary and next connection

This proves two connected stock-weight ALBERT affine boundaries execute through
PowerShell-emitted V73 code on the physical S23, and that output-channel HVX
tiling materially improves both tested geometries. It does not prove the
twelve-layer ALBERT encoder, complete attention, a full utterance, audible PCM,
or a whole-model real-time factor.

The next graph connection is the attention score/softmax/context region:
`A = softmax(Q*K^T/sqrt(head_dim) + mask)`, followed by `A*V`. It must preserve
the pinned head layout, mask convention, scaling, stable softmax, and next-
consumer tensor before fusion with the verified QKV job.
