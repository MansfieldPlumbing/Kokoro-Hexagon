# Reading the Kokoro checkpoint in PowerShell

`src/runspace/Torch.Checkpoint.psm1` reads a torch.save v1.6+ checkpoint — a zip holding
one pickle and raw storages — with no Python and no native dependency. Only the pickle
opcodes torch emits are implemented; anything else throws rather than guessing.

## Result

`C:\models\Kokoro-82M\kokoro-v1_0.pth`, 327,212,226 bytes, 510 zip entries:

```
tensors = 548        parse = ~1.9 s
bert=25  bert_encoder=2  predictor=122  decoder=375  text_encoder=24
total parameters = 81,763,410   (311.9 MB fp32)
```

Shapes resolve correctly, e.g.

```
predictor.module.F0.1.conv1.weight_v   float32 [256,512,3]
predictor.module.F0.1.conv1.weight_g   float32 [256,1,1]
predictor.module.F0.1.pool.weight_v    float32 [512,1,3]
predictor.module.F0.1.conv1x1.weight_v float32 [256,512,1]
```

## Validation

Against the R009 specimen bundle, which was produced from this same checkpoint and has
been executed correctly on V73. Fusing weight_norm as `w = g * v / ||v||` over dim 0 and
transposing the PyTorch `(out, in, k)` layout to the specimen's `(1, k, in, out)`:

```
elements=393,216   maxAbsDiff=8.196E-008   over 1e-6 = 0
```

That is fp32 rounding. It validates storage offsets, element order, dtype, and the
weight_norm fusion convention in one comparison.

A weaker check was tried first and discarded: `||weight_v||` does not equal `weight_g`,
because after training both are free parameters and only the direction of `v` matters.

## Notes for anyone extending it

Three PowerShell behaviours bit this implementation and are commented in the source:
`GetNewClosure()` snapshots variables, so a cursor helper advanced its own copy; variables
carry type constraints across a scope, so reusing `$k`/`$v` as pickle keys failed against
earlier `[int]`/`[long]` declarations; and `@(...)` flattens, so the args tuple absorbed
the nested size tuple until it was built through a `List[object]`. Variable names are also
case-insensitive, so `$O`/`$o` are one variable.

## What this unblocks

Weights no longer require Python. Static int8 quantization needs only per-output-channel
ranges from these values, with no calibration. The same reader feeds a reference evaluator,
which is what activation ranges and a relative accuracy gate both depend on.
