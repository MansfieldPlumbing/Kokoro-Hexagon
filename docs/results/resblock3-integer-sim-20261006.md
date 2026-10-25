# Connected integer resblocks.3 — V73 simulator, 2026-10-06

Baseline: `8cc06b96e9dd5546dfd76da40f59967be55d1789` plus local uncommitted
sources. The connected numerical run completed; speech quality and physical
device execution of this region remain unproven.

Input: the verified stock capture documented in
[the AdaIN/Snake receipt](adain-snake-integer-sim-20261006.md): 128 channels,
7,801 valid frames, 244 native time tiles, af_heart style entry 13, seed 17.

The same PowerShell-emitted bodies previously checked against SDK assembly run
all six AdaIN → Snake → W8A8 convolutions and three residual additions. Group
statistics are recomputed from each live preceding output across the complete
group. Dilations are 1,1,3,1,5,1, kernel size 3. Eight-tile convolution batches
include real neighboring halo rows and zero-point padding at group edges.
Residual additions reconcile the declared scales with integer Q16 coefficients.
Negative stock Snake alpha values are retained.

The reference C harness stages/serializes native buffers and calls emitted
bodies. It contains no floating-point or model arithmetic. It uses blocking
DDR/VTCM copies and SDK compilation for reference validation only; it is not
the product graph dispatcher or production DMA schedule. No timing claim.

**Arithmetic checks:** zero mismatches for all 1,536 live affine coefficients,
5,991,168 AdaIN values, 5,991,168 Snake values, and 2,995,584 residual values.
Observed affine/Snake/residual clipped values: 2.
Convolution output endpoint values (0 or 255): 3.
Convolution correctness is supported by the existing emitted-HMX checks; this
receipt compares every connected convolution boundary with stock FP32.

| Stage | Convolution SNR vs stock FP32 (dB) | Residual SNR vs stock (dB) |
|---|---:|---:|
| 0 | 24.223 | — |
| 1 | 19.093 | 24.767 |
| 2 | 16.114 | — |
| 3 | 17.760 | 20.953 |
| 4 | 19.996 | — |
| 5 | 17.059 | 18.363 |

**Final output:** SNR 18.362938 dB, RMSE 0.723159, maximum absolute error
7.520243 versus the captured stock block output. Output SHA-256:
`F0C28C628BFE6B4C420A01734F6DCE6991B9D9345A1F76B069B8EA9762E8EA28`.

No numerical acceptance threshold was defined for this experiment; its tensor SNR does not establish audio quality. The original stock AdaIN
class replay on identical quantized input already measures 25.370 dB SNR at stage 0;
the emitted integer affine adds much less error (55.380 dB versus that replay).
Shared activation-range calibration is therefore a demonstrated first-stage
loss source. Its contribution throughout the whole block needs further
calibration experiments; the final error must not be attributed solely to it.
Keep this connected harness and convolution path. First compare bounded
outlier-aware per-tensor calibration experiments and held-out propagated error.
See [the range-sensitivity receipt](activation-range-sensitivity-20261006.md).

All new bodies match the pinned SDK assembler. Existing HMX encoder checks:
2,713/2,713 pass. Additional integer instruction checks: 162/162 match and
10/10 invalid operands rejected. PowerShell AST and diff-whitespace checks pass.

Artifact identities (SHA-256):

- Eight-body/source artifact index: `5870BCCE1B0A08BA17125E9163A2DDC9B315CE98E2D60D3E4078F81C46C8C708`
- Connected fixture, hashing all 28 live input files: `650AE8167843D4D8DB2B87A83BD031A484610A2739EB86CE60C23446A78A0549`
- Complete boundary comparison receipt: `7E8F996C3B4FC63D9B94493CC8C915854DA311DB5EDBF132C71F1347440CAF78`
- Stock capture manifest: `DE740C02149986D66E8B5E7E6B0293AA8DE8EA106CBDA3BE0247CA9D412D92A5`

Generated artifacts and full boundary outputs remain in ignored
`build/connected-resblock3-integer-v3-20261006/`; the code/source index is
`build/integer-region-artifact-index-20261006.json`. Reproduce packing with
`tools/New-KokoroResBlockIntegerFixture.ps1`; the reference runner is
`tools/reference/hmx-sim/run-resblock-integer.sh` and comparisons use
`tools/reference/compare_integer_resblock.py`. No commit or push performed.
