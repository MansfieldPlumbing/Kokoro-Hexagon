# Lockstep ring address specialization on SM8550

The exact ring-parity candidate measured **103.776 and 104.087 ms** on the
primary lighthouse fixture, around a **105.057 ms** three-instruction fill
control. The candidate saved 1.281 and 0.970 ms in this comparison. Its
faster primary trial reached **113.47×** and finished 5.651 ms above the
98.125 ms threshold for 120×. The warm timing ranges overlapped.

The work started at local revision
`15549f1fc51492133a984ed1933803904c5e2b78`. The device was the same SM8550
(Hexagon V73) used for the preceding exact fill experiment, selected
through the pinned WinUSB PowerShell ADB client.

## Change

A lockstep ring holds two batches. For batch width `B`, block `j`
and worker offset `d`, the ring slot is `(B*j + d) mod (2*B)`. Replacing
`j` with its parity preserves this slot, including the previous tile at
offset −1. The generated interior loop already has an even and an odd
body to choose the mirrored writes. Each body can therefore name its
VTCM slots at emission time. The candidate still uses the live block
number for input and output DMA addresses, neighbor progress and edge
handling. Publication order, guards, convolution products and all
activation and PCM arithmetic are preserved.

The emitted code shrank by 100,128 bytes. The candidate ELF SHA-256 was
`E087F9DE5719AC95E6843C321E13C799314CADE57E1F5B5C49E1021CAAD81681`.
The control ELF SHA-256 was
`83E9FC7E9CFBD1C8906396023D37F1BDE85CB0847F5C5BBCF41C5405A8B2BED4`.

## Device measurements

| Trial | Warm DSP median ms | Warm DSP range ms | DSP realtime | Host invoke ms | Host setup ms | Invoke outside region ms | Output handling ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Candidate A | 103.776 | 102.558–105.405 | 113.47× | 144.129 | 3.026 | 39.913 | 1.241 |
| Three-instruction fill control | 105.057 | 103.306–105.985 | 112.08× | 154.280 | 2.829 | 48.770 | 1.290 |
| Candidate B | 104.087 | 102.963–104.867 | 113.13× | 146.883 | 2.938 | 42.885 | 1.143 |
| Candidate, second seed | 103.369 | 102.936–104.146 | 113.91× | 150.974 | 3.248 | 47.053 | 1.563 |

All primary trials used one cold and twelve warm invocations. The second
seed used one cold and four warm invocations. Each returned 282,600 samples
at 24 kHz. The probe verified ELF staging and startup restoration on every
trial, and every invocation matched the full reference PCM hash.

- Primary PCM `B61ACE349E3090D910E1F6E6EB20378FE70F89D38DD421B4C0AF978BFBE1A6BF`
- Second-seed PCM `B4DDB8805D48110587F1752F7DC4D7A653BE05EB235FE1D201CE4966DA50B52F`

Rebuild `section-lockstep-ring-parity` and the control
`section-snake-fill-three` with the [experiment tooling](../../tools/experiments/generator-throughput-20261119).
Use the existing probe and fixture commands from the
[packed-fraction experiment](generator-exact-packed-fraction-sm8550-20261120.md).
The [per-invocation CSV](../../tools/experiments/generator-throughput-20261119/exact-ring-parity-runs.csv)
includes cold run zero.
