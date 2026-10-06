# Integer AdaIN and Snake, real full-group input — V73 simulator

Baseline: `8cc06b96e9dd5546dfd76da40f59967be55d1789`, with local uncommitted
emitter/fixture changes. This is simulator evidence; no device timing or speech claim.

Stock source: Kokoro `dfb907a02bba8152ca444717ca5d78747ccb4bec`,
`kokoro/istftnet.py:20-31,69-81`. Checkpoint SHA-256:
`496DBA118D1A58F5F3DB2EFC88DBDC216E0483FC89FE6E47EE1F2C53F18AD1E4`.
Capture: `resblocks.3`, af_heart, style entry 13, seed 17, stock PyTorch
2.14.0+cpu, 548 checkpoint tensors verified. Capture manifest SHA-256:
`DE740C02149986D66E8B5E7E6B0293AA8DE8EA106CBDA3BE0247CA9D412D92A5`.

The emitted moment reduction, integer coefficient calculation, and HVX affine
pass ran consecutively over 128 channels and all 7,801 valid frames. The signed
Q8 affine output then supplied the emitted HVX Snake kernel. Native crouton
channel/time locations remain the same; intermediate lanes hold signed Q8
halfwords, and Snake returns unsigned W8A8 input bytes.

| Check | Result |
|---|---:|
| Live Q16 gain/offset vs exact integer contract | 0/256 mismatches |
| AdaIN Q8 output vs integer contract | 0/998,528 mismatches |
| AdaIN clipping | 0 |
| AdaIN vs original stock FP32 capture | 25.365 dB SNR; RMSE 0.072643 |
| Original stock AdaIN replay on the same quantized input vs capture | 25.370 dB; RMSE 0.072606 |
| Integer AdaIN vs that original-class replay | 55.380 dB; RMSE 0.002293 |
| Snake output vs integer contract | 0/998,528 mismatches |
| Snake clipping | 0 |
| Integer Snake before final requantization vs exact Snake on identical input | 57.775 dB; RMSE 0.002303 |
| Connected AdaIN → Snake vs stock Snake capture | 23.315 dB; RMSE 0.121715 |

AdaIN uses `D=N*sum(u²)-sum(u)²+round(eps*N²/sx²)`, with the stock
InstanceNorm epsilon `1e-5`. Trial-bit integer square root and division produce
the live affine coefficients. Style FC and learned norm affine fold offline
into per-channel Q16 coefficients. Full-group moments exclude padded rows.
No tile-local statistics, float DSP arithmetic, or host inference math is used.

Snake uses a shared 256-interval periodic sin² table, Q15 ordinates, eight
fractional interpolation bits, signed per-channel phase and reciprocal-alpha
coefficients. Negative checkpoint alpha values are retained. The published
fixed-point lookup/interpolation method was researched in
[CMSIS-DSP arm_sin_q31.c](https://github.com/ARM-software/CMSIS-DSP/blob/d5717e454fec0337bef114a21f1d2d01d74f2701/Source/FastMathFunctions/arm_sin_q31.c).
Hexagon forms come from SDK 6.4.0.2 and V73 HVX PRM Rev. AB, including its
shuffled-table and lookup-match rules. No external C implementation is shipped.

All three new bodies match SDK assembly bytes. The existing 2,713 HMX encoder
cases still pass; another 162 integer-instruction cases match, and 10 invalid
integer operands are rejected. New PowerShell sources parse and diff whitespace
checks pass.

Emitted body SHA-256:

- Coefficients (1,092 bytes): `6BA34FDDDD410386947A3CA44256D88A145E39F0A9F12348FAF4B759E5ABDF44`
- Affine (5,352 bytes): `9DBF297081D72F39C45163D3B8CAB1662457037A4863AD52F8376006E6FB23D9`
- Snake (2,836 bytes): `4CD819FCD2CC2857DF2F220F85EB71B3498A4220BE506B22338DBE06A52B4599`
- AdaIN output: `232316B7FB366D6B38528196E73DC609FB2F7A045CDE09626175BFEE362C5BF7`
- Snake output: `D83E30800E074980BDEDA8F7E85DB60C4E69E5135AB4A5EAA254B6837F9CC4ED`

Inputs and full receipts are in ignored `build/real-integer-adain-stage0-20261006/`
and `build/real-integer-snake-stage0-20261006/`. The stock-range calibration is
experimental. These results locate most first-stage loss in input quantization;
they do not establish acceptable connected-block or audible speech quality.
