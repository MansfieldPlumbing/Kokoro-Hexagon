# Integer HVX AdaIN moments over one real group

Baseline `8cc06b96e9dd5546dfd76da40f59967be55d1789` plus uncommitted emitter
and reference-test changes. Kernel: `src/emit/Kokoro.AdaInStatistics.ps1`.
SDK 6.4.0.2 assembler matches all 3016 emitted code bytes. V73 simulator runs
those bytes directly; `0/256` uint32 moment values differ from exact host
integer accumulation for 128 channels and 7801 frames in 244 native tiles.

Input is stock-captured resblocks.3's first AdaIN input, quantized symmetrically
with scale 0.0799673110 and represented as u8 = signed q + 128. The final
seven padded rows contain u8 zero for this reduction, so the complete group's
two raw moments exclude padding. This padding contract differs from the
convolution halo's u8 zero point 128 and must be preserved by the caller.
Moment output is sum(u8) and sum(u8*u8), interleaved in 32-channel blocks.
Actual frame count accompanies the moments for downstream normalization.

Instruction source: V73 HVX PRM `80-N2040-54`, Rev AB, word add,
unsigned-word logical shift, and word-by-low-unsigned-halfword multiply.
SDK manual SHA-256:
`D153DC5BE149FD90518438A10142BB9828A782EBD7F9551FF20DDBA92A435297`.

| Artifact | SHA-256 |
|---|---|
| Emitted body | `8560CC206F3999B9DF14F0CA8D5EBCE02443AA09ED3407E8F4028205BC5B1BA8` |
| Emitted ELF | `95A754554F7B03E5E1045447973C106198D667D1DE5A00694AAB979C00B6375F` |
| Input croutons | `F8B423D0562AB6F5FA88115DCF006199E75D016FA171D9E7EE98418DA8D37D6C` |
| Expected and observed moments | `C3BB0473D6F1668E3273BFC2C11C866C491078EBFB50795AD53C9F4F70192166` |
| Stock capture manifest | `DE740C02149986D66E8B5E7E6B0293AA8DE8EA106CBDA3BE0247CA9D412D92A5` |

Data/logs: `build/real-adain-statistics-20261006/`. Emission verification:
`build/integer-adain-statistics-check-20261006/KokoroAdaInStatistics/`.
References: `tools/New-KokoroAdaInStatisticsFixture.ps1` and
`tools/reference/hmx-sim/run-statistics.sh`.

This establishes exact integer reduction of quantized group data. Reciprocal
square root, style affine application, Snake, connected residual execution,
stock-FP32 propagated error, and physical-phone moment validation remain.
Simulator cycles are not device timing.
