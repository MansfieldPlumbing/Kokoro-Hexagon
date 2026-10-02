# Frozen weight-normalization folding gate

`ConvertTo-KokoroWeightNormConv1dWeights.ps1` folds a pinned Conv1d
`weight_norm(dim=0)` parameterization into effective FP32 weights at model
build time:

```text
W_eff[o, i, k] = weight_g[o] * weight_v[o, i, k] /
                 sqrt(sum(weight_v[o, :, :]^2))
```

`Test-KokoroWeightNormFold.ps1` used the pinned checkpoint tensor
`decoder.module.generator.resblocks.3.convs1.0` with a bounded 128-channel,
8-frame input. The folded-weight convolution and the existing source-defined
weight-normalized reference had maximum absolute error
`5.960464477539063e-08`.

This admits the folding algebra for that tensor and fixture only. The new
PowerShell functions are build-time/scalar-oracle material; they do not place
PowerShell convolution on the product inference path. A direct emitted kernel,
artifact layout, and consumer-boundary differential remain open.
