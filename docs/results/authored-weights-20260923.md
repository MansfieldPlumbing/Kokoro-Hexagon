# Authoring a prepared context's weight payload

A serialized QNN context is an executable template whose numeric payload we can write from
logical coordinates, with no compile and no prepare library.

## Result

`PING_32.QNN` (45,056 bytes, graph `PING_32_GRAPH`, in `PING_32_X` [1,32], out
`PING_32_Y` [1,32]) with its entire 2,048-byte FP16 weight region replaced by an identity
matrix authored through the V73 K-pair fold, then executed on SM8550 / Hexagon V73 through
`contextCreateFromBinary` + `graphRetrieve` + `graphExecute` from PowerShell:

```
LoadMs=48  ContextBytes=45056  ExecuteMs=18.1,2.6,1.2
Out[PING_32_Y]  NonFinite=0  MaxAbs=1.1921E-07  SnrDb=138.47  MeanAbs=1
Passed=True
```

X is all ones, so Y[n] = sum_k W[k,n] = 1 for an identity. MaxAbs 1.19e-7 is one fp32 ULP
at 1.0. The fold is therefore confirmed by execution, not only by inspection:

```
half = (k >> 1) * (N * 2) + n * 2 + (k & 1)      file = base + 2 * half
```

No ONNX, no Python, no C++ worker, and no `libQnnHtpPrepare.so` — prepare is needed to
build a graph, not to run a finished context.

## What this corrects

`Patch-QnnWeights.ps1` in the old repository was written for exactly this experiment in
2026-08 and its output, `PATCHED_32.QNN`, is on disk. Decoding that artifact shows its
weight region is entirely FP16 zero: 2,045 of 2,048 bytes differ from the template, and
none of the 1,024 halfwords is non-zero.

The cause is in the script:

```powershell
param([int]$K = 32, [int]$N = 32)
for ($k = 0; $k -lt $K; $k++) { for ($n = 0; $n -lt $N; $n++) { ... } }
```

PowerShell variable names are case-insensitive, so `$k` is `$K` and `$n` is `$N`. Both
conditions evaluate `0 -lt 0`, neither body runs, the packed array stays zero, and the
script then writes 2,048 zero bytes over the weights and executes without any error. So
the experiment appeared to run and proved nothing.

`tools/Author-QnnWeights.ps1` uses loop variables that cannot shadow their bounds and
asserts both the element count and the expected number of non-zero halfwords before
writing.

## Scope

This authors the numeric payload of an existing topology. Synthesising a new graph
structure would mean writing the FlatBuffers section of the context, which is not decoded.
Those compose, though: build a topology once through the C API, serialize it with
`contextGetBinary`, then author weights into it indefinitely at zero compile cost.
