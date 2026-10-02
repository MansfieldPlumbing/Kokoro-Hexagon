# Deterministic delta-search control probe (2026-09-28)

This is an offline reference-harness result, not a product inference path or a
direct-Hexagon speech result. The candidate generator is
`src/control/Kokoro.DeterministicSearch.psm1`; its evaluator is a trusted,
author-supplied callback. `src/control/Kokoro.DeltaMemory.psm1` stores bounded,
data-only, SHA-256-addressed trial records and returns non-authorizing advice.
Neither module is included in the product dispatch path.

The `marco-001` probe used the pinned stock ONNX model solely as an oracle for
waveform comparison. The objective was the existing 32-frame Hann-windowed
1024-point log-magnitude FFT error plus relative sample-length error. Starting
at voice-row scale 1.125 with step 0.0625, the deterministic search evaluated
six coordinates, allowed three non-improving trials, and backtracked once.
Initial score was 0.03926624773116257; the best coordinate was the unmodified
scale 1.0 with score zero and an exact baseline waveform. The fresh unmodified
run passed its exact-waveform self-check before search.

Every evaluated trial produced one immutable delta record: six records and six
receipt digests. All six imported successfully with digest and schema checks;
the saved outcome distribution was two `VerifiedBenefit` (improvement of this
FFT objective), three `Regression`, and one `Inconclusive` initial state. A
matching proposal retrieved one saved benefit as `PreferForTest` while
`MayExecute` and `MayPromote` remained false. These outcomes do not establish
causal transfer to other utterances, voices, model parameters, or DSP kernels.

Verification commands:

```powershell
& tools/Test-KokoroDeterministicSearch.ps1
& tools/Test-KokoroDeltaMemory.ps1
& tools/reference/Test-KokoroStyleMutationSearch.ps1 -CaseId marco-001 -InitialScale 1.125 -InitialStep 0.0625 -MaxEvaluations 8 -OutputDirectory build/style-mutation-search-controller-deltas-001
& tools/Test-ProductionClosure.ps1
```

The machine-local, ignored receipt is
`build/style-mutation-search-controller-deltas-001/receipt.json`; its `deltas/`
directory contains the six addressed records. This probe used only a global
voice-row scale. It did not test state-conditioned AdaIN replacement or the
full emitted phoneme-to-PCM graph. A future search can use a directly emitted
candidate only after its waveform exists and passes stock-weight equivalence;
until then, ONNX FFT feedback cannot certify or optimize the direct DSP path.
