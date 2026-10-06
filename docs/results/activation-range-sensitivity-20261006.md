# Activation-range sensitivity — stock AdaIN replay, 2026-10-06

This is a bounded diagnostic on one existing capture, not production calibration
or a new connected-DSP result. Baseline repository commit:
`8cc06b96e9dd5546dfd76da40f59967be55d1789`, with local uncommitted tools.

Source: Kokoro `dfb907a02bba8152ca444717ca5d78747ccb4bec`, original `AdaIN1d`
class and its captured checkpoint parameters. Capture manifest SHA-256:
`DE740C02149986D66E8B5E7E6B0293AA8DE8EA106CBDA3BE0247CA9D412D92A5`.
Input: `resblocks.3` stage 0, 128 channels, 7,801 frames, af_heart style entry 13.
The unquantized original-class replay matched the captured output within 1e-5.

The reference tool tries symmetric signed int8 ranges with zero point 128,
matching the current emitted path's encoding convention. It uses full range,
four absolute-value percentiles, and a bounded 128-candidate search over an
8,192-bin midpoint histogram. The histogram search is an MSE approximation;
it is not a reproduction of AIMET TF Enhanced. Candidates are replayed through
the original stock AdaIN class on Windows, with all group frames retained.

| Range | Input SNR (dB) | AdaIN SNR vs stock (dB) | Values outside range |
|---|---:|---:|---:|
| Full range | 34.859 | 25.370 | 0 |
| Absolute percentile 99 | 23.497 | 25.518 | 9,986 |
| Absolute percentile 99.9 | 29.017 | 29.976 | 999 |
| Absolute percentile 99.99 | 36.736 | 28.654 | 100 |
| Absolute percentile 99.999 | 36.359 | 26.918 | 10 |
| Histogram-MSE candidate | 36.921 | 27.972 | 50 |

Range selection measurably affects the downstream normalization. The best
input-tensor MSE candidate is not the best AdaIN candidate in this experiment.
The 99.9 candidate is diagnostic evidence only: its threshold was chosen from
this same capture, without a calibration/holdout split. It has not been replayed
through the connected emitted block or evaluated as audio.

Published guidance: [AIMET QuantSim](https://github.com/qualcomm/aimet/blob/6f1416e0bc3868a1dc43ce48072a4d5fe778f042/Docs/tutorials/quantsim.rst)
describes min/max outlier sensitivity, SQNR/MSE-based range selection, hardware
granularity constraints, and representative calibration data. Its 500–1,000
sample recommendation is general guidance, not a Kokoro-specific prerequisite.
CNN recipe percentiles and default precision do not define this model's ranges
or its speech-quality acceptance criteria.

Next experiment: use a small, explicit pilot spanning voices and phoneme/group
lengths, with separate calibration and holdout groups. Compare full range,
percentile and histogram-MSE candidates under the current per-tensor convention.
Freeze each candidate encoding set before replaying the entire emitted block on
holdouts. Track clipping, channel variance, each boundary and propagated block
error; expand coverage as stability requires. Preserve the kernels and native
layout. Quantization diagnostics should support progress toward phone speech;
no arbitrary tensor-SNR threshold or fixed corpus count replaces audio evidence.

Tool: `tools/reference/analyze_activation_ranges.py`. Full numerical receipt:
ignored `build/activation-range-sensitivity-stage0-20261006.json`.
