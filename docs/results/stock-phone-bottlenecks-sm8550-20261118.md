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

Scott reported a fan-like tremble during playback. Both batches logged zero AAudio underruns. Changing the CPU handoff produced identical samples. These checks establish repeatability and correct transfer in this test. They do not measure the audibility or cause of the tremble.

The baseline phone WAV and the reference driven by the PC front end share the same integer DSP backend and voice-base conditioning. The measured pitch tracks agree on jointly voiced frames, voicing classifications agree throughout, and 95% of active 10 ms windows differ by at most 0.0004 dB in RMS level (5 ms hop, both windows above −45 dBFS). This comparison gives little evidence of a flutter introduced specifically by moving the front end onto the phone. A shared synthesis effect or playback effect would survive the comparison.

A separate [float host render](../../build/bottleneck-stock-20261118T163854/lighthouse-float-utterance.wav) uses the same 193-phoneme passage, voice, nominal seed 1 and output length. It uses the host port's float decoder and generator with utterance normalization. It differs in multiple ways from the [phone render](../../build/evaluator/emit/KokoroGenerator60x16Run-8C8FAEF3744AE7D0/speech-SM8550-9b213e8a1783460caf87546f4fcda1f6.wav), including arithmetic, normalization and source implementation. The median absolute difference of the active short-time levels is 4.65 dB. The RMS-envelope difference did not identify a specific tremble rate (only seven continuously active, overlapping 0.4 s windows at the selected threshold). A listener-marked interval and a same-input comparison changing one of source, normalization or integer processing at a time would distinguish those effects. No component or control policy has yet been assigned as the cause.

## PCM return and weight-panel reuse on the same passage

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
