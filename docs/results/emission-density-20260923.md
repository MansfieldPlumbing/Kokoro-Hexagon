# What our context binaries are actually made of

Deflate ratio and windowed byte entropy, comparing our emissions against a shipped
QNN artifact for the same silicon. Lower ratio means more redundancy.

## Reference

LocalDream `AbsoluteReality_qnn2.28_8gen2.zip` (1,054,661,172 bytes, `xororz/sd-qnn`).
Read from the zip central directory by HTTP range, without downloading the archive: an
8gen2 build, so V73, the same part as ours. No 8gen3 build of this model is published.

```
unet.bin         880,827,736 -> 684,007,471   77.7%
vae_decoder.bin   59,945,848 ->  45,718,764   76.3%
vae_encoder.bin   41,438,176 ->  31,058,209   75.0%
token_emb.bin     75,890,688 ->  69,264,664   91.3%
patches           15-23 MB each               98-99%
```

## Ours

```
front_c160_fp16.bin              69,615,616 -> 62,581,973   89.9%
gen_c64_banal_ctx_qnn.bin        41,672,704 -> 34,708,452   83.3%
gen_nin_gb_c160_fp16_vtcm8.bin   53,366,784 -> 38,109,644   71.4%
```

Our front end and the unoptimized generator are denser than their UNet. The optimized
generator is not: 71.4% is the loosest artifact we have, about 15 MB of slack in 53 MB.

## Where the slack is

`gen_nin_gb_c160_fp16_vtcm8.bin`, 814 windows of 64 KiB:

```
p10=4.44  p50=7.34  p90=7.42  mean=6.38 bits/byte
low-entropy (<6.5): 306 of 814 windows, spread from 0 MB to 51 MB
```

Two populations, by composition:

```
win 3    ent=1.10  zeroBytes=75.0%  fp16 hiByte=0.00  loByte=1.58
win 120  ent=4.26  zeroBytes=47.0%  fp16 hiByte=3.04  loByte=4.74
win 400  ent=7.42  zeroBytes= 0.4%  fp16 hiByte=5.74  loByte=7.99
win 700  ent=7.45  zeroBytes= 0.6%  fp16 hiByte=5.83  loByte=7.99
```

The high windows are fp16 weights: the mantissa byte is at 7.99 of 8 bits and effectively
incompressible, while the exponent byte sits at 5.8. That gap is the format's own cost,
about 1.1 bits per byte of weight data.

The low windows are not weights. Window 3 is 75% zero bytes with a high-byte entropy of
exactly zero, which is integer fields zero-extended into wider slots — tensor ids, ranks,
dimensions, offsets.

It is not duplicated structure. Deflating two distant low-entropy windows together against
separately saves -0.7%, so they are not copies of one another; each op describes itself
verbosely with distinct values, and deflate removes the zeros within a window but finds
nothing shared across windows.

## Consequences

Two independent levers that do not overlap. int8 removes the exponent waste and halves the
weight payload, on ops that accept it — Conv2d does, measured. Descriptor density is the
other roughly 20 MB and is only reachable by emitting ourselves, since the verbosity comes
from a format that describes every node in full rather than referencing shared structure.

Their density advantage is partly just quantization: a dense int8 blob is near
incompressible, while fp16 carries a correlated high byte in every value we store.
