# Stock phone path and HMX data layout on SM8550, 18 November 2026

On code revision `d3b848f`, the CPH2451 rendered the 11.775 s lighthouse passage in a warm median of 5.051 s (2.33×). The generator DSP region alone took 273.16 ms (43.1×). This was the stock CPU front end with eight workers, the span decoder, the depth-first generator, and the existing supplied voice levels. Student inference and live AdaIN automation were outside this run.

## Method

Ran the repository's `PhoneSpeech` command under PowerShell 7.7.0-preview.5 with the October lighthouse text, `-Soc SM8550`, and `Runs=5`. The runner used the repository-pinned `adb.ps1`. Compared run 0 separately and took the median of runs 1–4. All five PCM hashes equal the earlier span-decoder receipt, `93F46D15CCDEFF43A83588DDF1E788AEC4C2B83B5676513DA400A277C0F688BC`. The phone played all 282,600 frames with zero underruns. The runner verified startup restoration. The measured total starts at text in the loaded process and ends at PCM. Loading the front end and phonemizer took another 1.990 s. Deployment, host-side preparation, and playback are outside that total. This measures one passage, one voice, and one handset.

Raw [five-run receipt](../../build/bottleneck-stock-20261118T163854/phone-speech.clixml). Local receipts under `build/` are excluded from Git.

| Milliseconds | First render | Warm median | Warm range |
| --- | ---: | ---: | ---: |
| Phonemizer | 35.28 | 0.48 | 0.32–0.62 |
| CPU front end | 8,590.8 | 4,598.85 | 4,592.1–4,833.6 |
| Decoder wall | 169.0 | 49.45 | 46.4–51.4 |
| Decoder DSP inside decoder wall | 29.65 | 28.88 | 28.77–28.93 |
| Generator wall | 419.0 | 400.15 | 392.8–407.2 |
| Generator DSP inside generator wall | 269.26 | 273.16 | 271.77–274.05 |
| Total text to PCM | 9,223.5 | 5,050.6 | 5,033.0–5,293.4 |

The medians are computed independently. With the measured front-end time subtracted per run, the remaining median is 451.75 ms, or 26.1×. That is a hypothetical upper bound for changing only the front end in this serial path. Decoder and generator DSP regions together take 302.01 ms, about 39.0×. A 40× text-to-PCM budget is 294.38 ms and an 87× budget is 135.34 ms.

The [earlier on-phone stage profile](frontend-phone-cpu-sm8550-20261027.md) explains where to look within the CPU front end on this passage. ALBERT took 2,955 ms, five predictor LSTMs took 1,120 ms, and the text encoder took 504 ms. These are older stage measurements, separate from today's totals. The baseline uses compiled numeric kernels, portable SIMD, and eight workers.

## Weights, transfers and working buffers

The generator pack is already a hardware-specific disk representation. `Get-PackWeightPlanesShapedKernel` encodes output groups, taps and input blocks in HMX byte order. `ConvertTo-KokoroGeneratorInt8` caches converted weights and bias corrections by weight and layout identity. The speech harness reads the packed weights before the timed loop. A second representation can change warm synthesis time only if the consumer uses it to reduce work, transfers, or stalls.

In the current 37,994,496-byte generator file, the low planes of the converted residual-block weights account for 14,155,776 bytes. Each low plane in the October pack hashed identically to a zero buffer of the same length. Today's weight file has the identical SHA-256. The one-plane schedule retains high/low spacing between stage offsets, while individual one-plane stage transfers can already skip low bytes. Removing holes from the file could reduce storage and the size of the declared RPC argument. A DSP-time saving cannot be inferred from those bytes alone.

The [current generator layout](../../build/evaluator/emit/KokoroGenerator60x16Run-8C8FAEF3744AE7D0/runner-layout.json) requests 7,602,176 B of VTCM and schedules five spans. Its DMA ledger sums to 1,053.13 MB (decimal), including 679.53 MB of weights, 167.25 MB of state saves/restores, and about 202.78 MB of tensor traffic. The 256-channel main section accounts for 665.52 MB of the weight traffic. These are scheduled transfer lengths within the job. They do not measure DDR misses, DMA stalls, or USB transfer. The October lighthouse emission used eight spans.

The phone passes 31.69 MB of decoder weights and 37.99 MB of generator weights as pinned managed buffers on each synthesis. The generator allocates a 123.56 MB output/workspace buffer and clones it in the diagnostic runner. The PCM occupies 0.565 MB. The span decoder writes its output, the CPU shifts the 512-channel result by 20 ticks, and the generator receives it in a separate call. These are distinct from the HMX weight transfers. An [earlier resident-buffer test](resident-payloads-invoke-sm8550-20261012.md) reduced warm host invoke time by 23.94 ms on another job.

## Implications for stored shapes

* Keep an authoritative model and allow extra immutable representations when two consuming kernels want different orders. Select a representation by consumer and stream its current tile or panel. Disk duplication and live VTCM occupancy are independent choices.
* For the 256-channel section, compare packing panels in scheduled read order with reusing a panel across more ready tiles. The former may simplify DMA descriptors. Only the latter necessarily removes repeated weight reads when dependencies and VTCM allow it. The existing [queued-weight and span experiments](generator-source-on-dsp-sm8550-20261024.md) provide working controls.
* For activations, the values appear during synthesis. Let the producer write the next consumer's order when possible. A CPU-side transform can use Arm NEON before DMA, or overlap work on the next buffer with the current transfer. The DSP-side vector unit is HVX. The implementation's DMA descriptors move bytes. Arithmetic, quantization, shuffling, synchronization and cache ownership each need an explicit owner and timing.
* Keep Student-provided conditioning separate from immutable weights. Static packing can encode where a site's coefficients go. Their values and effective times may change with the Student's performance.
* In the historical generator profile, HVX window fill for AdaIN/Snake and plane combines occupied more thread time than waiting for the matrix lock in the profiled resident sections. The five-span DMA ledger alone cannot rank these against exposed DMA stalls on this run. A matched long-passage test should report both DSP and wall time, scheduled bytes, workspace, and the cost of any replacement transform. For a pure layout change, byte equality tests the arithmetic contract.

## Paired on-device layout probe

A second five-render batch compared two CPU copies of the *same live decoder output* in each render. Both realigned the delayed decoder tiles and wrote the same padded 983,040-byte generator input tensor. A used the current 128-byte copy per row pair and channel block. B copied each contiguous range up to the next source or destination tile boundary. Both used the same output allocation, zero-fill convention, and managed array-copy API. Their execution order alternated. All 983,040 bytes matched on all five runs, and B fed the generator. Final PCM was identical to the baseline on every run.

| Warm run | Current copy, ms | Grouped copy, ms | Clone of generator workspace, ms | Generator invoke, ms | DSP inside invoke, ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 6.23 | 2.98 | 36.46 | 331.27 | 272.24 |
| 2 | 4.20 | 1.86 | 8.39 | 327.43 | 271.04 |
| 3 | 3.72 | 1.97 | 42.28 | 324.29 | 269.77 |
| 4 | 2.51 | 2.89 | 9.10 | 329.61 | 271.00 |

The calls fell from 7,536 to 960. The median warm paired saving was 2.05 ms, with one reversal. The 123.56 MB generator output clone cost 8.39–42.28 ms after invoke. The invoke itself exceeded the DSP region by 54.5–59.0 ms. This difference includes transport and other call overhead. Both handoffs ran in each diagnostic iteration, so the batch's total time cannot establish a production throughput gain from B. The diagnostic used scratch copies of the harness, restored phone startup, and released the lock. [Runnable diagnostic](../../build/bottleneck-stock-20261118T163854/Measure-Handoff.ps1) and [full receipt](../../build/bottleneck-stock-20261118T163854/handoff/run.log).

## Listening observation

The speech handoff now uses the grouped copy described above. It fills encoded zero only in unused row pairs of the last tile. At 942 ticks its temporary padding array is 1,152 bytes, down from 983,040 bytes. Verify compares all output bytes with a row-pair reference for 25 length and delay combinations. The production change has been checked on the host. The earlier phone probe measured grouping with the original fill.

Scott reported a fan-like tremble during playback. Both batches logged zero AAudio underruns. Changing the CPU handoff produced identical samples. These checks establish repeatability and correct transfer in this test. They do not measure the audibility or cause of the tremble.

The baseline phone WAV and the reference driven by the PC front end share the same integer DSP backend and voice-base conditioning. The measured pitch tracks agree on jointly voiced frames, voicing classifications agree throughout, and 95% of active 10 ms windows differ by at most 0.0004 dB in RMS level (5 ms hop, both windows above −45 dBFS). This comparison gives little evidence of a flutter introduced specifically by moving the front end onto the phone. A shared synthesis effect or playback effect would survive the comparison.

A separate [float host render](../../build/bottleneck-stock-20261118T163854/lighthouse-float-utterance.wav) uses the same 193-phoneme passage, voice, nominal seed 1 and output length. It uses the host port's float decoder and generator with utterance normalization. It differs in multiple ways from the [phone render](../../build/evaluator/emit/KokoroGenerator60x16Run-8C8FAEF3744AE7D0/speech-SM8550-9b213e8a1783460caf87546f4fcda1f6.wav), including arithmetic, normalization and source implementation. The median absolute difference of the active short-time levels is 4.65 dB. The RMS-envelope difference did not identify a specific tremble rate (only seven continuously active, overlapping 0.4 s windows at the selected threshold). A listener-marked interval and a same-input comparison changing one of source, normalization or integer processing at a time would distinguish those effects. No component or control policy has yet been assigned as the cause.

The host float ExcitationPair run on the lighthouse text reused one decoder output, acoustic style, F0 and random draws. For the second generator run it zeroed the nine harmonic noise draws at samples whose source tick exceeded the existing 10 Hz voiced threshold. Both WAVs last 11.775 s. In 19 qualifying windows per render, the 24 Hz median moved from 1.31 to 1.28 dB and the 80 Hz median from 0.46 to 0.48 dB. The full-passage loudness difference was 0.009 LU and envelope correlation 0.99989. Removing voiced excitation noise had little effect on those measures in this float renderer. Listening comparison is pending. The phone uses different arithmetic, noise generation and normalization. [Host baseline](../../build/flutter-pair-01/baseline.wav) and [voiced noise off](../../build/flutter-pair-01/voiced-noise-off.wav).

## PCM return and weight-panel reuse on the same passage

Scott subsequently heard all three float lighthouse renders (full, half and zero voiced noise) as clean. The half-gain run reproduced the full-gain control WAV byte for byte. These results provide no reason to suppress voiced noise.

The host float speech renderer previously generated a second full set of random draws on each render to check repeatability. The seeded diagnostic retains that check. On the second PC, six warm pairs at 282,600 samples alternated the checked and single-generation order. Median draw preparation fell from 185.4 ms to 90.3 ms. Both output WAVs from the excitation comparison matched the prior renders byte for byte. This times host draw preparation only. [Paired timings](../../build/flutter-draw-speed/draw-times.csv)

### Offline follow-up on the reported flutter

On the second development PC the phone's retained speech WAV decoded to the original PCM16 hash. Scott heard the flutter throughout this saved file on playback away from the phone. The samples therefore carry the reported effect. The PowerShell MeasureAudio command measured −28.60 LUFS integrated and −9.60 dBTP true peak. The final waveform has headroom. Internal saturation remains possible.

Run `MeasureAudio -Path build/recovered.wav -Pattern Modulation` through the development entry point to examine periodic level variation. The analysis uses 2 ms RMS bins and half-second windows with at least half their bins above −50 dBFS. In 13 qualifying windows the median log-envelope amplitudes at 22, 24 and 26 Hz were 3.02, 3.47 and 1.97 dB. At 78, 80 and 82 Hz they were 0.52, 0.38 and 0.50 dB. The control clock at 80 Hz has no local peak in this measure. Natural speech can produce the broad low-frequency variation. A known modulated carrier and a steady carrier exercise the detector in Verify. No matched intervention has established a perceptual flutter rate or identified a responsible stage.

The speech generator's managed return now keeps 565,200 bytes of PCM from the 123,560,128-byte RPC workspace and reuses the existing PCM hash. The RPC still allocates and passes the full workspace. The decoder and diagnostic jobs still return their first full result. In one process, after a warmup, the phone repeated compact/full/full/compact three times. All 13 renders matched the earlier PCM hash and the WAV matched byte for byte. Returning just the samples removes 122,994,928 bytes of copying per render.

The compact generator path won four of six adjacent pairs. The median paired saving was 30.55 ms with individual savings from −47.8 to +140.7 ms. Across the six runs in each group, generator wall medians were 620.0 ms compact and 607.1 ms full. The working-memory reduction is repeatable. These timings are too variable to claim a reliable wall-time gain. [Paired phone receipt](../../build/pcm-return-20261118T115942/run.log)

This batch also exposed a second operating condition. The CPU frontend took 36.1–37.8 s warm for 11.775 s of audio. A follow-up snapshot during the panel benchmark found Android dozing, thermal status 0 and battery saver off. Android had placed the speech app process in the background cpuset with CPUs 0–2 allowed. The frontend was configured for eight workers. The prior 4.60 s baseline lacks a matching cpuset reading, so the performance difference cannot all be assigned to that restriction. [Device state](../../build/pcm-return-20261118T115942/phone-state.log)

The panel experiment kept one 720,896-byte HMX-ready panel in a reserved VTCM slot for each span of the 256-channel main section. It used the same packed model file. The emitted schedule dropped from 1,415 weight transfers to 1,340 in that section and from 665,518,080 to 611,450,880 scheduled weight bytes. Total VTCM rose from 7,602,176 to 8,323,072 bytes. Each separately staged library ran one real frontend and decoder followed by 11 generator calls on that input. Each call produced the baseline PCM hash. The candidate ran first. The first invocation of each library was excluded.

| Generator median, 10 warm calls | Current schedule | Resident panel |
| --- | ---: | ---: |
| DSP region | 270.80 ms | 271.07 ms |
| DSP range | 269.57–273.70 ms | 269.43–272.21 ms |
| Host invoke | 333.93 ms | 343.13 ms |

The saved transfers produced no measurable DSP speedup on this schedule. This tests reuse of one already-packed panel. A different disk representation that eliminates a conversion or changes the compute schedule is a separate experiment. The resident-panel variant is confined to the experiment directory. [Control receipt](../../build/pcm-return-20261118T115942/control.log) · [Panel receipt](../../build/pcm-return-20261118T115942/panel.log) · [Emitter change](../../build/pcm-return-20261118T115942/panel-variant.diff)

## Hardware counters on the lighthouse generator

### Host float timing on the second PC, November 19

RenderTiming rendered the 11.775 s lighthouse passage four times on the i5-4310U (two cores, four logical processors), with four convolution workers. Zira distillation ran concurrently. Each render called the phonemizer and recomputed the text features. The generator timer includes the seeded draws. Text-to-PCM excludes loading the checkpoint and compiled libraries, WAV writes and comparison. Run 0 took 56.585 s total and 27.435 s in the generator. Runs 1–3 took 39.352–40.081 s total (median 39.857 s, RTF 3.385) and 24.383–24.918 s in the generator (median 24.455 s, RTF 2.077). The baseline WAV matched the listener-confirmed clean host render and all repeats matched in memory. This batch measures the float host on this PC under load. [Per-run timings](../../build/lighthouse-rtf-4t/render-times.csv)

The host float generator now windows each 20-sample harmonic STFT frame once and reuses those samples across its 11 frequency bins. Eight alternating warm pairs on the same lighthouse excitation gave median STFT times of 76.25 ms before and 58.63 ms after. All spectra compared equal, and both full baseline and voiced-noise-off WAVs matched their prior files byte for byte. [Stage timings](../../build/flutter-stft-speed/stft-times.csv)

The DSP seeded harmonic-source candidate initializes its multiplicative counter from the chunk's absolute first sample and advances it by addition. It removes two multiplies and one add from each sample iteration and adds two setup instructions per chunk. `Check -Kernel SourceNoiseCounter` checked 20,480 wrapping counter inputs and emitted the seeded source job. This is a host arithmetic check and emission only. The distinguishing phone run is the same retained generator input and coefficients through both libraries, checking the generated source and final PCM, then comparing harmonic-source ticks and whole-generator time.

The instrumented stock kernel ran three times on the same real generator input. All three PCM hashes matched. In the last call the DSP region took 279.76 ms. The lockstep regions accounted for 107.27 ms. Within those regions the four workers each spent 68.18–69.81 ms filling AdaIN/Snake inputs, 17.14–18.06 ms combining outputs and 1.03–3.22 ms waiting for the HMX lock. These workers run concurrently. Their time also falls inside the lockstep region.

Viewed by stage, Front128 took 72.81 ms, Front256 43.74 ms, harmonic source generation 41.01 ms and harmonic layout 29.26 ms. The stage and activity counters are overlapping views. Time marked as DMA was 9.41 ms and covers the marked intervals only. The matched transfer-reuse experiment above measures the effect of eliminating those transfers on total DSP time. A next comparison could have the harmonic source producer write the consumer's layout directly, with the same excitation, live controls and final PCM. [Full hardware-counter receipt](../../build/pcm-return-20261118T115942/pmu.log)

## Harmonic layout batch size on the lighthouse passage

The 128-channel front consumes the original 60× harmonic tensor. The 256-channel front consumes a second representation that folds six time phases into channels. On the SM8550 the gather ran in 37 batches of eight slow tiles, including a final partial batch. Using up to 48 tiles cut that to seven batches with the same 7,602,176-byte peak VTCM allocation. The emitter selects the larger batch for fixed-length spans when a full batch is available and the existing VTCM reservation fits its input and output planes.

The two separately staged libraries each processed the same live generator input 11 times via the repository ADB client. The candidate ran first. Excluding each first call, median generator DSP time fell from 272.45 to 268.21 ms (1.56%). The median instrumented harmonic-layout stage fell from 29.25 to 23.79 ms over three calls per build; the control profile was recorded earlier. Both builds produced the original PCM hash throughout. A separate capture checked all 9,666,560 bytes of the candidate's phase-major tensor against an independent reconstruction from the live source, including padding and the one-phase tail. Both planes matched exactly. This measures a single passage and device. Full text-to-PCM latency was outside the paired generator measurement.

[Stock receipt](../../build/pcm-return-20261118T115942/har8-control.log) · [Larger batch](../../build/pcm-return-20261118T115942/har48.log) · [Hardware profile](../../build/pcm-return-20261118T115942/har48-pmu.log) · [Layout check](../../build/pcm-return-20261118T115942/check-har-layout.py)

## HVX harmonic gather on complete tiles

The six-phase gather packs two output rows at once. Each aligned source vector contains both time parities for 32 channels. Two such vectors six source rows apart supply a pair of output rows. HVX selects their halfwords, masks the value byte and joins the six 22-channel groups into 132 contiguous output channels. Padding uses the plane's encoded zero. The scalar row body handles the partial tile and last row. VTCM use on the lighthouse job is 7,602,176 bytes.

On the SM8550 the vector library ran first, followed by the scalar library from commit e39e294. Both used the same 48-tile batching and live lighthouse inputs. Each library ran once to warm up and ten more times for timing. Median generator DSP time fell from 268.50 to 245.05 ms, a saving of 23.45 ms (8.7%). Median host invoke fell from 313.89 to 289.85 ms. The intervals across the ten DSP calls were 265.22–270.06 and 243.53–247.30 ms respectively. The two batches used separate launches. These results measure the generator on one passage and handset.

All 22 calls returned the original PCM SHA-256. An independent reconstruction from a separate vector-kernel speech capture matched all 9,666,560 bytes of phase-major output, including the partial rows and unused channels. [Vector timing receipt](../../build/pcm-return-20261118T115942/har-vector-paired.log) · [Scalar timing receipt](../../build/pcm-return-20261118T115942/har-adaptive-paired.log) · [Capture receipt](../../build/pcm-return-20261118T115942/har-vector-check.log)

The median instrumented harmonic-layout stage was 1.31 ms over three vector calls. The preceding three-call profile with the scalar 48-tile gather measured 23.79 ms. [Vector profile](../../build/pcm-return-20261118T115942/har-vector-pmu.log)

## HVX packing in the AdaIN/Snake fill

The fill now extracts the fractional turns for both time rows with equal shifts and one halfword shuffle. After the existing Snake calculation and signed clamp, it interleaves the two rows once. A mask and sign-bit flip produce the high plane, and a halfword shift produces the low plane. This preserves the per-channel and per-tile coefficient path. The generator layout JSON hashes match.

On the SM8550, the new generator ran first and the a930ffb control second, each on the same stock lighthouse speech input. After one warmup, median generator DSP time over ten calls fell from 244.82 to 236.16 ms (3.5%). The observed intervals were 242.11–246.95 and 234.22–238.27 ms respectively. Median host invoke time was 299.32 and 283.61 ms. All 22 PCM hashes matched. In the last instrumented call, the four lockstep workers spent 61.83–63.20 ms apiece filling windows, compared with 68.10–69.70 ms in the earlier control profile. The worker times overlap.

A host arithmetic check covered every signed 16-bit output value in each row and all 65,536 fractional lanes at Q22 and Q24. The kernel emitted for both supported channel counts, both precisions, controller contact on and off, and ordinary and mirrored stores. Phone timings used stock conditioning on one passage. [Control](../../build/pcm-return-20261118T115942/snake-ab-har-vector.log) · [Candidate](../../build/pcm-return-20261118T115942/snake-ab-snake-pack.log) · [Hardware profile](../../build/pcm-return-20261118T115942/snake-pack-pmu.log)

### November 19 lighthouse quality regression

Run `./Invoke-KokoroDevelopment.ps1 CompareAudio -Pattern SpeechQuality -Reference tools/fixtures/lighthouse-af_heart-float.wav -Path <phone-wav>` on the same aligned lighthouse passage. The check measures integrated loudness loss and excess 10–30 Hz envelope modulation independently. The regression thresholds are 2 LU and 3 dB respectively.

| Phone condition | Level loss (LU) | Excess modulation (dB) |
| --- | ---: | ---: |
| Stock | 3.10 | 6.90 |
| Supplied excitation noise | 3.07 | 6.95 |
| Float decoder features quantized into the phone generator input | 3.23 | 6.72 |

Gain-only and 24 Hz amplitude-modulated controls each triggered their corresponding check alone. Substituting float decoder features leaves both symptoms. The generator input quantization and downstream path remain candidates.

On SM8550, converting 282,600 returned PCM samples took 0.30 ms versus 23.05 ms previously (paired warm medians, identical samples). Four warm stock renders of 11.775 s of audio took a median 5.086 s end to end, including 4.749 s in the frontend. DSP generator time was approximately 235 ms.

In the quantized float decoder handoff, 99 of 482,304 active values reached the upper 16-bit rail (0.021%). None reached the lower rail. This rules out widespread input saturation in that experiment. Internal generator scaling and the effect of the supplied normalization values on this passage remain open.

### Full-utterance AdaIN export limits

Tried emitting a source-complete generator Export job for all 56,521 generator frames (942 input ticks). The layer schedule rejected the `ups[1]` input planes because their combined placement exceeds a 4 MiB VTCM page. The backward schedule rejected Export because it requires supplied AdaIN values. Both errors occur during emission, before deployment. The 130-tick matched-constants experiment therefore cannot establish whether using matched constants clears the lighthouse regression.

A bounded-memory matched reference needs a stage barrier at each AdaIN site. Accumulate each channel's sum, squared sum, and count over the complete valid stage tensor in spans, derive one coefficient record, then stream the stage with that record. Save the stage tensor in DDR or recompute its producer on the second pass. Check the moment and coefficient records against the existing 130-tick Export path before moving to the lighthouse length. To isolate the normalization policy, feed those exported coefficients back through the existing backward job with the original decoder features, F0, seed, and weights. The layer job uses a different weight representation, so terminal PCM from that job alone would confound the comparison.

The existing moments kernel stores signed 32-bit S1, A2, AB, and B2 partials. B2 can grow by 65,025 per valid frame, so its worst-case signed limit is 33,025 frames. At 56,521 frames the worst-case B2 is 3,675,278,025. A checked host arithmetic probe split that input into chunks of at most 7,801 frames, cast each partial to signed int32, and recovered the full result by widening before addition. A streamed exporter needs to merge partial records in int64, reconstruct squared sums in int64, and pass the valid frame count (excluding tile padding) to coefficient calculation.

### Span size and flutter on SM8550

Rendered the same 942-tick lighthouse passage through the pinned adb client with 120-tile spans first and 60-tile spans second. Each configuration ran one warmup and four timed renders. The generator input, weights, coefficients, seed, and 7,602,176 bytes of VTCM were held constant. All ten PCM hashes matched and both launches restored startup files after playback with zero underruns.

| Span tiles | Spans | Scheduled state save and restore | Scheduled weights | Warm median generator DSP | Warm median text to PCM |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 60 | 5 | 167.24 MB | 679.53 MB | 235.90 ms | 5,154.2 ms |
| 120 | 3 | 83.62 MB | 657.80 MB | 234.43 ms | 5,223.4 ms |

The 120-tile configuration still measured 3.10 LU of level loss and 6.90 dB of excess modulation. Moving these span boundaries leaves the affected waveform byte-identical. The DSP timing ranges overlap and the end-to-end median increased. The default stays at 60 tiles. A 300-tile configuration failed emission because its front required 16,121,856 bytes of VTCM, above the 8 MiB limit.

### Two-tile generator batch on SM8550

Kept the 60-tile span and four HVX threads, reduced the resident batch from four tiles to two, then ran the lighthouse passage through the pinned adb client. VTCM fell from 7,602,176 to 5,505,024 bytes. Scheduled weight transfers rose from 679.53 to 1,290.58 MB. After one warmup, the median of four DSP times was 350.01 ms versus 235.90 ms in the prior four-tile control, a 48% regression. The ranges did not overlap (348.66–351.42 ms versus 232.07–237.08 ms). PCM and WAV hashes matched the four-tile run, so both audio quality flags remain. Playback had zero underruns and startup restoration succeeded. The four-tile batch stays in production.

### AdaIN/Snake post-increment address experiment

Replaced the three explicit 128-byte pointer advances per row pair with HVX post-increment vector accesses. The candidate kept the 60-tile span and four-tile batch. All five phone PCM hashes matched the four-tile control, and playback completed with zero underruns. The four warm DSP calls ranged from 234.29 to 237.80 ms, with a median of 236.58 ms versus 235.90 ms in the earlier control. The timing ranges overlap. The existing packetizer treats post-increment memory operations as packet boundaries, so removing scalar instructions alone need not reduce cycles. The candidate was reverted.
