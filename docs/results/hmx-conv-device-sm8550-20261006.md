# Emitted HMX int8 conv on the SM8550 arm64 physical device

The PowerShell-emitted runner (`src/emit/Kokoro.HmxConvRun.ps1`, wrapping
`New-KokoroHmxConvSteps`) ran on the SM8550 cDSP through the AndroidSMA preview host:
one unsigned-PD FastRPC session, one handle, method 2 per call. The runner itself casts
the HVX, DCVS (turbo) and HMX power votes, acquires VTCM and an HMX context through
`compute_resource_*`, copies inputs into VTCM, locks HVX and HMX, runs the conv, and
releases everything. No other DSP library of this project is loaded. Every call's 32768
outputs (odd bytes of the output croutons) are compared with the exact integer reference
from `tools/New-KokoroHmxConvFixture.ps1`.

Timing is the DSP `c31:30` counter (19.2 MHz) around the conv only; the closing read
follows a load of the last output word and `syncht`. Invoke time is host wall time for the
whole call, including power votes, VTCM acquire and the input/output copies.

| Shape | Frames | MACs per call | Calls | Exact | Median ticks | Conv µs | TMAC/s | Invoke ms (warm) |
|---|---:|---:|---:|---|---:|---:|---:|---:|
| C 128, K 3, D 1 | 256 | 12,582,912 | 20 | 20 / 20 | 42 | 2.19 | 5.75 | 0.87–0.96 |
| C 128, K 3, D 1 | 2048 | 100,663,296 | 20 | 20 / 20 | 294 | 15.31 | 6.57 | 3.7–4.5 |
| C 128, K 11, D 5 | 256 | 46,137,344 | 20 | 20 / 20 | 115 | 5.99 | 7.70 | 1.02–1.26 |
| C 256, K 7, D 3 | 256 | 117,440,512 | 20 | 20 / 20 | 348 | 18.12 | 6.48 | 1.83–2.11 |

Libraries: `libkokoro_hmx_conv_run_skel.so` per shape (2348 to 5620 code bytes), each
matched the SDK assembler byte for byte (`tools/Test-HexagonEmission.ps1 -Kernel
KokoroHmxConvRun`); 12 GOT imports, all `R_HEX_GLOB_DAT`. Receipts:
`build/hexagon-emission/hmxconvrun/<shape>/KokoroHmxConvRun/device-receipt-SM8550-*.txt`.

Caveats: the 256-frame C 128 K 3 row is near the counter's resolution (one tick = 2.4%). The schedule issues
one instruction per packet apart from the HMX activation/weight pair, uses the plain
`:single` read (half the rows of `:cm`), and keeps all operands resident in VTCM, so this
is not a DDR-streaming number. SM8635 has not been run.
