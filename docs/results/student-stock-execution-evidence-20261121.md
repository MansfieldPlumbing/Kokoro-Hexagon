# Source-linked Kokoro execution evidence

The Student opens the execution indexes through its existing `OpenSpeechEvidence` path. Each `StudentStockExecution` points to the same `StudentTeacherObservation` used by the human/Zira comparison. Its activation and normalization objects point back to that execution. A normalization site links its input, output, parameters, scope geometry and, where available, the original live decoder token accumulators. A residual intervention links the stock execution, the modified execution, the site and the stated intention.

The relevant type boundary follows the operations the Student can perform. A normalized activation has coordinates and values. A normalization site has an invocation scope and can be replayed. An intervention has a baseline and a stated change. A measured consequence belongs to a run and can contradict its intention. A verified capability has applicability conditions and reusable behavior. The field can represent these distinctions with existing CLR and ETS semantics while keeping the numerical buffers compact.

## Stock capture

The baseline trace records 731 stage observations per stock run. The inventory comprises 125 ALBERT, 103 predictor, 15 text encoder, 104 decoder, 382 generator and two style tensors. They include token IDs, embeddings, Q/K/V, twelve applications of shared ALBERT weights, double-precision normalized attention weights, attention context, feed-forward tensors and layer outputs, and the BERT projection. The trace includes predictor recurrent outputs, duration logits and decisions, shared and branch outputs, text encoder convolution inputs to normalization and post-activation outputs, recurrent outputs, and duration alignment. It includes predictor and decoder conditioning convolutions, residual sums, generator source draws, harmonic/noise components, excitation, source STFT, upsampling and convolution geometry, Snake outputs, residual branches, spectral head and waveform.

The generator input retains every float32 value in channel-major order at 80 ticks per second. Generator branches run at 800 and 4,800 frames per second, with a reflected left frame at the second upsampling stage. Source STFT uses a 20-sample window and five-sample hop on the 24 kHz source clock. Attention spans all query and key tokens in its invocation. Bidirectional recurrence and instance normalization introduce dependencies that can extend beyond any one phone interval.

The AdaIN inventory is 12 predictor, 10 decoder and 48 generator sites. Retained parameters are field-major in this order: mean, variance, standard deviation, epsilon-adjusted standard deviation, projected gamma, beta, gamma including the identity offset, normalization weight and bias, and ideal affine scale and offset. Applying that ideal affine in one operation can change float rounding. The retained input, output and staged arithmetic are the replay evidence. The decoder moments reuse the measurements supplied to its original live normalization. For the other sites the observer reproduces the stock float32 accumulation order on the retained input.

## Acquisition and verification

Run these scripts with the pinned PowerShell 7.7 runtime from the repository root.

```powershell
./build/pwsh77/runtime/pwsh.exe -NoProfile -File student/Invoke-StudentStockCorpus.ps1 -HalfCorpus -MaxStoreGB 70
./build/pwsh77/runtime/pwsh.exe -NoProfile -File student/Test-StudentStockCorpus.ps1 -SourceIdentity Gutenberg/11 -VerifyBuffers
```

The runner resumes from published indexes. Each tensor points to a GZip blob keyed by the SHA-256 of its exact little-endian bytes. A new stock index is published only after the 12 previously retained tensors and the original paired WAV match byte for byte. A fresh process can check identity, site inventory, dimensions and every referenced buffer checksum. Storage is shared across baseline and modified runs. The original human, Zira and Kokoro artifacts stay at their original source paths.

The first four stock runs covered two passages each from *Alice's Adventures in Wonderland* and *Word Study and English Grammar*. They retained 319,800 samples (13.325 seconds), 2,924 stage observations, 5,229,791,184 logical bytes and 4,365,117,567 new compressed bytes in a combined 274.42 seconds of per-passage execution. Those rates project about 111 GB for the original pool of 60 retained pairs (337.75 seconds), with variation across passages.

The halved plan keeps existing traces and chooses additional passages by distance from the already chosen source offsets within each work. Its 18 *Alice* passages cover 81.825 stock seconds and its 12 *Word Study* passages cover 74.750 stock seconds. The projected stock buffer cost is about 51 GB, leaving space for procedural traces and interventions. The runner checks both the exact compressed store size and available volume space. `-PlanOnly` reports the selected scope without rendering. `-BufferDirectory` can place new buffers on a separate volume while retaining access to the original store.

A controlled run dropped only the final residual correction at `generator.resblocks.5.2` on the short *Word Study* passage. The run verified the same 12 upstream tensors, including the full generator input. Its 730 tensor descriptors added 4,573,698 compressed bytes in 56.86 seconds because shared buffers were reused. A fresh process found 34,800 of 34,800 float waveform samples changed, with a peak absolute difference of 0.330638 and a waveform SNR of 1.319459 dB relative to baseline. This intervention provides a local test of functional contribution for that invocation.

## Procedural runs and remaining gaps

`-Procedural` observes the earlier Student prosody controller's rule durations, replay ratios, target and running states, realized F0 and N, downstream activations and all 512 generator channels. The legacy corpus-backed inventory requires its original corpus input. `-ClockExperimentPath` accepts the retained clock experiment as historical input and reconstructs that three-passage training setup using its pinned phonemizer. Six source-linked runs cover four Alice passages and two *Word Study* passages, totaling 16.75 seconds. They contain 3,068 observations and added 5,302,312,094 compressed bytes in 551.47 seconds of per-passage execution. The historical phonemizer rejected Alice offsets 4182, 98122 and 143700. The bank exposes the retained failures as typed unresolved procedural pronunciations linked to the original teacher observation.

`-FrontStates` enriches existing baselines through a front-end replay. The first two replays each retained 48 observations and reproduced all 11 original front-end tensors byte for byte. They retain all six recurrent stages' actual gates, cell states and hidden states by direction and step, plus additional pre- and post-normalization states. The two replays added 27,708,443 compressed bytes in 27.19 seconds, excluding startup.

Explicit linguistic candidate edges at activation granularity and some intermediate normalization and spectral transformations remain open. Attention, convolution geometry and complete normalization scopes are available, with source relationships through the original typed document, sentence owners and word occurrence indices. Full covariance and distribution calculations can use the retained arrays. The bank has no verified acquired percept or transferable executable capability from these captures yet.
