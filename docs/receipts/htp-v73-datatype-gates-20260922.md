# What HTP V73 will and will not do with tensor datatypes

Device: SM8550 / Hexagon V73. QAIRT 2.46.0.260424. All graphs built through the QNN C API
from PowerShell on device. Error names resolved from the generated authority pack
(`QAIRT-2.46.0.260424/Enums.psd1`).

## 4-bit weights are refused at op config, not at the tensor

`MatMul`, 256x256 static weight against uint8 activations, per-tensor ScaleOffset:

```
Case=w8         weightBytes=65536  addRc=0     finalizeRc=0     contextBytes=110592
Case=w4packed   weightBytes=32768  addRc=6005  finalizeRc=6022  contextBytes=-1
Case=w4unpacked weightBytes=65536  addRc=6005  finalizeRc=6022  contextBytes=-1
```

`6005 = QNN_GRAPH_ERROR_INVALID_OP_CONFIG`, `6022 = QNN_GRAPH_ERROR_FINALIZE_FAILED`.

Three things follow. `tensorCreateGraphTensor` accepted a `UFIXED_POINT_4` tensor in both
cases without error, so the datatype exists and the tensor is constructible; the failure is
`MatMul` refusing to consume it. Packed (two nibbles per byte) and unpacked (one per byte)
fail identically, so this is not a container-convention mismatch. `QNN_DATATYPE_SFIXED_POINT_2/4`
and `UFIXED_POINT_2/4` are present in the core `Qnn_DataType_t` enum, but no `int4`, `4BIT`,
`FIXED_POINT_4` or nibble reference appears anywhere in the extracted HTP headers.

4-bit on this part is therefore reachable only through our own kernel, not through vendor ops.

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

`src/runspace/W4A8.ps1` for the first table. The second is `src/runspace/R009.ps1` against
`Kokoro.F0NSecondPairPolyphaseR009.psm1`, once as committed and once with four edits:
`Float32` -> `Float16` on the datatype binding; a half-converting wrapper around the
specimen slice used for statics and exec inputs; output buffers 133,120 -> 66,560; and the
readback expanded from half instead of `BlockCopy`. The oracle stays fp32 throughout.
