# Direct three-token ALBERT attention on S23

Date: 2026-09-28

## Scope

This receipt covers the stock three-token fused-QKV fixture through the
attention score, stable softmax approximation, and context product:

`context = softmax(Q K^T / sqrt(64)) V`

The specialization is 12 heads by 64 channels. It is a bounded physical
operator gate, not a complete ALBERT layer or synthesizer.

## Source and emitted identity

- Transformer source contract: pinned revision
  `8ac2b916b042b1f78b75c9eb941c0f5d2cdd8e10`.
- Hexagon instruction source: Qualcomm V73 Programmer's Reference Manual,
  `80-N2040-53 Rev. AB`, pinned SHA-256
  `44EBAFD1119F725BD3C6FFB87499232520DF9A0A6E3E3DC6EA329B15DAED11A8`.
- The manual's `sfmax` encoding at page 474 closes the max-shift operation
  without a host arithmetic boundary.
- Emitted library SHA-256:
  `36E9FF41F6F622B27B8725DDB7E1ADA687C6D315F7C8034606BC38DF3904CF9F`.
- Emitted code: 32,364 bytes; library: 37,056 bytes; zero imports and zero
  relocations.
- The instruction bytes match the independently pinned Hexagon assembler
  SHA-256 `FC64C65ACA06186106A73BA93E65DDF7C906BF4905B786DC748D3F034401EA27`.

## Numerical gates

The host approximation uses a degree-seven Taylor polynomial on `x / 64`,
followed by six FP32 squarings. Across 2,748 domain and mask cases its maximum
absolute probability error against stable exponential softmax is
`4.03499016643494E-07`. Across the 36 stock-QKV score rows it is
`7.11491250859897E-07`.

The complete approximate attention context differs from the exact bounded
PowerShell reference by at most `2.38418579101562E-06` over 2,304 values.

On the physical S23, the final emitted scalar score/softmax/context kernel
passed all 2,304 values with maximum absolute error
`4.76837158203125E-07`. The length and finite-domain rejection gates also
passed. The application startup scripts were hash-checked after restoration.

## Timing and boundary

Thirteen calls were measured; the first was excluded. Warm invocation timing
was:

- median: `0.666 ms`
- minimum: `0.603 ms`
- maximum: `0.680 ms`

This is a synchronous FastRPC diagnostic call. It is not a resident product
queue measurement and is not a TTFA or real-time-factor claim. The intended
product schedule fuses this region with adjacent resident ALBERT work rather
than dispatching once per attention row.

An initial HVX context-combination candidate produced zero output lanes and
failed the numerical gate. It was not promoted. The passing artifact retains
scalar FP32 context combination as the verified baseline; vectorizing that
subregion remains a separate equivalence task.

## Remaining boundary

This receipt extends the directly emitted path through QKV consumption and
attention context. It does not cover attention output projection, residual
layer normalization, feed-forward layers, repeated ALBERT layers, duration,
decoder, generator, or audible PCM.
