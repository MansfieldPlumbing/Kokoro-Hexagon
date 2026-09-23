# Which op names V73 accepts

SM8550 / Hexagon V73, QAIRT 2.46.0.260424, one single-op graph per candidate name, package
`qti.aisw`. Reproduce with `src/runspace/OpNames.ps1`.

```
ElementWiseSin                  addRc=0     finalizeRc=0
ElementWiseCos                  addRc=0     finalizeRc=0
ElementWiseAbs                  addRc=0     finalizeRc=0
ElementWiseExp                  addRc=0     finalizeRc=0
ElementWiseLog                  addRc=0     finalizeRc=0
ElementWiseRsqrt                addRc=0     finalizeRc=0
ElementWiseSquareRoot           addRc=0     finalizeRc=0
Tanh                            addRc=0     finalizeRc=0
Sigmoid                         addRc=0     finalizeRc=0

Sin                             addRc=0     finalizeRc=1002
ElementWiseSine                 addRc=0     finalizeRc=1002
ElementWiseSquaredDifference    addRc=0     finalizeRc=1002
ElementWiseNeuron               addRc=6000  (requires parameters)
```

`graphAddNode` accepts names that do not exist; `graphFinalize` rejects them with 1002. Op
name validation must therefore test finalize, not add.

## Consequences for AdaINResBlock1

Snake, `x + sin^2(a x)/a`, lowers with no `Pow` — which matters because `Pow(x,2)` computes
incorrectly on this part:

```
Multiply(x, alpha) -> Sin -> Multiply(s, s) -> Multiply(inv_alpha) -> Add(x)
```

AdaIN's normalisation uses `ElementWiseRsqrt` in place of `SquareRoot` followed by
`Divide`, which removes an op over the full tensor and is better conditioned:

```
ReduceMean -> Subtract -> Multiply(self) -> ReduceMean -> Add(eps) -> Rsqrt
  -> Multiply -> Multiply(gain) -> Add(shift)
```

With `Conv2d` already confirmed to accept uint8 weights and finalize, every op the block
needs is available.
