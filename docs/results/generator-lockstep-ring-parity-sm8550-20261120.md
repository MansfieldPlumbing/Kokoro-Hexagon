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

## Wrapping halfword doubling

The following trial added one change to the ring-parity variant. Snake's
folded halfword argument uses a wrapping left shift by one. A non-saturating
halfword add of the value to itself produces the same low 16 bits for
every input. The candidate uses the add and drops the redundant scalar
shift constant. This reduces demand for shift issue inside the four-way
unrolled fill. The static non-mirrored body at either channel width has
202 instructions across 108 packet records, compared with 203 across 107
before. The timing gain cannot be explained by a smaller static packet
count alone.

| Trial | Warm DSP median ms | Warm DSP range ms | DSP realtime | Host invoke ms | Host setup ms | Invoke outside region ms | Output handling ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Candidate A | 102.695 | 101.404–103.560 | 114.66× | 145.980 | 3.300 | 43.910 | 1.133 |
| Ring-parity control | 104.112 | 103.000–104.595 | 113.10× | 149.996 | 3.298 | 45.522 | 1.327 |
| Candidate B | 103.007 | 101.849–103.527 | 114.31× | 150.455 | 2.989 | 47.487 | 1.321 |
| Candidate, second seed | 102.711 | 102.023–103.661 | 114.64× | 146.539 | 3.588 | 44.246 | 1.530 |

The candidate medians improved by 1.417 and 1.104 ms against the fresh
ring-parity control. The faster result leaves 4.570 ms to reach 120×.
The same 13/13/13/5 invocation protocol verified both PCM hashes, the
282,600-sample duration and startup restoration again. Rebuild
`section-lockstep-ring-double` using the same commands. Its ELF SHA-256
was `60F03A2FE578584B3FBE9B253CFD05A7824C761A8E0002A56D2045F12D6ECD3F`.
[Per-invocation timing and verification](../../tools/experiments/generator-throughput-20261119/exact-ring-double-runs.csv).

## Even-row halfword selection

The even row fed to the signed odd-halfword multiply originally moved
into position through a word shift. An even-halfword shuffle with two
identical inputs places that same signed value in the high halfword.
The multiply consumes only the high halfword, so the duplicated low
halfword cannot affect it. The packetizer admits the shuffle as a vector
ALU operation. The static standalone body has 201 instructions across
108 packets.

| Trial | Warm DSP median ms | Warm DSP range ms | DSP realtime | Host invoke ms | Host setup ms | Invoke outside region ms | Output handling ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Candidate A | 102.295 | 101.115–103.281 | 115.11× | 151.920 | 2.973 | 49.249 | 1.236 |
| Wrapping-double control | 102.868 | 101.578–103.648 | 114.47× | 149.079 | 3.256 | 46.517 | 1.158 |
| Candidate B | 102.228 | 101.171–103.880 | 115.18× | 146.917 | 2.938 | 44.328 | 1.290 |
| Candidate, second seed | 101.729 | 101.241–102.403 | 115.75× | 145.597 | 2.817 | 43.775 | 2.003 |

The candidate medians led by 0.573 and 0.640 ms around the control.
The 102.228 ms primary median is 4.103 ms above the 120× budget. The
same 13/13/13/5 invocation protocol confirmed both reference PCM hashes
and startup restoration. Rebuild `section-lockstep-ring-shuffle`.
Its ELF SHA-256 was
`6FC34DBF963CBE0688A1F383CD0F97929F625A2F4659F98941EB18CF784717DE`.
[Per-invocation timing and verification](../../tools/experiments/generator-throughput-20261119/exact-ring-shuffle-runs.csv).

## Screening results

A progress-counter variant computed the same interior block base once per
tile and reused it for all six stages. It produced exact PCM and ran at
105.100 ms in a four-warm screen. A low-plane variant replaced the
halfword shift with an even-byte shuffle using the existing mask's zero
bytes. It preserved PCM and measured 102.848 ms when added to the
wrapping-double control, close to the control's 102.868 ms median. Neither
screen gave a clear gain. The
[screening CSV](../../tools/experiments/generator-throughput-20261119/exact-ring-screening-runs.csv)
includes the corresponding ELF hashes, cold runs and restoration checks.

The remaining 4.103 ms is on DSP. Prior instrumentation points to repeated
fill and combine work and to the chunked 256-channel section. The next
profile can check those costs in the current binary after the instruction
substitutions. Lock wait, producer readiness and execution under the
matrix lock should remain separate measurements.
