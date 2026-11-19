# SM8550 depth-first generator throughput

**Current exact-baseband generator throughput is 106.93–107.02× DSP realtime (RTF about 0.00935).** The candidate ran at 110.027 and 110.119 ms around a 116.378 ms control on SM8550. Host invocation was 145.721 and 146.407 ms (80.4–80.8×); frontend work is outside the measurement. The initial short trial reached 108.97×. All 26 confirmation invocations matched the reference PCM, as did all five runs against a second seed's separate reference.

The section-front-pack candidate parallelizes the 256-channel front add and splits the 128-channel front interleave at complete tile boundaries. Each worker writes disjoint output tiles, and the controller handles the partial tile. It also retains section state across span segments and combines and packs output on the same worker. Candidate library SHA-256 is 2124DCDE4B7BB6D442D0FAA0660DDF81A71879FF4A36AB308622ECC9D33203DA.

The confirmed rate covers the 24 kHz baseband that both approved 48 kHz listening examples share. The FM air track was generated offline. Native FM-air and Opus timing is open.


The 24 kHz generator reaches 110× at 2.64 million valid PCM samples per DSP second and 120× at 2.88 million. A full 32-row output tile advances audio by 160 samples. The corresponding budgets are 60.61 and 55.56 microseconds per full output tile. The final partial tile contributes only valid samples. These are equivalent aggregate costs. Measuring the steady-state initiation interval requires interior tile or span timestamps.

## Control and measurement

Commit 1ebca4f computes the harmonic source, seeded noise and PCM. The 282,600-sample fixture includes startup and drain. Divide 282,600 by the warm median region time in seconds for samples/s, then divide by 24,000 for realtime factor. The DSP timer runs at 19.2 MHz. Host invocation time is measured independently.

The preserved zero-source A/control/B comparison measured 115.404, 116.039 and 114.534 ms respectively. Both candidate trials matched the reference PCM. For the same fixture, the 110× limit is 107.045 ms and the 120× limit is 98.125 ms.

## Section scheduling experiment

The release interleaves the two source and two main sections. Each section can overwrite the preceding section's VTCM state. Saving and restoring that state at section transitions costs DMA bandwidth. Reordering changes which state is live and also changes the lifetime required of each tensor in DDR. The prior two section-ordered experiments both produced PCM beginning 720D5468 instead of the control hash beginning B61ACE34. Their timings do not qualify.

The emitter selects backward worker bodies by section suffix and a run name beginning with _s. The previous segmented experiment named its main workers _main. The first diagnostic changes this name to _smain while holding the fixture and segmentation fixed. Compare emitted library identity, DSP time, full PCM hash and restoration receipt.

## Qualification

Use the pinned PowerShell ADB client on SM8550. Confirm candidate/control/candidate with one cold and twelve warm invocations per trial, verify the emitted library hash and every PCM hash, and repeat with the second seed. For procedural air, compare a deterministic reference at the actual output rate and preserve the audio-duration denominator. The current PCM control runs at 24 kHz.

## Phone results on November 19

| Change | Warm runs | Median DSP ms | Audio rate | Waveform check |
| --- | ---: | ---: | ---: | --- |
| Segmented section residency, main worker name corrected | 4 | 112.56 | 104.6× | Exact PCM |
| Both sections resident, one worker run per section | 8 | 113.81 | 103.5× | Exact PCM |
| Feed the 128-channel noise convolution directly into its front | 8 | 98.331 | 119.75× | Changed PCM |
| Feed both noise convolutions directly into their fronts | 8 | 91.540 | 128.63× | Changed PCM |

The matching samples after renaming the worker locate a concrete error in the earlier section experiments. The direct-source candidates bypass the learned source residuals. They retain seeded excitation and the main sections. Against the same decoded reference, the 128-channel and both-channel bypasses have 4.73 and 5.50 times the raw RMS. Their sample-aligned SNRs are −13.69 and −14.94 dB. The binaries yield timing bounds for replacing these branches. Listening approval is required before a changed waveform qualifies.

Local captures and timing logs live under build/rt80-1795102334443 in section-bound-main, section-single-bound, source128-direct and source-direct-both. The last two names also identify the WAVs beside control.wav. Each WAV wraps the raw DSP samples without gain matching.

## Fourth-phase hypothesis

The current tail computes conv_post logits, derives complex spectra, runs the inverse transform, and combines and packs five samples per output row. The pack loop traverses 4,096 bytes of biased crouton layout per tile and writes 320 contiguous PCM bytes. The next batch reuses the input scratch holding those packed bytes. This is one measurable handoff where a fourth phase could change the pace of the pipeline.

The first timing control distributes that same packing work among the four existing workers, with disjoint tile ranges. It preserves the existing barriers, PCM format, edge-sample gains, and arithmetic. This isolates the effect of distributing packing from the effect of removing a barrier or adding procedural air. An independent output phase would additionally need ownership of its live buffers until the output consumer releases them. The appropriate comparison measures the interval between successive completed blocks, plus fill and drain.

For a four-phase path emitting 48 kHz Opus, use valid packet duration over elapsed DSP time. FM air can advance from procedural state. Decoded sample count expresses audio duration and does not prescribe the number of explicit PCM synthesis operations. No Opus or FM cost is included in the table.

### Output scheduling trials

All three schedules rendered the control PCM hash B61ACE34… on every invocation. They used the same weights and 24 kHz output.

| Tail schedule | Warm DSP median | Audio rate | Comparison |
| --- | ---: | ---: | --- |
| Original controller packs each tile | 116.239 ms | 101.30× | Interleaved control |
| Four workers pack disjoint tiles | 112.767 / 112.793 ms | 104.42 / 104.39× | Candidate/control/candidate, 12 warm runs per trial |
| Each worker combines and packs its own tiles in one dispatch | 111.599 ms | 105.51× | Initial trial, 8 warm runs |
| First tile group combines and packs on three workers while the controller issues HMX inverse transformation for the second group | 113.243 ms | 103.98× | Initial trial, 8 warm runs |

Moving the copy onto workers recovered 3.45–3.47 ms in the controlled comparison. The half-batch overlap schedule added a matrix call and split the work unevenly. It took 1.64 ms longer than the fused schedule in the two initial trials. The elapsed results cannot establish an internal hardware stall cause. Neither implementation synthesizes air or emits packets. Receipts are under confirm-output-four-lanes-124708, output-pack-fused and output-pack-overlap in the build directory above.

Combining section residency, the direct zero-residual noise convolution, and the fused worker output produced 109.693 ms (107.34×) with exact PCM. A separate activation-precision experiment retained both learned source branches and used the high activation byte for residual convolutions. That run reached 128.89× but changed the audio considerably (−6.22 dB waveform SNR and 1.76× RMS). Its speed includes a change in arithmetic. It cannot isolate the contribution of the output phase.

### Repeatability and air audition

The candidate bypassing both residuals ran again at 128.16× and 128.30× around a 101.72× exact control. All 26 candidate invocations produced the same candidate PCM. A second noise seed produced a distinct candidate hash D24D50D2… in a discovery run and all five verification invocations. This establishes repeatability for the changed contract. The full receipts are in confirm-source-direct-both-125523 and source-direct-both-seed2. At the slower candidate median, only 6.25 ms of DSP budget remains for any extra work to reach 120× on this fixture.

The offline 48 kHz comparison uses the exact phone PCM as input to both sides. Interpolation preserves samples at the even indices. The additional signal is a 15,137 Hz carrier phase-modulated by 1,321 and 1,927 Hz oscillators, then band-limited to 12–16 and 16–20 kHz. Its envelope follows smoothed squared energy in the baseband's 8–11.5 kHz band. The level calibration uses the first twelve seconds of the existing heart-with-air-48k WAV. The corresponding upper-to-mid band RMS ratios were 0.264 and 0.161. These oscillator parameters are an audition choice. Both files use unity common gain and contain 565,200 samples at 48 kHz. The offline filter centers its FIR windows. A streaming implementation would need to account for filter delay and retain oscillator and envelope state. These files do not enter the DSP timing.

The two auditions are control-48k.wav and control-fm-air-48k.wav. The executable prototype is pcm-capture/fm_air.py under the same local build directory.

### Listening decision

Scott approved both 48 kHz auditions and reported the flutter was gone. Both use the exact control baseband. No targeted flutter correction was applied. This observation is specific to the audition pair.

Scott rejected the level-matched 122.66× render as very staticky. This render retained the source residual branches but used rounded high-byte activations in both main residual sections and a degree-five Snake approximation. Its raw RMS was 2.55× the control, so its audition used gain 0.393. Exclude it from milestone qualification. For comparison, the degree-five approximation alone preserved 44.79 dB sample-aligned SNR and near-identical RMS, but reached only 108.92×. Neither test establishes the sound of a native 48 kHz Opus implementation.

## Reproduce this checkpoint

The experiment sources, per-invocation measurements, and offline FM renderer are in [the experiment directory](../../tools/experiments/generator-throughput-20261119). Each named patch applies over the parent listed in parents.json, starting at commit 1ebca4f. Patches preserve the tested emitters, including deliberately lossy diagnostics. Use section-front-pack for the exact-PCM front and tail schedule. The default generator at 1ebca4f remains the control. The two PowerShell commands below create a detached experiment checkout and emit its DSP library from source.

~~~powershell
$tools = (Resolve-Path tools/experiments/generator-throughput-20261119).Path
$tree = Join-Path (Resolve-Path build) 'repro-front-pack'
& "$tools/New-ExperimentCheckout.ps1" -Variant section-front-pack -Destination $tree
& "$tools/Export-ExperimentGenerator.ps1" -Checkout $tree -OutputDirectory "$tree/build/emission"
~~~

The emitter needs the repository's PowerShell development runtime. For a hardware run, pass the emission directory, existing full-size lighthouse fixture, and pinned PowerShell ADB client to the archived Invoke-GeneratorTailProbe.ps1. For exact baseband, supply expected PCM hash B61ACE349E3090D910E1F6E6EB20378FE70F89D38DD421B4C0AF978BFBE1A6BF. The timing CSV contains run zero explicitly so the warm medians can be recomputed. Stock source data, device binaries and local audio stay in the existing build and offline research directories.

The portable FM audition accepts three positional paths. It uses only the Python standard library.

~~~powershell
python "$tools/fm_air.py" "$capture/control.wav" "$offline/experiments/heart-with-air-48k.wav" "$capture/rebuilt-air"
~~~

Here $capture is the local experiment output directory and $offline is the local offline research repository. The 48 kHz air audition adds no learned weights. The phase and envelope operations still have a cost on the target. A native-Opus throughput claim requires timed valid packets and a decoded audition.

## Procedural student question

The rejected main-section experiment discarded activation precision inside the generator. The Student frontend was not in that timed region. Its result therefore says little about whether a Student can supply a correction. An experiment that isolates that question would keep the accepted reference fixed, collect paired tensors at the first diverging stage, and measure whether a causal Student can predict the missing contribution from its available controls. Inject the reference contribution first to establish what that one intervention can recover. Then audition the predicted contribution on unseen text and another noise seed, including its compute and transfer costs in the rate.
