# What HTP V73 will and will not do with tensor datatypes

Device: SM8550 / Hexagon V73. QAIRT 2.46.0.260424. All graphs built through the QNN C API
from PowerShell on device. Error names resolved from the generated authority pack
(`QAIRT-2.46.0.260424/Enums.psd1`).

## 4-bit tensors cannot be created at all

Corrected 2026-09-23. The first version of this section claimed the tensor was accepted and
`MatMul` refused it at op config. That was wrong: the probe discarded the registration
return code, so the `6005 INVALID_OP_CONFIG` it reported was a downstream consequence of an
op referencing a tensor with `id=0`. Re-run with every code checked
(`src/runspace/Fixed4.ps1`):

```
MatMul w8      regW.rc=0    id=2   addRc=0  finRc=0
MatMul w4pack  regW.rc=7004 id=0   (never reached addNode)
MatMul w4full  regW.rc=7004 id=0
Conv2d w8      regW.rc=0    id=9   addRc=0  finRc=0
Conv2d w4pack  regW.rc=7004 id=0
Conv2d w4full  regW.rc=7004 id=0
```

`7004 = QNN_TENSOR_ERROR_INVALID_TENSOR_PARAM`. `tensorCreateGraphTensor` refuses a
`UFIXED_POINT_4` tensor outright, for both ops and for both nibble packings. This is not
op coverage: no vendor op can receive a 4-bit tensor on this part, because the tensor
cannot be constructed. 4-bit is reachable only inside our own kernels, where we own the
storage and the unpack.

`QNN_DATATYPE_SFIXED_POINT_2/4` and `UFIXED_POINT_2/4` are present in the core
`Qnn_DataType_t` enum, and no `int4`, `4BIT`, `FIXED_POINT_4` or nibble reference appears
anywhere in the extracted HTP headers.

Conv2d accepts uint8 weights and finalizes, which is the case that matters: int8 is open on
the op the generator spends its time in.

## fp32 declarations were already executing and storing as fp16

The R009 F0/N second-pair graph, unchanged except that every tensor is declared
`QNN_DATATYPE_FLOAT_16` and every static and input payload is converted to half:

| declared | MaxAbs | Rmse | over 0.02 | relMax >1.0 | contextBytes |
|---|---:|---:|---:|---:|---:|
| Float32 | 0.0269908905029297 | 0.00240280029354746 | 45 | 0.002442 | 3,338,240 |
| Float16 | 0.0269927978515625 | 0.00241223170370454 | 46 | 0.002442 | 3,330,048 |

Same worst-case location in both (branch 0, channel 25, t=35). Halving the precision of
every weight and input moved MaxAbs by 2e-6. If the fp32 path had been computing in fp32,
that change would have moved the error materially.

Storage agrees. The graph's static tensors total 1,448,960 elements: 5,795,840 bytes at
fp32, 2,897,920 at fp16. The context binary is 3,338,240 — fp16 plus ~440 KB of structure —
under a Float32 declaration.

**Consequence: float precision is not a lever on V73.** Declaring fp16 changes neither
accuracy nor size because the backend already chose fp16 for both. The numeric floor for
this graph is 2.4e-3 relative, and accuracy gates should be relative and sized to it.

int8 would be 1,448,960 bytes of weights for this block. Static weights quantize from the
checkpoint with no calibration (per-output-channel min/max into `AXIS_SCALE_OFFSET`);
activations need ranges, which requires running a reference.

## Reproducing

`src/runspace/Fixed4.ps1` for the first table (`W4A8.ps1` is the earlier version that discarded registration codes). The second is `src/runspace/R009.ps1` against
`Kokoro.F0NSecondPairPolyphaseR009.psm1`, once as committed and once with four edits:
`Float32` -> `Float16` on the datatype binding; a half-converting wrapper around the
specimen slice used for statics and exec inputs; output buffers 133,120 -> 66,560; and the
readback expanded from half instead of `BlockCopy`. The oracle stays fp32 throughout.
