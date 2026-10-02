# What is actually inside a prepared context

SM8550 / Hexagon V73, QAIRT 2.46.0.260424. Contexts emitted by building graphs through the
C API and calling `contextGetBinary`. Reproduce with `src/runspace/ProgramDiff.ps1` and
`src/runspace/VtcmConfig.ps1`.

## Ops are named kernel references, not inlined code

Emitting the same elementwise graph at 1, 2, 4 and 16 ops gives five 45,056-byte contexts
whose differences concentrate around `0x7300`, where the bytes are ASCII:

```
mul01:  6.tcm@Fe.Ff . @SyncOp . Const . SlicePad_shape_inplace@Fe*2.s4*3.ce . Mul...
mul16:  6.tcm@Fe.Ff . Const . Mul.fp16_flat@Fe*3.fi . ForceFormat_Crouton_f2c@...
```

Full symbol set recovered from a 16-op context:

```
Cast_fp32_to_fp16.tcm@Fe.Ff      Mul.fp16_flat@Fe*3.fi
ForceFormat_Crouton_f2c@Ce.Fe    Mul.fp16_no_bc@Ce*3.fi
*InputSlice@Ff.s4*6.             *OutputCast_fp16_to_fp32@Ce.s4*4.
@SyncOp  @DmaCheckpointSet  @DmaCheckpointWait  @DummyOp2  @DummyOp3
```

`Fe`/`Ff` denote the flat layout and `Ce` the crouton (tiled) layout, and the compiler
inserts explicit `ForceFormat` conversions between them. Sixteen ops cost about 29 bytes
each over one op, which is a command list referencing kernels that already live in
`libQnnHtpV73Skel.so`, not compiled HTP code.

`Cast_fp32_to_fp16` on the input boundary independently confirms the fp16 finding in
htp-v73-datatype-gates-20260922.md, from a third direction.

## The context carries the compiler's configuration as plain text

Settings visible in the emitted binary include:

```
soc_type=SM8550  min_arch=73  hvx_threads=4  hmx_type=fg
tile_height=8  big_width_split=256  weight_sharing_channel_tile_size=64
native_k_channel_tile_size=256  v_channel_tile_size=64
disable_wide_croutons=true  tall_croutons=false
compress_weights=false  dlbc_weight_compression=0
compress_fp16_weights_to_mxfp6=false  sparsity_weight_compression=false
native_hmx_a16w4=true  unpack_2bitweights=false
relaxed_precision_flag=true  fold_relu_flag=true  force_conv_fusion=false
```

Four weight-compression knobs are off by default, and `native_hmx_a16w4=true` indicates an
int4-weight hardware path even though `tensorCreateGraphTensor` refuses a 4-bit tensor.

## Graph configs now work, and are verifiable

`graphCreate` takes a NULL-terminated array of `QnnGraph_Config_t*` (16 bytes: option at 0,
union at 8) each wrapping a `QnnHtpGraph_CustomConfig_t` (56 bytes: option at 0, union at
8). The direct path passed `IntPtr::Zero` and so accepted every default. With configs
plumbed through `Qnn.Native`'s `NewTrial`:

```
default      vtcm_size=8388608   vtcm_mb=4   hvx_threads=4
vtcm8        vtcm_size=8388608   vtcm_mb=4   hvx_threads=4
vtcm2        vtcm_size=2097152   vtcm_mb=4   hvx_threads=4
vtcm8+hvx2   vtcm_size=8388608   vtcm_mb=4   hvx_threads=2
```

Requesting 2 MB moved `vtcm_size` to exactly 2,097,152 and requesting two HVX threads moved
`hvx_threads` to 2, so the configs take effect and can be confirmed by reading the emitted
binary rather than inferred from timing.

`vtcm_mb` reads 4 in every case including when the grant is 8 MB, so it is not the granted
size. An earlier reading of that field as "our direct path only gets 4 MB" was wrong: the
default grant is already the full 8,388,608 bytes.
