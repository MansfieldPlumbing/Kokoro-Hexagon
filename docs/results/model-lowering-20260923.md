# Lowering a model written in PowerShell

`src/lower/Lower-Model.ps1`. The model description is ordinary PowerShell source. SMA parses
it; this walks the AST and recovers a tensor operation DAG. Nothing here executes the model
— PowerShell is the authoring language, not the runtime.

## Why the AST and not the expression tree

SMA lowers scriptblocks to LINQ expression trees, but those carry dynamic binder call-sites
and PSObject boxing — PowerShell's own semantics, which are noise for emitting tensor
graphs. The AST is the structure before that lands, and it is a public API.

## Result

One AdaIN -> Snake -> Conv pass written as plain PowerShell:

```powershell
$xm   = Mul $x $mask
$mu   = Mul (ReduceMean $xm -Axis 2) $k
$d    = Sub $x $mu
$sc   = Add (ReduceMax (Abs (Mul $d $mask)) -Axis 2) $tiny
$c    = Div $d $sc
...
$out  = Conv $snake $w $bias -Dilation 1 -Pad 1
```

lowers to 28 nodes with operands, attributes and consumer counts. Nested calls are hoisted
into their own nodes, so `(Mul (Abs $d) $m)` becomes two nodes and the outer references the
inner by id.

Common subexpression elimination removes one node: the source computes `Mul $c $mask`
twice. At full tensor size each removal is a whole pass over memory.

Partitioning maximal runs of pointwise ops whose value has a single consumer:

```
27 ops -> 14 kernel launches

FUSE  %13:Mul -> %14:Mul -> %15:Div -> %16:Add -> %17:Rsqrt -> %18:Mul -> %19:Mul -> %20:Add -> %21:Mul
FUSE  %22:Mul -> %23:Sin
FUSE  %24:Mul -> %25:Mul -> %26:Add
```

Partitions break where they must: `sc` and `c` have three consumers each and have to
materialise, and the reductions and the convolution are their own kernels.

## Status

This is a front end and a partitioner. There is no backend that can execute a fused
partition. QNN cannot, because its op set is fixed — a partition is only a kernel if we
emit the kernel.

That is the measured motivation rather than a preference. `r0` emitted as 189 individual
QNN ops takes 280 ms against 342 ms for the whole compiled generator, and roughly 520 MB of
intermediate traffic accounts for it. Halving the passes is worth more than tiling, which
measured as a null inside a real block.

The Qualcomm compiler stays useful as a reference: it produces the oracles we score
against, and reading its output gave us the crouton layout, the kernel symbol naming and
`tile_height=8`.
