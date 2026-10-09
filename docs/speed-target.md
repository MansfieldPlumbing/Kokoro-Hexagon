# Speed target: the published iPhone Kokoro

## The bar

kokoro-coreml-ane `484907d` (`C:\Dev\.vendor\kokoro-coreml-ane`), Core ML fp16 + int8 palettized, mostly on the ANE.
iPhone 16 Pro (A18 Pro), `iOSDemo/` (`assets/iPhone16ProBenchmark.png`):

| T_enc | T_a | Audio | Chain | Speed (RTF) |
| ---: | ---: | ---: | ---: | ---: |
| 13 | 60 | 1.50 s | 132 ms | 11.4x (0.088) |
| 66 | 179 | 4.47 s | 249 ms | 18.0x (0.056) |
| 128 | 323 | 8.07 s | 407 ms | 19.8x (0.050) |
| 272 | 651 | 16.27 s | 880 ms | 18.5x (0.054) |
| 457 | 1078 | 26.95 s | 1568 ms | 17.2x (0.058) |
| 512 | 1125 | 28.12 s | 1720 ms | 16.4x (0.061) |

How they time it (`KokoroEngine.swift:75-154`, `BenchmarkView.swift:52`): one warm-up and one measured run, wall clock
summed over the stages from phoneme IDs to PCM. G2P runs offline; model load is excluded. One forward per passage,
not split into breath groups. Inputs: `iOSDemo/iOSDemo/Resources/benchmark_data.json` (phoneme strings), voice `af_heart`.

## Our matching measurement

- The same six phoneme sequences and `af_heart`, one forward per passage, warm.
- Wall clock on the ARM host, from token IDs handed to the DSP to PCM in host memory, including dispatch.
- SM8550 and SM8635 reported separately. The phones differ from the iPhone, so the claim is "faster than the published
  iPhone 16 Pro result on the same inputs", not a same-phone comparison.
- Fidelity reported with every timing: PCM SNR against stock PyTorch for the same passage and noise draws.
- Time to first audio is a separate claim: breath-group streaming, first group's PCM.

## Where we are

Decoder + whole generator, hello world (1.625 s): 106.8 ms DSP time, RTF 0.066, on SM8550. ALBERT, the text encoder and the
predictors are not on the DSP yet. Their front end is small (M4 Mac, T_enc 13: ALBERT 4, PostAlbert 3, alignment 1,
prosody 1 ms of 75.6 ms). The vocoder half decides it: at 8.07 s, linear scaling of our 0.066 would give about 530 ms
for decoder + generator alone against their 407 ms for everything. That is an extrapolation; the length scaling is
not measured.

Dispatch counts. The same receipt measures 139-170 ms per synchronous invoke against 106.8 ms on the DSP, so the
harness spends 30-60 ms outside the DSP. Which part of that is buffer mapping or cache maintenance is not measured.
dspqueue's warm dispatch measured 120 us on SM8635, with the weights mapped once.

To win every row, decoder + generator needs about RTF 0.045 or lower, with the front end under 10% of the chain.

## Length limit (checked 2026-10-09)

Decoder and generator keep the whole sequence in VTCM. `Get-KokoroDecoder16Layout` accepts 90 decoder frames and
rejects 120 (activations over the first 4 MiB) and 179 and longer (a 2 MiB page). `Get-KokoroGenerator60x16Layout`
needs 12.4 MiB at 4.47 s on the 128-channel stage. Only passage 0 (1.5 s, 61 decoder frames) runs today; passages 1-5 need
layer-major streaming: each layer reads and writes DDR in tiles with a halo, accumulates its AdaIN moments as it goes,
and the next layer applies them. Stock's own chunk limit (510 phonemes, about 28 s) needs this regardless of the
benchmark, so breath groups do not remove it.

For the benchmark rows we run one forward per passage, the same computation as theirs.

### Interim: decoder + generator in overlapping slices (team listening test, 2026-10-09)

Sentence: "The early morning sun cast long shadows across the empty street." (178 asr frames, 4.45 s). Stock PyTorch only.

- Text split into three stock forwards at word boundaries: works; needs a pause after the first piece (250 ms sounded
  closest to the single forward). Prosody is predicted per piece, so this departs from stock.
- Vocoder split: ALBERT and predictors over the whole sentence; decoder + generator over three time slices with one
  harmonic source computed over the whole sentence; linear crossfade over the overlap. 16 asr frames of overlap
  (400 ms) judged the best quality of all variants. Waveform SNR against the single forward is 3 dB (per-slice AdaIN
  statistics); loudness within 3%. One slice covering the whole sentence reproduces the single forward exactly.
- Fit: `Get-KokoroDecoder16Layout` accepts up to 96 asr frames; the generator at 192 input frames needs 7.62 MiB.
  A 400 ms-overlap slice is at most 64 + 32 = 96 frames, so interior slices compute 1.5x the frames they keep.
- On the DSP each slice must continue the source's phase and noise from the previous slice (state carried between
  jobs), not restart it.

- Which AdaIN statistics the slices use, 3 slices, against the single forward (waveform SNR / log-spectral distance):
  own per slice 3.0 dB / 6.06 dB; first slice's reused, unstable (output overflow) / 6.40 dB; running over slices so
  far 3.7 dB / 5.70 dB; whole-sentence 26.4 dB / 0.23 dB at 100 ms overlap and 32.3 dB / 0.19 dB at 400 ms. The
  statistics are the whole slicing error; with whole-sentence statistics 100 ms of overlap covers the convs' reach.
  Causal statistics do not recover it.
- The single forward itself pauses 280 ms after "sun" (1.40-1.68 s, 20 ms RMS below -40 dBFS), which is why the
  250 ms text-split pause matched.

Layer-major streaming stays the exact answer and the one used for benchmark timing; slices are the fallback that
runs long sentences on today's jobs.

Stock captures (af_heart, seed 17, `build/capture-iphone-bench/<id>-decoder|generator`), generator input frames and audio:
122 / 1.525 s, 356 / 4.450 s, 644 / 8.050 s, 1300 / 16.250 s, 2154 / 26.925 s, 2242 / 28.025 s. The iPhone rows differ by
up to 0.1 s (predicted durations; cause not checked); RTF is the comparable figure.

## Integration state (2026-10-09, end of session)

- Decoder reads its frame count at run time: `Add-KokoroDecoder16JobSteps -RuntimeFrames` (emit
  `tools/Emit-HexagonProbe.ps1 -Kernel KokoroDecoder16Run -DecoderFrames <capacity> -DecoderRuntimeFrames`); the count is an
  int32 at `Layout.Input.Frames`, clamped to 2..capacity. V73 simulator, hello-world fixture (65 frames): capacity 65 and
  capacity 96 both 0 differing bytes against the fixed job (163,840 output bytes). The fixed job's code is unchanged
  (SHA-256 `346276CF...`, 54,468 bytes, before and after).
- Next: the generator. Its batch loops, `$parallel` worker chunks, pad rows, front interleave counts, source and tail
  layouts are emitted per frame count (`Kokoro.Generator60x16Run.ps1` lines 206-245, 289-300, 354-509). Converting the
  batch loop to runtime counts is also the loop DDR streaming needs.
- Recurring operations done by hand this session belong in one instrument: emit a job, build a simulator fixture from a
  capture, run the simulator, compare outputs, capture stock, write WAV, measure waveform and log-spectral distance.

## Order

1. **Scaling.** Capture stock for the six passages (`build/capture-iphone-bench/`; calibrate on other sentences, the six
   are holdout). Passage 0 on the current job; layer-major streaming for the rest, measuring DDR traffic per layer. This
   also covers handoff step 1 (decoder-input recalibration).
2. **Vocoder speed** against those lengths: decoder HVX threads and DMA/HMX overlap, generator combine + moments
   fusion, removal of diagnostic DMAs, then the fast-path investigations (`vlut16` Snake, integer HMX output
   conversion, shape-specific packing). Each one is measured on SM8550 before it is kept.
3. **Front end on the DSP**: text encoder and predictors from captured ALBERT output (measure one 640 -> 256 BiLSTM
   layer first), then ALBERT.
4. **Runtime length.** Jobs are emitted for a fixed frame count (`Kokoro.DecoderRun16.ps1` `$Frames`); the shipped job
   takes the length at run time or picks from length buckets.
5. **Host chain timing** on both phones: weights mapped once, dspqueue per job, the 30-60 ms invoke overhead found and
   removed; then the six passages, then breath-group streaming for time to first audio.
