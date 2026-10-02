# Style-mutation control probe, 2026-09-28

## Scope

This is an offline PowerShell-hosted ONNX differential experiment, not a product inference path. `tools/reference/Test-KokoroStyleMutationSearch.ps1` uses the pinned FP32 ONNX model and the existing fixed-input PCM references. It perturbs one bounded control: a scalar multiplier applied to the selected 256-value voice row. Phoneme IDs, voice row, speed, model file, and reference waveform stay fixed. No Python process, QNN context, or direct Hexagon path participates.

The evaluator samples 32 evenly placed Hann-windowed 1024-point FFT frames. Its provisional score is mean absolute log-magnitude difference plus relative output-sample-count difference. This is sufficient to exercise deterministic feedback, but is not a complete speech-correctness gate: phase, duration trajectory, phoneme accuracy, and listening remain separate checks.

The controller begins at style scale 1.125 with step 0.0625. It evaluates bounded deterministic neighboring scales, retains only strictly improving candidates, allows three distinct worse evaluations, then restores the best scale and halves the step. It never promotes a worse candidate. A fresh scale-1 run is required to reproduce the saved baseline waveform byte-for-byte before the search begins.

## Results

| Case | Phoneme characters | Initial score | Best score/scale | Worse trials before rollback | Repeated run |
| --- | ---: | ---: | ---: | ---: | --- |
| `marco-001` | 7 | 0.039266248 | 0 / 1.0 | 3 | Exact trial sequence and WAV files |
| `marco-019` | 94 | 0.012976670 | 0 / 1.0 | 3 | Not repeated |

Both cases recovered a byte-exact match to their saved ONNX PCM reference and executed one rollback with step 0.03125. The complete trial receipts and the initial/best WAV files are in ignored `build/style-mutation-search-001/` and `build/style-mutation-search-019/`. A separate process repeated `marco-001` with the same trial scores, decisions, and WAV hashes.

## AdaIN boundary

`tools/Test-KokoroAdaInStaticSpecialization.ps1` read a pinned stock AdaIN style projection and the pinned `af_heart` row. For a 1.125 style mutation, precomputed per-channel gain/shift controls matched direct projection to within 2.9×10⁻⁷. This supports compilation of fixed-voice style-affine controls, with bounded live deltas, while retaining the normalization operation.

For a deliberately shifted synthetic activation, the stock AdaIN output was unchanged, but a fixed affine fitted to the original activation missed the shifted output by 5.84955 maximum absolute units. Its training-input error was 5×10⁻⁸. This is an operator-level counterexample to replacing current-segment instance statistics with a voice-only static affine; it is not a measured failure of a trained alternate architecture. The ignored operator receipt is `build/adain-static-specialization-002/receipt.json`.

The control-loop success does not establish AdaIN removal, compiled weight mutation, direct-DSP execution, or audible device speech. The next whole-model test needs a same-input directly emitted candidate PCM or an exposed intermediate consumer boundary, compared against the pinned source contract and this separately labeled ONNX differential reference.
