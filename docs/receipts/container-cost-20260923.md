# What a serialized QNN context actually charges for

Measured on SM8550 / Hexagon V73, QAIRT 2.46.0.260424, by building graphs through the C API
and reading `contextGetBinarySize`. Reproduce with `src/runspace/OpCost.ps1` and
`src/runspace/TensorCost.ps1`.

## Ops are nearly free

N chained `ElementWiseMultiply` over `[1,64,64]`:

```
Ops=1   45,056      Ops=16  45,056
Ops=2   45,056      Ops=32  49,152
Ops=4   45,056      Ops=64  49,152
Ops=8   45,056
```

Sixty-four ops cost 4,096 bytes more than one. The container has a ~45 KB floor and grows in
4 KB pages, so op count is worth about 64 bytes at the margin.

This falsifies "fewer, larger ops give a denser binary". Fusion is still worth doing for
residency and for bytes moved per output frame, but not for container size.

## Tensor geometry is what costs

The same 65,536 bytes of fp16 static payload, split across different numbers of tensors,
each consumed by one `ElementWiseAdd`:

```
Count  Elems    fp16Payload   contextBytes   overhead
1      32768    65,536        688,128        622,592
2      16384    65,536        675,840        610,304
4      8192     65,536        667,648        602,112
8      4096     65,536        397,312        331,776
16     2048     65,536        258,048        192,512
32     1024     65,536        188,416        122,880
```

Identical weights, 3.7x difference in emitted size, and it moves the *opposite* way from a
per-tensor descriptor cost: more tensors is smaller. Overhead follows the element count of
an individual tensor. Holding the count at 8 and growing each tensor:

```
8 x 4096    overhead 331,776
8 x 16384   overhead 643,072
8 x 65536   overhead 811,008
```

so it rises steeply and then saturates.

The mechanism is not established. It is consistent with a generated tiling program that
grows with the extent an op has to cover, but that is a hypothesis, not a measurement.

## Consequence for the generator

Late-stage tensors are `[1,128,19201]`, about 2.46M elements each — far beyond where this
saturates. Channel tiling, already proven bit-exact for the norm/Snake/elementwise chain
(see channel-tile-exactness-20260923.md), therefore pays twice: it keeps the working set
inside VTCM, and it hands the container tile-sized tensors instead of one enormous one.
