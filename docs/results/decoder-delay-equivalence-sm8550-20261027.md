# Decoder with delayed tensors against the layer job, SM8550 (2026-10-27)

Kokoro-Hexagon at the commit that adds this record (parent `a77eb6b`). First milestone of the
depth-first decoder: every convolution reads only rows at or before the row it writes, as whole-tensor jobs, before
any span loop.

## Method

The delayed decoder job (`New-KokoroDecoder16RunSteps -Delayed`, emission parameter `DecoderDelayed`) gives each
convolution a tap delay equal to its lookahead, so each tensor lags its input:

| Layer | Tap delay | Output delay |
| --- | ---: | --- |
| Kernel-3 conv1, conv2 | 1 | input + 1 frame (decode.3: + 1 tick) |
| 1x1 shortcut | 2 | input + 2 frames |
| `asr_res` (1x1) into block j's output | 2j + 2 | 2j + 2 frames |
| F0 and N stride convs into block j's output | rows start at 2j + 2 | 2j + 2 frames |
| decode.3 pool (k 3, stride 2) | one row pair | 2 x 8 + 2 = 18 ticks |

Block inputs sit at 0, 2, 4, 6 and 8 frames; the decode.3 shortcut reaches 10 frames, doubled to 20 ticks, and the
residual branch reaches 18 + 1 + 1 = 20 ticks. x leaves the job 20 ticks late. Rows before a tensor's delay hold zero
(conv-input zero in the windows) as rows past its frame count do. Tensors cover F + 10 frames and 2F + 20 ticks; the
input stays at F frames.

Without `-Delayed`, the job's instructions are unchanged: six existing decoder libraries (fixed and run-time frames;
Accumulate, Export, Constants and Direct moments; a dump point) emit with their previous SHA-256.

The check is `Run -Case decoder-delay-equivalence` (`Test-KokoroDecoderDelayEquivalence`). For each frame count, a
slice from frame 0 of the stock decoder capture's inputs (`decoder.input.0` to `.2`, voice `af_heart`) is packed once.
The layer job and the delayed job then run in Direct mode on the phone with the same input, tables, weights and
decoder voice base K/M. Layer x at tick n is compared byte for byte with delayed x at tick n + 20. Two controls guard
the comparison: the same comparison without the shift must find differences, and x must not be the zero fill.

## Results

| Frames | Compared bytes | Different | Different without the shift | Non-zero x vectors | Layer DSP | Delayed DSP |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 54 | 110,592 | 0 | 109,656 | 804 of 864 | 2.88 ms | 3.01 ms |
| 64 | 131,072 | 0 | 129,929 | 1,024 of 1,024 | 2.87 ms | 3.99 ms |
| 100 | 204,800 | 0 | 202,878 | 1,552 of 1,600 | 4.90 ms | 5.05 ms |
| 118 | 241,664 | 0 | 239,337 | 1,828 of 1,888 | 4.97 ms | 5.11 ms |

x is identical at every frame count, and the estimated output delay of 20 ticks is confirmed. DSP times are from one
run each and are not a timing measurement.

## Limits

The delayed job still holds whole tensors in VTCM. At a run-time capacity of 128 frames its layout exceeds the admitted
8 MiB (138 frames need a fifth tile), so this check runs fixed frame counts up to 118 frames. The delayed form is
supported only with supplied coefficients (Direct, Constants): it computes no moments over the lead rows.

Receipt: `build/decoder-delay-equivalence-20261028T025302` (decoder-delay-equivalence.clixml, one directory of job
inputs per frame count).
