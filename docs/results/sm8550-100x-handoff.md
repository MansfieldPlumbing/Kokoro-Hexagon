# Kokoro on SM8550 — handoff for the 100× milestone

19 November 2026. Start here after switching accounts. Checkout on Scott’s machine is C:/Dev/Kokoro-Hexagon. Use pwsh and the repository’s adb.ps1 for phone work. The implementation is authored in PowerShell and emits Hexagon code that executes on the DSP. The last measured production code revision was 371ee3e. Commit 89659d3 added the [handoff timing report](generator-hmx-handoff-sm8550-20261119.md).

## What counts as success

On the 11.775 s lighthouse passage (282,600 mono samples at 24 kHz), 100× requires **117.75 ms**. The immediate target is warm generator DSP time with verified audio quality. Record generator wall time separately so DSP throughput and user-visible latency can both be reproduced. The stretch goal applies the same budget to text through returned PCM, including the procedural Student. Pin the input, voice/style, seed, artifacts, warmup protocol, timing boundaries and output duration. Publish per-run times and PCM hashes.

The reported Core ML result was 27.4 s in about 319 ms on iPhone 15 Pro Max, from prepared IDs to PCM. For a public comparison measure that boundary too, disclose passage length and device, and label speed as audio seconds per elapsed second. Object-to-PCM and object-to-Opus are additional product measurements. [Core ML benchmark revision](https://github.com/mattmireles/kokoro-coreml/tree/903f1fc1)

## Where the time went

| Lighthouse measurement | Result | Interpretation |
|---|---:|---|
| Queued production generator, instrumentation off | 227.08 ms median over seven warm runs, 224.59–228.07 ms | 51.85× DSP throughput. Reaching 100× requires saving 109.33 ms. |
| Queued handoff trace / synchronous weight control | 226.17 / 239.04 ms whole generator | Keep queued DMA as the baseline. At the traced handoff the exposed queued fence was at most one 19.2 MHz tick. |
| Fresh unmarked / fill-marked generator | 226.67 / 225.85 ms warm medians | Ranges overlap. Mark overhead unresolved. |
| All 256_c256 AdaIN/Snake fills and joins | 14.057 ms, range 14.019–14.075 | 450 dispatches per render across five spans and six stages. Count each four-worker dispatch once. |
| Interior / edge fill and join | 13.460 ms over 432 / 0.597 ms over 18 | Edge blocks 0, 73 and 74. Post-fill edge padding adds a separately measured 0.434 ms median. |

The fill timing excludes history copies, explicit padding, the caller’s final syncht and dmwait. Even eliminating all 14.057 ms would yield only about **55.3×**, leaving roughly **95.3 ms** to find. This upper bound concerns the measured fill region alone. The 665.52 MB weight ledger counts scheduled bytes. The weights already use HMX-oriented panels and the trace shows that queued copies can overlap compute. [Weight layout and traffic](stock-phone-bottlenecks-sm8550-20261118.md)

The fresh unmarked log’s four warm runs show frontend times of 4.77–4.91 s, generator wall times of 294.9–325.7 ms, and total times of 5.13–5.25 s. Run 0 is cold. Five outputs including cold matched. Raw PCM SHA-256 is B61ACE349E3090D910E1F6E6EB20378FE70F89D38DD421B4C0AF978BFBE1A6BF. The WAV file hash is 2DF730C2CB2BEFB5550E40B594F0F5257398252C4E434092B06F76FCB6159072.

## What Sol established

Span 2, block 44, tiles 176–179, stage 0→1, interior no-padding path. From return of branch 2 to setup for the next HMX call, the queued handoff took 49.48 µs. History save completed at 5.36 µs, combine and history restore by 13.15 µs, and activation fill joined at 49.43 µs. The 36.30 µs fill locally gates HMX; these marks bracket software calls. Individual DMA completions and matrix issue times remain unresolved.

Each lane fills one tile in branch order 0, 1, 2. Stage 1 has disjoint branch activation windows and branch-specific coefficients. Branch 0 needs both planes across all four tiles. The worker wrapper and pool completion protocol are shared. Sol proposed publishing branch-0 readiness per worker after syncht, letting workers continue branches 1/2 while the caller runs branch-0 HMX, then finishing caller work and joining before pool reuse. **Proposal only.** Preserve history, padding, weight-slot ownership and full completion semantics. [Dispatch and convolution](../../src/jobs/Kokoro.Generator60x16Run.ps1) · [Activation stores](../../src/kernels/Kokoro.AdaInSnakeTurns.ps1)

## Next bounded assignment for Sol

Using the same lighthouse inputs, queued weights and phone, build a whole-generator wall-clock breakdown in scratch. Begin with existing receipts and marks. Rank the largest remaining elapsed regions by section and operation, including front, 128-channel work, 256-channel work, tail, and any unassigned time. Reconcile the sum with the uninstrumented generator DSP baseline. Treat nested worker time and overlapped DMA separately to prevent double counting. Report per-run values, output hash, instrumentation overhead or uncertainty, and one candidate change with a savings bound. Stop before changing production scheduling. The branch-0 overlap experiment remains available once ranked.

## Quality and Student work carried forward

- Scott still hears fan-like flutter on phone output. Scheduling controls preserved the exact waveform. The style-fix WAV has not passed listening acceptance. In three jointly voiced intervals the 8–12 kHz envelope peaked near 10–11 Hz in both affected and clean float renders, often at the estimator’s search floor. That metric cannot certify a fix. Static AdaIN remains a hypothesis. Preserve affected and clean examples and validate any detector against both.
- The live Student supplies phones, durations, F0 and N. The stock text encoder and DSP decoder still produce generator input x. The historical direct-x audition used held-out timing/F0. A meaningful bypass uses live occurrence objects, Student durations and F0, and emits 512 × T features at 80 Hz on unseen text. Track reopenable object completion separately from explicit phrase closure. Utterance-derived or procedurally controlled AdaIN is part of the design.
- Procedural high-frequency air and native Opus are parallel research. Independent held-out FFT results on the two original 48 kHz recordings support testing 12–16 kHz (2.48–2.88 dB median error). A common 16–20 kHz gain had about 30 dB median error. Heart-with-air carries reported flutter. Preserve the integer synthesis tail as a reference for any codec experiment.

## Local evidence for the next account

Under C:/Dev/Kokoro-Hexagon/build/pcm-return-20261118T115942/ retain handoff-baseline-current.log, handoff-study/{queued-header.log,sync-header.log}, and fill-join-study/{queued-fill.log,queued-control.log,Measure.ps1,MeasureControl.ps1,Prepare-FillJoin.ps1}. Scratch runners reference other local build artifacts. Preserve the build tree if moving machines. The figures above can be read without the scratch tree; a clean-checkout reproduction still needs a portable fixture and invocation. The provisional audio timing bundle lives at C:/Dev/kokoro-bdsm-dungeon/audio-performance-timing-bundle/.
