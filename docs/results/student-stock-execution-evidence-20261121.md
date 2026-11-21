# Source-linked Kokoro execution evidence

The Student opens the execution indexes through its existing `OpenSpeechEvidence` path. Each `StudentStockExecution` points to the same `StudentTeacherObservation` used by the human/Zira comparison. Its activation and normalization objects point back to that execution. A normalization site links its input, output, parameters, scope geometry and, where available, the original live decoder token accumulators. A residual intervention links the stock execution, the modified execution, the site and the stated intention.

## Stock capture

The current trace records 731 stage observations per stock run. They include token IDs, embeddings, Q/K/V, twelve applications of shared ALBERT weights, double-precision normalized attention weights, attention context, feed-forward tensors and layer outputs, and the BERT projection. The trace includes predictor recurrent outputs, duration logits and decisions, shared and branch outputs, text encoder convolution inputs to normalization and post-activation outputs, recurrent outputs, and duration alignment. It includes predictor and decoder conditioning convolutions, residual sums, generator source draws, harmonic/noise components, excitation, source STFT, upsampling and convolution geometry, Snake outputs, residual branches, spectral head and waveform.

The generator input retains every float32 value in channel-major order at 80 ticks per second. Generator branches run at 800 and 4,800 frames per second, with a reflected left frame at the second upsampling stage. Source STFT uses a 20-sample window and five-sample hop on the 24 kHz source clock. Attention spans all query and key tokens in its invocation. Bidirectional recurrence and instance normalization introduce dependencies that can extend beyond any one phone interval.

The AdaIN inventory is 12 predictor, 10 decoder and 48 generator sites. Retained parameters are field-major in this order: mean, variance, standard deviation, epsilon-adjusted standard deviation, projected gamma, beta, gamma including the identity offset, normalization weight and bias, and ideal affine scale and offset. Applying that ideal affine in one operation can change float rounding. The retained input, output and staged arithmetic are the replay evidence. The decoder moments reuse the measurements supplied to its original live normalization. For the other sites the observer reproduces the stock float32 accumulation order on the retained input.

## Acquisition and verification

Run these scripts with the pinned PowerShell 7.7 runtime from the repository root.

```powershell
./build/pwsh77/runtime/pwsh.exe -NoProfile -File student/Invoke-StudentStockCorpus.ps1
./build/pwsh77/runtime/pwsh.exe -NoProfile -File student/Test-StudentStockCorpus.ps1 -SourceIdentity Gutenberg/11 -VerifyBuffers
```

The runner resumes from published indexes. Each tensor points to a GZip blob keyed by the SHA-256 of its exact little-endian bytes. A new stock index is published only after the 12 previously retained tensors and the original paired WAV match byte for byte. A fresh process can check identity, site inventory, dimensions and every referenced buffer checksum. Storage is shared across baseline and modified runs. The original human, Zira and Kokoro artifacts stay at their original source paths.

The first four stock runs covered two passages each from *Alice's Adventures in Wonderland* and *Word Study and English Grammar*. They retained 319,800 samples (13.325 seconds), 2,924 stage observations, 5,229,791,184 logical bytes and 4,365,117,567 new compressed bytes in a combined 274.42 seconds of per-passage execution. Those rates project about 111 GB for the 60 retained pairs (337.75 seconds), with variation across passages. That exceeds the initial 95 GB free on the acquisition volume. The runner checks space before new blob writes and can resume when space is available. Corpus-wide acquisition also needs paired renders for the remaining eligible source text.

A controlled run dropped only the final residual correction at `generator.resblocks.5.2` on the short *Word Study* passage. The run verified the same 12 upstream tensors, including the full generator input. Its 730 tensor descriptors added 4,573,698 compressed bytes in 56.86 seconds because shared buffers were reused. This intervention provides a local test of functional contribution for that invocation.

## Procedural runs and remaining gaps

`-Procedural` observes the earlier Student prosody controller's rule durations, replay ratios, target and running states, realized F0 and N, downstream activations and all 512 generator channels. The legacy corpus-backed inventory requires its original corpus input. `-ClockExperimentPath` accepts the retained clock experiment as historical input and reconstructs that three-passage training setup using its pinned phonemizer. Its new tensors use the same typed bank. Procedural and stock paths can produce different phones and durations and keep separate clocks.

Remaining instrumentation includes recurrent gates and cell trajectories, some pre/post normalization states outside AdaIN, and explicit linguistic candidate edges at activation granularity. Attention, convolution geometry and complete normalization scopes are available, with source relationships through the original typed document and sentence owners. Full covariance and distribution calculations can use the retained arrays. The bank has no verified acquired percept or transferable executable capability from these captures yet.
