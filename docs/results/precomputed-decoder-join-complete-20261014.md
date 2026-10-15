# Offline precomputed-decoder join experiment: complete

No outstanding STOP condition. Part 1 passes both stock PCM gates and exact
Live/Export -> Supplied-level replay. Part 2 produced and measured all 63 WAVs.
Raw donor features can drive the generator offline, but overlap-add does not
consistently improve the requested join score. Banked levels D are less faithful
to A's decoder output than the frozen control E in all nine cases. These
measurements do not establish listening quality or phone execution.

## Location, commits and execution boundary

Working repository and worktree: C:\Dev\Kokoro-Hexagon-v15-front-end; branch
v15-front-end. Starting commit:
c67d525d3e4d162e77be121fb8a6fbd546813ed2.

Part 1 commit: 0a2bb140aa3c6c84b6dd6b75c059b1607b2cdc03, not pushed.
This receipt is prepared before the Part 2 commit; no Part 2 SHA exists yet.
The delivery message records that commit and the final post-commit statuses.
No push was performed.

The offline PowerShell host owns graph dispatch, checkpoint/file I/O and typed
records. Tensor arithmetic runs in typed classes lowered through the unchanged
PSLowering pin 1afabe056235a570da29e268824784557d4f6cdd. Convolutions use
Vector128 and four compiled workers. Weights and folded convolution parameters
remain resident in typed dictionaries across renders. This is an offline tool;
DSP jobs, emitters, pins and the selector were not changed.

C:\Dev\Kokoro-Hexagon-v15-front-end\tools\Invoke-KokoroPrecomputedDecoder.ps1,
initialization, calls "Export-LoweredAssembly" and "Test-LoweredAssembly";
OfflineConvolutionWorker.Run calls "Sse.Multiply" and "Sse.Add", and the host
dispatches "[Threading.Tasks.Task]::Run($action)". Admission reports only
System.Private.CoreLib, SmaReferenced=False, ClrOnlyAdmitted=True, and the
two-worker synthetic convolution check passes. These are observed admission
results, not a claim of complete graph orchestration in standalone IL.

Hardware model, external CPU load isolation, and portability to other CPUs/SDKs:
unverified. No phone or phone lock was used.

## Part 1: numerical gates and fixes

The immutable [Part 1 receipt](C:/Dev/Kokoro-Hexagon-v15-front-end/docs/results/precomputed-decoder-reopen-20261014.md)
contains every one of the 25 nodes before and after each operator fix, source
lines, artifact hashes, and the final node table after level export was added.
Its preparation-time "Part 2 is pending" statement remains a historical snapshot.

The first divergent node was gen.m_source.out0: float32 division by 300 was
replaced by multiplication by the float32 reciprocal when calculating linear
interpolation indices. Stock SineGen uses 'mode="linear"' at
C:\Dev\Kokoro-Hexagon\build\stock-albert-capture-hello\source\kokoro\istftnet.py,
lines 155-157. C:\Dev\.vendor\pytorch\aten\src\ATen\native\UpSample.h,
compute_scales_value line 261, uses "static_cast<scalar_t>(1.0 / scale.value())";
area_pixel_compute_source_index line 299 uses
"scale * (dst_index + static_cast<scalar_t>(0.5))".

The next divergent node was gen.har_phase: DC and Nyquist imaginary components
are structurally real and now use positive zero before atan2. This removes the
spurious -pi branch caused by direct-DFT imaginary residue. Stock TorchSTFT,
istftnet.py line 94, returns "torch.angle(forward_transform)"; Generator line
305 concatenates "torch.cat([har_spec, har_phase], dim=1)". Thus that branch
changes a learned input feature. C:\Dev\.vendor\pytorch\aten\src\ATen\native\SpectralOpsUtils.h,
NOTE Fourier Transform Conjugate Symmetry, states
"X[i_1, ..., i_K] = X[j_i, ..., j_K]*". No fitted activation, weight change or
window tuning was used.

Stock TorchSTFT line 87 uses "periodic=True, dtype=torch.float32".
C:\Dev\.vendor\pytorch\torch\functional.py, stft lines 513-514, declares
"center: bool = True" and 'pad_mode: str = "reflect"'.
The exact correspondence of this local PyTorch source revision to the capture
installation is unverified; the preserved independent tensors establish the
numerical results on the supplied inputs.

All 25 final dog nodes pass the diagnostic tolerance declared before the fixes:
SNR >=80 dB and max error <=1e-4 * max(1, reference peak). This describes
float32 numerical agreement, not bitwise stock parity. The PCM acceptance gate
remains the requested >=60 dB.

Stock gate normalization is Live; "Supplied" in the following table means the
three captured noise draws. Both implementations use the identical captured
inputs and pinned weights. Stock PyTorch and compiled PowerShell are different
implementations, with different float32 reduction/transcendental evaluation
orders. No stock timing comparison is made.

| Case | PCM SNR dB | Max absolute error | Decoder tenth ms | Generator tenth ms |
|---|---:|---:|---:|---:|
| dog | 94.671656 | 7.2047114372253418E-06 | 1417.1781 | 33601.2676 |
| peach | 95.595120 | 6.5974891185760498E-06 | 1884.9959 | 41069.1010 |

Tenth-run artifact SHA-256:
04DA4AB56161ADE365662D605A86A5363DA736D929C05C52E79AFD661566D31C.
These are Stopwatch region wall times, excluding compilation/loading and
including dispatch/allocation. The same resident assembly, four-worker
configuration and captured arrays were reused for all ten runs per case.
Peach's ending sequence overlapped a separate level/admission process; its
timing can include contention. No warm dog decoder exceeded ten seconds.
The final confirmation below is one render per case, not a new tenth-run timing.

The final source and experiment host emit numeric assembly SHA-256:
446FD867E60D8D21F267D9B372A6736D357E84DEF7B680609E8386CBE22D1F8D.
The two neural classes and six neural graph functions compare equal to Part 1
commit 0a2bb14 after normalizing line endings for a read-only AST comparison.
New experiment helpers change assembly metadata/identity but not those neural
definitions. Final confirmation on this assembly:

| Case | Supplied-noise PCM SNR dB | Max absolute error | Live -> Supplied-level replay |
|---|---:|---:|---|
| dog | 94.671656 | 7.2047114372253418E-06 | bit exact, ten sites |
| peach | 95.595120 | 6.5974891185760498E-06 | bit exact, ten sites |

Live/Export accumulates double sums and squared sums of float32 activations for
each token/channel at each decoder site. Mean and variance are derived from
those totals and cast to float32 for normalization. Supplied consumes those
values without measuring decoder activations. This reduction-order difference
from stock is disclosed in the Part 1 receipt. decode.3.norm2 uses twice the
duration frames; the other nine sites use duration frames. Generator
normalization remains Live in every variant.

## Part 2: fixed conditions and selection

All nine targets use af_heart row 25, seed 17, the same generator assembly,
the same per-sentence F0 assembled from selected units, and the same three
draw arrays across all seven variants. Seeded mode draws uniform phase and
Box-Muller Gaussian noise; the seed resets for each sentence. Repeated draw
arrays compare bit for bit. Captured Supplied noise is used only for Part 1.

The unchanged reference selector is
C:\Dev\Kokoro-Hexagon-v15-front-end\tools\reference\unit-bank\mine.ps1,
SHA-256 293DA2E73F207595B2368F224FAC681157AC22BE28EB0913B1674F1093A274FA.
Get-TargetCost and Select-Target retain triphone backoff, up to 4,000 candidates,
best 40 and Viterbi. The existing KOKORO_TARGETW input is set to the published
right-weighted costs and restored afterwards:
C:\Dev\Kokoro-Hexagon-v15-front-end\docs\results\substitution-refinement-20261010.md,
line 43: "right-weighted 4,1,0.5 / 4,8,2".
Removed cost terms: none. Retuned terms/weights: none.

The entire available bank was admitted for this experiment. The reference
indexed 43,679 sentences, 2,429,833 units and 9,862 triphone contexts; selection
of the nine targets took 38,644.2585 ms inside mine.ps1, excluding indexing.
There are 384 selected units, 375 unit boundaries and 210 distinct donors.
Every donor is decoded as a whole sentence with its own bank t_en aligned by
its own durations, F0 and N. There are no per-unit decoder rerenders.

| Variant | Decoder/generator inputs |
|---|---|
| A | Target assembled t_en/durations/F0/N -> Live decoder -> generator |
| B | Concatenated selected slices of whole-donor decoder features -> generator |
| C1/C2/C4 | Same slices extended by 1/2/4 decoder-output frames and sine-window overlap-add -> generator |
| D | A's decoder inputs, with supplied levels composed only from selected donor token moments -> generator |
| E | A's decoder inputs, with one fixed arithmetic mean of all 210 donors' Live means and variances -> generator |

For C, isolated joins use sine-squared/cosine-squared complementary weights,
the effective overlap weights of a sine analysis/synthesis window. A rising
sine-squared ramp spans [join-k, join+k), sampled at frame centers. Adjacent ramp
differences form a nonnegative partition when short units cause multiple
overlaps; the last active weight is the float32 complement of the accumulated
weights. Every frame is checked for an exact float32 weight sum of one.
All 27 actual sentence/k window cases pass. Interior weights are one; output
length and F0 timing are unchanged. Required source neighbouring frames must
exist; no donor padding or extrapolation is invented. This is feature
overlap-add, not a claim of TDAC alias cancellation for neural features.

D composes each site's mean=sum(x)/frames and
variance=sum(x*x)/frames-mean*mean from selected token contributions, with only
a zero clamp for numerical roundoff. It never measures the target decoder's
levels. E averages donors' mean/variance pairs, unweighted by donor length;
it is not a pooled-corpus variance. A supplies the independent Live comparison.

## WAV measurements and join scores

All 63 IEEE float32 mono WAVs are under
[C:\Dev\Kokoro-Hexagon-v15-front-end\build\precomputed-decoder-20261014](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014).
There is no output clipping, gain matching or PCM16 requantization.
Every variant of each sentence has identical frame/sample count.

Measurements call the entrypoint from
C:\Users\Scott\.codex\worktrees\measure-audio\Kokoro-Hexagon,
commit 93a6d8220ed20734b0f5a943ef95b03c922d5be1, with MeasureAudio -Path <folder>.
The tool and its source are unchanged. Its
tools\Kokoro.AudioMeasurement.psm1, DESCRIPTION, names
"ITU-R BS.1770-4 (10/2015), Annex 1 Tables 1-3 and equations 2-7"
and "Annex 2 section 3". The electrical measurement does not establish
phone-speaker playback or perceived quality.

The join numerator is the largest absolute adjacent-sample difference within
+/-240 samples (10 ms at 24 kHz) around each selected unit boundary, including
boundaries between consecutive units of one donor. The denominator is the
sentence median of maximum adjacent differences in every complete 480-sample
window, with a one-sample hop (479 differences per window). Reported max/median
are over the unit-boundary ratios. PCM used for the join score is exactly the
float32 WAV data. All variants use the same measurement implementation and
conditions; the feature assembly and named decoder-level modes are their
intentional differences. Part 2 A is an assembled-bank baseline, not stock PCM.

| Sentence | Variant | Integrated LUFS | True peak dBTP | Join maximum | Join median | WAV |
|---:|---|---:|---:|---:|---:|---|
| 1 | A | -25.617 | -10.925 | 7.579843 | 2.031841 | [01-A.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/01-A.wav) |
| 1 | B | -25.471 | -9.220 | 7.218673 | 1.676434 | [01-B.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/01-B.wav) |
| 1 | C1 | -25.480 | -9.033 | 7.172945 | 1.656896 | [01-C1.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/01-C1.wav) |
| 1 | C2 | -25.498 | -8.941 | 6.975783 | 1.610382 | [01-C2.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/01-C2.wav) |
| 1 | C4 | -25.553 | -9.372 | 7.068629 | 1.622763 | [01-C4.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/01-C4.wav) |
| 1 | D | -25.542 | -10.606 | 8.653035 | 2.179128 | [01-D.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/01-D.wav) |
| 1 | E | -25.574 | -9.770 | 8.018412 | 1.751078 | [01-E.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/01-E.wav) |
| 2 | A | -25.800 | -6.050 | 19.979585 | 1.278601 | [02-A.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/02-A.wav) |
| 2 | B | -25.881 | -5.949 | 10.480231 | 1.340237 | [02-B.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/02-B.wav) |
| 2 | C1 | -25.887 | -5.967 | 11.356217 | 1.354350 | [02-C1.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/02-C1.wav) |
| 2 | C2 | -25.899 | -5.934 | 11.660781 | 1.386303 | [02-C2.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/02-C2.wav) |
| 2 | C4 | -25.941 | -5.952 | 11.020982 | 1.421149 | [02-C4.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/02-C4.wav) |
| 2 | D | -25.782 | -6.220 | 17.205452 | 1.385130 | [02-D.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/02-D.wav) |
| 2 | E | -25.793 | -5.820 | 20.496864 | 1.439665 | [02-E.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/02-E.wav) |
| 3 | A | -26.053 | -10.658 | 17.673402 | 1.566676 | [03-A.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/03-A.wav) |
| 3 | B | -26.205 | -8.044 | 17.139892 | 1.782880 | [03-B.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/03-B.wav) |
| 3 | C1 | -26.210 | -8.147 | 16.683711 | 1.722664 | [03-C1.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/03-C1.wav) |
| 3 | C2 | -26.214 | -8.335 | 16.490019 | 1.699943 | [03-C2.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/03-C2.wav) |
| 3 | C4 | -26.212 | -8.844 | 16.904058 | 1.729044 | [03-C4.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/03-C4.wav) |
| 3 | D | -26.213 | -9.774 | 18.339134 | 1.542102 | [03-D.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/03-D.wav) |
| 3 | E | -25.925 | -9.928 | 18.409009 | 1.824191 | [03-E.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/03-E.wav) |
| 4 | A | -26.297 | -10.441 | 12.875285 | 1.405214 | [04-A.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/04-A.wav) |
| 4 | B | -26.442 | -10.839 | 12.195301 | 1.254295 | [04-B.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/04-B.wav) |
| 4 | C1 | -26.456 | -10.857 | 12.743645 | 1.293551 | [04-C1.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/04-C1.wav) |
| 4 | C2 | -26.474 | -10.879 | 12.645298 | 1.330396 | [04-C2.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/04-C2.wav) |
| 4 | C4 | -26.514 | -10.907 | 12.525201 | 1.330234 | [04-C4.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/04-C4.wav) |
| 4 | D | -26.240 | -9.396 | 13.112874 | 1.398158 | [04-D.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/04-D.wav) |
| 4 | E | -26.432 | -10.982 | 12.542169 | 1.325904 | [04-E.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/04-E.wav) |
| 5 | A | -26.702 | -11.033 | 23.104703 | 1.533529 | [05-A.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/05-A.wav) |
| 5 | B | -26.597 | -11.372 | 24.168303 | 1.790292 | [05-B.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/05-B.wav) |
| 5 | C1 | -26.598 | -11.391 | 24.232642 | 1.788322 | [05-C1.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/05-C1.wav) |
| 5 | C2 | -26.603 | -11.415 | 24.441507 | 1.787966 | [05-C2.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/05-C2.wav) |
| 5 | C4 | -26.629 | -11.464 | 24.978793 | 1.804350 | [05-C4.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/05-C4.wav) |
| 5 | D | -26.743 | -10.939 | 18.337334 | 1.765832 | [05-D.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/05-D.wav) |
| 5 | E | -26.813 | -10.759 | 22.871734 | 1.657713 | [05-E.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/05-E.wav) |
| 6 | A | -26.789 | -10.942 | 7.729218 | 1.786374 | [06-A.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/06-A.wav) |
| 6 | B | -26.811 | -10.957 | 8.743746 | 1.423990 | [06-B.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/06-B.wav) |
| 6 | C1 | -26.814 | -10.966 | 8.730879 | 1.452922 | [06-C1.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/06-C1.wav) |
| 6 | C2 | -26.818 | -10.974 | 8.709477 | 1.488078 | [06-C2.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/06-C2.wav) |
| 6 | C4 | -26.828 | -11.019 | 8.861225 | 1.468127 | [06-C4.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/06-C4.wav) |
| 6 | D | -26.931 | -10.337 | 7.838060 | 1.714616 | [06-D.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/06-D.wav) |
| 6 | E | -26.770 | -10.947 | 7.425380 | 1.405995 | [06-E.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/06-E.wav) |
| 7 | A | -26.017 | -9.330 | 20.857036 | 1.746504 | [07-A.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/07-A.wav) |
| 7 | B | -26.189 | -10.216 | 20.702344 | 2.045625 | [07-B.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/07-B.wav) |
| 7 | C1 | -26.199 | -10.250 | 20.538294 | 2.044524 | [07-C1.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/07-C1.wav) |
| 7 | C2 | -26.209 | -10.321 | 20.359713 | 2.041887 | [07-C2.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/07-C2.wav) |
| 7 | C4 | -26.230 | -10.460 | 20.831772 | 2.104233 | [07-C4.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/07-C4.wav) |
| 7 | D | -25.892 | -8.683 | 26.434204 | 1.873495 | [07-D.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/07-D.wav) |
| 7 | E | -26.055 | -9.537 | 19.894250 | 1.825127 | [07-E.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/07-E.wav) |
| 8 | A | -26.023 | -6.176 | 20.441006 | 2.731366 | [08-A.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/08-A.wav) |
| 8 | B | -25.903 | -6.139 | 27.103052 | 2.501176 | [08-B.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/08-B.wav) |
| 8 | C1 | -25.906 | -6.148 | 27.793756 | 2.753197 | [08-C1.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/08-C1.wav) |
| 8 | C2 | -25.912 | -6.170 | 27.305269 | 2.585309 | [08-C2.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/08-C2.wav) |
| 8 | C4 | -25.935 | -6.236 | 26.943077 | 2.683504 | [08-C4.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/08-C4.wav) |
| 8 | D | -25.839 | -6.549 | 17.378720 | 3.173231 | [08-D.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/08-D.wav) |
| 8 | E | -26.048 | -5.437 | 21.256345 | 2.756545 | [08-E.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/08-E.wav) |
| 9 | A | -26.875 | -10.406 | 9.922274 | 1.330885 | [09-A.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/09-A.wav) |
| 9 | B | -27.005 | -10.947 | 9.682262 | 1.289076 | [09-B.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/09-B.wav) |
| 9 | C1 | -27.009 | -10.998 | 9.313342 | 1.268591 | [09-C1.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/09-C1.wav) |
| 9 | C2 | -27.016 | -11.001 | 9.285153 | 1.297363 | [09-C2.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/09-C2.wav) |
| 9 | C4 | -27.039 | -11.175 | 8.844484 | 1.234802 | [09-C4.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/09-C4.wav) |
| 9 | D | -26.689 | -9.284 | 9.636320 | 1.492415 | [09-D.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/09-D.wav) |
| 9 | E | -26.893 | -10.575 | 9.601635 | 1.319254 | [09-E.wav](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014/09-E.wav) |

## Banked/frozen decoder output versus A

Same target decoder input arrays, style, weights, assembly and SNR reduction;
only the supplied level source differs. These are experimental feature SNRs,
not the stock PCM acceptance gate.

| Sentence | D vs A decoder SNR dB | E vs A decoder SNR dB |
|---:|---:|---:|
| 1 | 6.077998 | 11.102450 |
| 2 | 12.217050 | 16.591301 |
| 3 | 10.775122 | 15.696552 |
| 4 | 11.623398 | 17.700498 |
| 5 | 9.634707 | 16.664945 |
| 6 | 12.532421 | 17.175045 |
| 7 | 11.821568 | 16.696968 |
| 8 | 11.190212 | 15.909259 |
| 9 | 10.543353 | 17.669810 |

## Per-site composed levels versus A's true Live levels

Dimensionless relative errors, across channels of the named site. Standard
deviation is sqrt(variance), without normalization epsilon. Relative-error
denominators use max(abs(reference),1e-12); near-zero means can give large maxima.
This floor defines the reported ratio only and does not alter rendering.
All pairs use the same target, artifact and conditions; one side is composed
donor levels and the other is A's measured Live levels.

| Sentence | Site | Mean max relative | Mean median relative | Std max relative | Std median relative |
|---:|---|---:|---:|---:|---:|
| 1 | encode.norm1 | 0.0245452764 | 0 | 0.000710933341 | 0 |
| 1 | encode.norm2 | 60.7590179 | 0.150107722 | 0.463026105 | 0.0445507635 |
| 1 | decode.0.norm1 | 2218.9786 | 0.358662786 | 0.397354405 | 0.0651333855 |
| 1 | decode.0.norm2 | 45.1773879 | 0.136713218 | 0.78019197 | 0.157814316 |
| 1 | decode.1.norm1 | 215.810137 | 0.534989554 | 0.735671987 | 0.114461568 |
| 1 | decode.1.norm2 | 92.9025576 | 0.167546542 | 0.847498716 | 0.118919837 |
| 1 | decode.2.norm1 | 348.26658 | 0.537098047 | 0.698646569 | 0.094197258 |
| 1 | decode.2.norm2 | 45.72894 | 0.15013723 | 0.533770973 | 0.0967016414 |
| 1 | decode.3.norm1 | 3200.85669 | 0.435613343 | 0.490830307 | 0.0773053658 |
| 1 | decode.3.norm2 | 55.0038309 | 0.0504226265 | 0.526170075 | 0.0890226211 |
| 2 | encode.norm1 | 0.00191206088 | 0 | 0.00369140291 | 0 |
| 2 | encode.norm2 | 217.716876 | 0.0773331664 | 0.183778961 | 0.03503142 |
| 2 | decode.0.norm1 | 730.137368 | 0.150858715 | 0.151481637 | 0.0227739526 |
| 2 | decode.0.norm2 | 42.3951126 | 0.0629553854 | 0.205562702 | 0.0334521299 |
| 2 | decode.1.norm1 | 95.7537702 | 0.221063358 | 0.27122941 | 0.0304090088 |
| 2 | decode.1.norm2 | 33.4844891 | 0.0931273992 | 0.404961235 | 0.0312672698 |
| 2 | decode.2.norm1 | 1056.99925 | 0.306455626 | 0.170819661 | 0.0272019189 |
| 2 | decode.2.norm2 | 39.6600255 | 0.0971729391 | 0.151189251 | 0.0305904595 |
| 2 | decode.3.norm1 | 758.028786 | 0.314929698 | 0.143281028 | 0.0278685658 |
| 2 | decode.3.norm2 | 10.9141659 | 0.0209277398 | 0.191612034 | 0.0298511703 |
| 3 | encode.norm1 | 0.00633043618 | 0 | 0.00214461769 | 0 |
| 3 | encode.norm2 | 266.094211 | 0.0739838313 | 0.250286179 | 0.0385301674 |
| 3 | decode.0.norm1 | 161.939058 | 0.170054206 | 0.196544045 | 0.0248717041 |
| 3 | decode.0.norm2 | 37.6990309 | 0.0607893484 | 0.266674823 | 0.0409175283 |
| 3 | decode.1.norm1 | 1252.76511 | 0.237081036 | 0.258310762 | 0.0344080273 |
| 3 | decode.1.norm2 | 88.6625058 | 0.0978590312 | 0.27581168 | 0.0408166545 |
| 3 | decode.2.norm1 | 309.083067 | 0.333671968 | 0.199897526 | 0.0339576891 |
| 3 | decode.2.norm2 | 27.9823476 | 0.104620869 | 0.33981492 | 0.0337584052 |
| 3 | decode.3.norm1 | 143.782084 | 0.345788733 | 0.228167268 | 0.0310392954 |
| 3 | decode.3.norm2 | 33.0600389 | 0.0242424279 | 0.208804755 | 0.0307432222 |
| 4 | encode.norm1 | 0.00210489758 | 0 | 0.00120082958 | 0 |
| 4 | encode.norm2 | 2465.72696 | 0.0891803839 | 0.284298962 | 0.0321537083 |
| 4 | decode.0.norm1 | 733.945861 | 0.163006922 | 0.212803379 | 0.0265837077 |
| 4 | decode.0.norm2 | 4.56798101 | 0.0516173005 | 0.335781618 | 0.03972642 |
| 4 | decode.1.norm1 | 121.033281 | 0.215727685 | 0.389186381 | 0.0330844665 |
| 4 | decode.1.norm2 | 24.9475265 | 0.0863734909 | 0.293107063 | 0.0392951493 |
| 4 | decode.2.norm1 | 736.002857 | 0.266013554 | 0.287362784 | 0.0348408916 |
| 4 | decode.2.norm2 | 48.2964388 | 0.0891139536 | 0.184846769 | 0.0348362357 |
| 4 | decode.3.norm1 | 149.136608 | 0.298328472 | 0.290351823 | 0.0338108029 |
| 4 | decode.3.norm2 | 5.64476554 | 0.0192435707 | 0.13651232 | 0.0256098369 |
| 5 | encode.norm1 | 0.00356392532 | 0 | 0.00416908761 | 0 |
| 5 | encode.norm2 | 44.5060164 | 0.0943615504 | 0.32658207 | 0.0392449335 |
| 5 | decode.0.norm1 | 162.228932 | 0.177235191 | 0.381481852 | 0.034512658 |
| 5 | decode.0.norm2 | 7.1782969 | 0.0555623688 | 0.357563085 | 0.0527465915 |
| 5 | decode.1.norm1 | 186.668558 | 0.253153862 | 0.607550174 | 0.04650925 |
| 5 | decode.1.norm2 | 23.5249767 | 0.0879819352 | 0.357355781 | 0.0453304027 |
| 5 | decode.2.norm1 | 217.971942 | 0.317232735 | 0.517082544 | 0.0468029652 |
| 5 | decode.2.norm2 | 57.5267473 | 0.0910177148 | 0.256558023 | 0.0455527816 |
| 5 | decode.3.norm1 | 378.412424 | 0.321028954 | 0.386406291 | 0.0399031967 |
| 5 | decode.3.norm2 | 16.8957579 | 0.0218713464 | 0.143349401 | 0.0302429744 |
| 6 | encode.norm1 | 0.00364144734 | 0 | 0.00247279974 | 0 |
| 6 | encode.norm2 | 126.113739 | 0.0735151808 | 0.1953167 | 0.0387723185 |
| 6 | decode.0.norm1 | 3438.44907 | 0.124978086 | 0.156011537 | 0.0260354554 |
| 6 | decode.0.norm2 | 8.67370077 | 0.0502347281 | 0.165726157 | 0.0294750431 |
| 6 | decode.1.norm1 | 678.05572 | 0.188948486 | 0.150461059 | 0.0303014539 |
| 6 | decode.1.norm2 | 39.3603106 | 0.0777117581 | 0.165527819 | 0.0278866726 |
| 6 | decode.2.norm1 | 361.825007 | 0.27808859 | 0.138218269 | 0.0269313576 |
| 6 | decode.2.norm2 | 15.0372632 | 0.0897576294 | 0.17301939 | 0.0281997252 |
| 6 | decode.3.norm1 | 506.078021 | 0.303347705 | 0.174905631 | 0.0255707897 |
| 6 | decode.3.norm2 | 6.64311033 | 0.0199134679 | 0.149527298 | 0.0249434957 |
| 7 | encode.norm1 | 0.00134602085 | 0 | 0.00131169249 | 0 |
| 7 | encode.norm2 | 35.3398474 | 0.0735731929 | 0.31316602 | 0.0411790351 |
| 7 | decode.0.norm1 | 34.7949729 | 0.12874115 | 0.192121584 | 0.0269548188 |
| 7 | decode.0.norm2 | 14.4418315 | 0.057746427 | 0.177621132 | 0.0327603186 |
| 7 | decode.1.norm1 | 1229.72931 | 0.19163872 | 0.161900471 | 0.0318506586 |
| 7 | decode.1.norm2 | 20.6894104 | 0.0824983345 | 0.17596396 | 0.0325716955 |
| 7 | decode.2.norm1 | 80.9934107 | 0.26638986 | 0.19658422 | 0.030540064 |
| 7 | decode.2.norm2 | 35.4148999 | 0.0948200983 | 0.174793057 | 0.0319865988 |
| 7 | decode.3.norm1 | 5090.95272 | 0.324933533 | 0.234586526 | 0.0273123726 |
| 7 | decode.3.norm2 | 67.7640194 | 0.0205099441 | 0.136926445 | 0.0279685991 |
| 8 | encode.norm1 | 0.00738952799 | 0 | 0.000822982182 | 0 |
| 8 | encode.norm2 | 120.459905 | 0.0809649203 | 0.286177968 | 0.0339057962 |
| 8 | decode.0.norm1 | 397.828246 | 0.171916831 | 0.27521951 | 0.0293892438 |
| 8 | decode.0.norm2 | 108.265717 | 0.0573863432 | 0.244969689 | 0.0436279065 |
| 8 | decode.1.norm1 | 130.587332 | 0.203629414 | 0.339588528 | 0.0418355476 |
| 8 | decode.1.norm2 | 81.304332 | 0.0760924879 | 0.247046432 | 0.0489078447 |
| 8 | decode.2.norm1 | 11686.0025 | 0.23972567 | 0.249981214 | 0.04490369 |
| 8 | decode.2.norm2 | 15.0137528 | 0.0813320443 | 0.27607779 | 0.0429402336 |
| 8 | decode.3.norm1 | 203.705661 | 0.259289232 | 0.300511544 | 0.0355344302 |
| 8 | decode.3.norm2 | 4.31152288 | 0.0246131511 | 0.1747972 | 0.0341048514 |
| 9 | encode.norm1 | 0.00559369917 | 0 | 0.00153200561 | 0 |
| 9 | encode.norm2 | 62.0345117 | 0.0750287529 | 0.469321525 | 0.0389820547 |
| 9 | decode.0.norm1 | 33.0510934 | 0.144589118 | 0.378162073 | 0.0369462447 |
| 9 | decode.0.norm2 | 10.0287891 | 0.0557225893 | 0.510797864 | 0.062875565 |
| 9 | decode.1.norm1 | 393.518012 | 0.237058663 | 0.597900045 | 0.050920891 |
| 9 | decode.1.norm2 | 158.687449 | 0.087644207 | 0.405317852 | 0.048790733 |
| 9 | decode.2.norm1 | 2508.06027 | 0.295511383 | 0.625611653 | 0.0444586084 |
| 9 | decode.2.norm2 | 38.4367072 | 0.0865686371 | 0.322327465 | 0.038258829 |
| 9 | decode.3.norm1 | 191.033471 | 0.297085371 | 0.444580321 | 0.0414096333 |
| 9 | decode.3.norm2 | 2.98385659 | 0.0192615207 | 0.262574638 | 0.0446579591 |

## Donor decoder times

One offline pass per donor, four workers. Stopwatch covers the decoder region.
Early calls can include first-use JIT, lazy weight loading/folding and allocation;
later calls reuse resident parameters. These are individual non-isolated
single-pass observations, not a controlled before/after speed comparison.
Generator single-pass times remain in measurements.clixml; Part 1's tenth-run
table is the requested warm decoder/generator timing.

| Donor sentence ID | Tokens | Decoder-output frames | Decoder ms |
|---:|---:|---:|---:|
| 21 | 26 | 158 | 2636.8822 |
| 62 | 113 | 594 | 8306.3385 |
| 222 | 51 | 248 | 3688.0147 |
| 555 | 29 | 168 | 1674.6064 |
| 577 | 34 | 186 | 1657.2635 |
| 815 | 29 | 166 | 1410.5048 |
| 841 | 45 | 246 | 2266.2981 |
| 1012 | 91 | 472 | 4745.5549 |
| 1027 | 72 | 360 | 3527.8775 |
| 1056 | 30 | 176 | 1593.6750 |
| 1081 | 36 | 192 | 1523.0916 |
| 1206 | 70 | 368 | 4808.7937 |
| 1469 | 67 | 370 | 4175.6929 |
| 1511 | 58 | 296 | 2585.2939 |
| 1641 | 41 | 216 | 1824.5010 |
| 1814 | 37 | 204 | 1748.5060 |
| 2230 | 48 | 258 | 2711.4496 |
| 2428 | 61 | 306 | 2463.1170 |
| 2748 | 70 | 330 | 2825.2658 |
| 2778 | 104 | 534 | 4777.2859 |
| 2835 | 48 | 238 | 2741.2547 |
| 2924 | 45 | 224 | 1873.3732 |
| 3180 | 39 | 196 | 1628.5897 |
| 3211 | 58 | 274 | 2424.2513 |
| 3332 | 64 | 348 | 3405.9485 |
| 3422 | 44 | 246 | 2515.2489 |
| 3478 | 39 | 210 | 2064.8477 |
| 3592 | 25 | 156 | 1874.7267 |
| 3674 | 50 | 266 | 2627.7793 |
| 3986 | 21 | 148 | 1511.5269 |
| 4218 | 77 | 420 | 4457.3575 |
| 4233 | 84 | 418 | 5056.7696 |
| 4354 | 34 | 180 | 1968.6592 |
| 4378 | 50 | 280 | 2425.1040 |
| 4472 | 47 | 256 | 1997.6944 |
| 4510 | 88 | 454 | 3685.4654 |
| 4616 | 42 | 228 | 2068.7123 |
| 4792 | 43 | 232 | 1780.1594 |
| 4814 | 76 | 382 | 3789.3062 |
| 4949 | 32 | 182 | 2068.0543 |
| 4957 | 59 | 292 | 3704.8126 |
| 5000 | 73 | 370 | 3690.3120 |
| 5245 | 32 | 168 | 1340.7220 |
| 5262 | 65 | 312 | 3188.3809 |
| 5282 | 79 | 386 | 3262.8851 |
| 5421 | 39 | 210 | 2100.8879 |
| 5555 | 53 | 274 | 2232.1033 |
| 5930 | 100 | 514 | 4416.2880 |
| 5941 | 101 | 524 | 3979.3861 |
| 6340 | 51 | 272 | 2165.8775 |
| 6382 | 82 | 406 | 4170.8243 |
| 6494 | 48 | 234 | 3079.0934 |
| 6639 | 76 | 386 | 4920.9749 |
| 6767 | 36 | 202 | 2469.0667 |
| 6842 | 54 | 282 | 2965.5052 |
| 6855 | 74 | 400 | 4608.2340 |
| 6879 | 95 | 506 | 5175.1992 |
| 7215 | 85 | 432 | 5017.8552 |
| 7403 | 69 | 334 | 3303.2064 |
| 7456 | 93 | 502 | 4683.5084 |
| 7592 | 49 | 242 | 2492.6351 |
| 8033 | 91 | 470 | 3916.9063 |
| 8035 | 67 | 338 | 2826.6404 |
| 8053 | 47 | 252 | 2199.4252 |
| 8128 | 65 | 342 | 2856.0876 |
| 8166 | 41 | 218 | 2120.1464 |
| 8300 | 93 | 476 | 5735.2260 |
| 8364 | 81 | 366 | 6178.5540 |
| 8429 | 67 | 328 | 2646.1758 |
| 8462 | 20 | 140 | 1252.7401 |
| 8761 | 53 | 244 | 2613.4331 |
| 8852 | 108 | 532 | 6267.7984 |
| 8974 | 39 | 210 | 2156.0483 |
| 9037 | 71 | 352 | 3809.7701 |
| 9073 | 39 | 226 | 2963.5966 |
| 9341 | 28 | 156 | 2850.3775 |
| 9389 | 79 | 396 | 5408.6758 |
| 9447 | 82 | 420 | 6725.8859 |
| 9638 | 37 | 188 | 2455.8767 |
| 9657 | 61 | 310 | 3142.3125 |
| 10284 | 63 | 302 | 2991.4996 |
| 10351 | 86 | 430 | 3445.6725 |
| 10802 | 26 | 158 | 1266.4584 |
| 11150 | 70 | 356 | 3230.3263 |
| 11379 | 77 | 382 | 3687.7532 |
| 11445 | 33 | 198 | 1775.4827 |
| 11479 | 91 | 454 | 3625.3003 |
| 11588 | 60 | 320 | 2629.4184 |
| 11697 | 89 | 486 | 3962.2599 |
| 12852 | 26 | 158 | 1240.3744 |
| 12861 | 36 | 216 | 1653.8690 |
| 12964 | 84 | 394 | 4231.2169 |
| 13177 | 46 | 234 | 2328.3351 |
| 13415 | 27 | 162 | 2119.5684 |
| 13499 | 68 | 370 | 3657.1781 |
| 14093 | 59 | 298 | 2590.9334 |
| 14273 | 97 | 476 | 3859.7641 |
| 14324 | 44 | 228 | 1781.8428 |
| 14646 | 72 | 338 | 2721.8651 |
| 14817 | 84 | 384 | 3915.7674 |
| 14881 | 46 | 242 | 2810.1592 |
| 14913 | 85 | 438 | 5858.0646 |
| 14928 | 69 | 348 | 6812.4777 |
| 14967 | 55 | 290 | 3526.4429 |
| 15049 | 74 | 378 | 4210.5639 |
| 15050 | 42 | 238 | 2564.1128 |
| 15205 | 31 | 162 | 1695.4280 |
| 15558 | 69 | 352 | 3631.3118 |
| 15603 | 29 | 168 | 1358.5635 |
| 15787 | 44 | 236 | 2343.9626 |
| 15827 | 42 | 204 | 1687.5763 |
| 15861 | 36 | 198 | 1841.1882 |
| 16022 | 33 | 192 | 2135.8636 |
| 16632 | 61 | 338 | 4426.9587 |
| 16649 | 38 | 188 | 1522.3417 |
| 17077 | 59 | 294 | 2341.1650 |
| 17620 | 81 | 412 | 3453.6825 |
| 17624 | 59 | 282 | 2828.0185 |
| 18229 | 67 | 324 | 2901.4976 |
| 18282 | 83 | 436 | 3546.8559 |
| 18310 | 84 | 420 | 4780.8701 |
| 18675 | 69 | 344 | 5254.4271 |
| 18811 | 33 | 180 | 2156.1326 |
| 18822 | 86 | 448 | 6497.9298 |
| 18991 | 38 | 198 | 1718.2051 |
| 19008 | 69 | 338 | 2513.6890 |
| 19202 | 24 | 144 | 1149.9158 |
| 19598 | 62 | 322 | 2699.9128 |
| 20143 | 99 | 446 | 4187.3022 |
| 20597 | 28 | 164 | 1267.2688 |
| 20869 | 60 | 286 | 2093.6912 |
| 21004 | 53 | 284 | 2063.6182 |
| 21136 | 28 | 160 | 1108.9896 |
| 21752 | 36 | 198 | 1567.3396 |
| 21825 | 71 | 374 | 4087.7277 |
| 21958 | 69 | 352 | 3842.4799 |
| 22069 | 38 | 208 | 2103.2617 |
| 22077 | 73 | 362 | 2915.6288 |
| 22112 | 96 | 506 | 4716.2199 |
| 22192 | 67 | 336 | 2567.9115 |
| 22463 | 30 | 174 | 1300.5369 |
| 22692 | 64 | 324 | 3254.7206 |
| 23062 | 37 | 200 | 1360.5091 |
| 23755 | 83 | 414 | 3157.0702 |
| 24235 | 66 | 354 | 2833.3981 |
| 24400 | 21 | 150 | 1214.4184 |
| 24536 | 69 | 332 | 2918.7813 |
| 24744 | 70 | 352 | 2516.7279 |
| 24747 | 64 | 318 | 2673.8035 |
| 25125 | 28 | 162 | 1202.2097 |
| 25134 | 68 | 356 | 2547.3598 |
| 25363 | 25 | 142 | 1247.4888 |
| 25805 | 49 | 274 | 2272.7495 |
| 25884 | 47 | 236 | 2028.2415 |
| 26169 | 89 | 468 | 3631.1863 |
| 26292 | 44 | 268 | 3147.0160 |
| 26353 | 112 | 562 | 7448.0911 |
| 26358 | 61 | 328 | 4353.8195 |
| 27012 | 47 | 258 | 3483.1862 |
| 27146 | 89 | 460 | 4960.7373 |
| 27876 | 53 | 280 | 2288.2297 |
| 28305 | 83 | 420 | 3451.7082 |
| 28345 | 71 | 332 | 2912.3158 |
| 28423 | 36 | 170 | 1413.9119 |
| 29025 | 57 | 302 | 2405.9117 |
| 29231 | 81 | 378 | 3103.3813 |
| 29364 | 73 | 386 | 3132.9992 |
| 29499 | 39 | 206 | 2441.0069 |
| 29608 | 31 | 180 | 1429.0813 |
| 29745 | 73 | 378 | 4818.9729 |
| 30025 | 40 | 230 | 3082.3194 |
| 30055 | 75 | 396 | 4715.2654 |
| 30289 | 77 | 382 | 4498.0563 |
| 30482 | 60 | 266 | 3108.6714 |
| 31019 | 62 | 304 | 3773.3127 |
| 31095 | 35 | 202 | 1756.2071 |
| 31298 | 60 | 324 | 4186.2119 |
| 31353 | 113 | 536 | 5071.2473 |
| 31881 | 73 | 342 | 2762.7028 |
| 32723 | 78 | 354 | 2899.0074 |
| 34270 | 42 | 204 | 1865.9536 |
| 34477 | 57 | 276 | 2669.3261 |
| 34556 | 59 | 290 | 2465.9527 |
| 34702 | 53 | 256 | 2070.1067 |
| 34953 | 77 | 398 | 3120.1270 |
| 35183 | 57 | 292 | 2379.8149 |
| 35231 | 64 | 348 | 3274.4463 |
| 35258 | 65 | 344 | 2653.1969 |
| 35462 | 28 | 160 | 1227.6923 |
| 36218 | 93 | 462 | 3826.6767 |
| 36651 | 44 | 242 | 2151.0103 |
| 37039 | 44 | 220 | 1666.5909 |
| 37677 | 74 | 358 | 4453.3892 |
| 37850 | 40 | 200 | 1708.6567 |
| 37922 | 88 | 436 | 5030.7303 |
| 38222 | 77 | 408 | 4041.6207 |
| 38529 | 93 | 474 | 5575.4045 |
| 38814 | 102 | 526 | 5691.8958 |
| 39682 | 78 | 402 | 4886.7212 |
| 40215 | 51 | 248 | 3414.2516 |
| 40387 | 54 | 288 | 3458.0997 |
| 40852 | 76 | 352 | 4595.0386 |
| 41261 | 68 | 342 | 4339.4860 |
| 41329 | 44 | 230 | 2357.4412 |
| 41367 | 41 | 222 | 2255.5983 |
| 41442 | 60 | 296 | 3432.4442 |
| 42528 | 25 | 156 | 1971.8502 |
| 42530 | 67 | 330 | 3344.1825 |
| 42838 | 48 | 234 | 2061.5512 |
| 43169 | 41 | 222 | 1909.7178 |

## Selected unit records

Each entry below is donor-sentence-ID:token-index; the token range is
[index,index+1). Full donor text and decoder-output frame ranges are recorded in
C:\Dev\Kokoro-Hexagon-v15-front-end\build\precomputed-decoder-20261014\selected-units.clixml.
The native offsets and per-site token frame counts are in donors.clixml.
No selection path was changed during rendering.

Sentence 1: I can eat a peach for hours.

    35258:0 6494:1 6494:2 6494:3 34477:4 8128:6 39682:63 14967:21 42838:32 42838:33 3422:34 9657:17 9657:18 26358:40 26358:41 10802:7 10802:8 10802:9 10802:10 11697:68 8974:28 19008:45 29608:25 29608:26 29608:27 9389:76 9389:77 1081:35

Sentence 2: She left her keys on the kitchen table again.

    26292:0 26292:1 1056:2 1056:3 1056:4 27876:5 27876:6 32723:7 32723:8 23755:21 23755:22 28423:13 28423:14 28423:15 12852:20 43169:26 2835:34 37922:41 37922:42 37922:43 37922:44 20869:49 577:20 577:21 8053:33 8053:34 8053:35 8053:36 8053:37 40852:33 4472:39 24235:27 4218:69 14273:90 7456:82 7456:83 31298:50 8033:37 8033:38 8033:39 8033:40 6639:71 11588:56 11588:57 11588:58 555:28

Sentence 3: Please call me when you get home tonight.

    34270:0 34270:1 34270:2 34270:3 11379:33 15050:3 15050:4 13415:12 13415:13 20597:14 20597:15 20597:16 15827:12 15827:13 14928:12 13177:16 18991:25 2748:12 2748:13 40215:36 40215:37 16632:35 35462:12 35462:13 21136:13 25134:52 25134:53 25134:54 25134:55 25134:56 1511:23 37039:21 37039:22 9341:19 9341:20 9341:21 9341:22 9341:23 9341:24 14646:69 14646:70 4354:33

Sentence 4: My brother plays the guitar in a small band.

    9638:0 9638:1 9638:2 9638:3 1012:54 1012:55 25125:21 25125:22 28345:22 34556:49 7403:35 17077:23 17077:24 26169:33 11445:16 11445:17 11445:18 11445:19 4616:33 4616:34 22692:46 3332:41 29364:60 30055:14 34702:36 14817:21 19598:9 19598:10 4510:7 4510:8 38222:33 11479:11 11479:12 11479:13 11479:14 11479:15 27012:31 27012:32 27012:33 21825:45 30025:34 30025:35 30025:36 36651:41 18310:82 222:50

Sentence 5: We should plant more trees along the river.

    8462:0 30482:1 15603:2 15603:3 15603:4 15603:5 42528:6 42528:7 21958:17 4378:19 14881:21 29231:62 37677:55 37677:56 37677:57 9447:66 9447:67 34953:63 34953:64 34953:65 40387:29 40387:30 24747:39 36218:45 36218:46 36218:47 36218:48 36218:49 4949:19 5941:80 5941:81 5941:82 5941:83 5941:84 1027:46 815:21 815:22 815:23 815:24 815:25 815:26 10351:84 1814:36

Sentence 6: The children laughed at the funny little dog.

    12861:0 1206:1 1206:2 1206:3 1206:4 11150:50 29499:9 29499:10 29499:11 25884:9 8166:19 8166:20 8166:21 8166:22 8166:23 41367:19 21004:27 21004:28 21004:29 21004:30 20143:18 20143:19 3211:19 3211:20 12964:24 12964:25 8429:26 8429:27 41442:22 41442:23 3180:15 3180:16 22463:16 22463:17 22077:57 5262:14 5555:38 17624:19 17624:20 6842:49 6842:50 6842:51 6842:52 2428:60

Sentence 7: He forgot to bring an umbrella this morning.

    18811:0 13499:1 31019:2 41329:14 41329:15 6855:48 37850:5 37850:6 16649:12 5245:10 5245:11 5245:12 15049:21 8761:38 8761:39 8761:40 35183:24 35183:25 35183:26 5930:52 5930:53 38529:17 8852:96 8852:97 8852:98 8852:99 8852:100 8852:101 8852:102 62:52 2778:35 2778:36 6879:47 9073:23 3478:28 14324:33 14324:34 5421:30 5421:31 41261:61 29745:67 29745:68 29745:69 6340:48 6340:49 3674:49

Sentence 8: Our train was late, so we missed the meeting.

    28305:0 28305:1 28305:2 28305:3 19202:17 19202:18 14913:68 18675:39 42530:16 42530:17 26353:32 18229:42 7592:33 2924:7 2924:8 15787:8 31095:19 22112:45 17620:37 17620:38 4233:23 8035:42 24744:51 18822:12 18822:13 29025:33 10284:54 22192:32 15558:12 6382:56 6382:57 6382:58 841:35 841:36 38814:15 5282:20 25363:18 25363:19 25363:20 25363:21 25363:22 25363:23 1641:40

Sentence 9: There is a bakery on the corner of my street.

    4792:0 24536:1 4957:2 4957:3 25805:4 24400:5 5000:7 1469:36 3986:8 2230:40 15861:28 15861:29 27146:76 27146:77 23062:21 8300:72 8300:73 8300:74 8300:75 7215:33 20869:49 577:20 577:21 30289:50 8364:50 8364:51 15205:24 4814:60 4814:61 4814:62 4814:63 22069:26 9037:23 9037:24 18282:50 35231:52 14093:23 31881:62 31881:63 16022:26 6767:30 21752:31 21752:32 21:23 31353:111 3592:24

## Store-size consequence

Measured from the actual files for the same 210 donors and 12,467 token units.
This compares different tensor representations explicitly: frame-level float32
decoder features versus one 512-channel int16 t_en column per token. It excludes
metadata, shared t_en scales and F0/N/durations on both sides. It is a
selected-donor sample, not a whole-bank extrapolation.

| Native component | Measured bytes | Bytes per token unit |
|---|---:|---:|
| Decoder features | 131579904 | 10554.255554664 |
| t_en int16 columns | 12766208 | 1024.000000000 |
| Exported double moments plus donor Live level pairs | 1923253024 | 154267.508141494 |

The moment files are uncompressed offline exports, not a proposed compact phone
format. B/C do not require the moment exports at generation time; D/E use them
for this experiment's level controls.

## Integration corrections and preservation

The first selector attempt encountered an out-of-range index after indexing.
The parent experiment had enabled StrictMode Latest; the unchanged selector's
Get-TargetCost indexes a third context character beyond terminal padding.
A direct terminal-index probe returned null under non-strict indexing and threw
under StrictMode Latest. Scoping mine.ps1 to its original non-strict execution
completed the full selection. The initial attempt did not retain a stack trace,
so the exact first faulting statement in that attempt is unverified. Selector
source and algorithm are unchanged.

The next attempt saved the nine selections, then the voice reader rejected a
missing pinned-hash argument. C:\Dev\Kokoro-Hexagon-v15-front-end\src\runspace\Torch.Checkpoint.psm1,
ReadTensor line 245, says "A pinned SHA-256 is required." The caller now supplies
the already verified af_heart hash. This admission was retained, not bypassed.

After all donors were saved, the requested MeasureAudio single-file invocation
failed at tools\Kokoro.AudioMeasurement.psm1 line 288, "$files.Count -eq 0".
The tool's preceding line supports a folder. The completed 63-file folder was
measured from that worktree through its existing entrypoint. No tool source
was copied, rewritten or changed.

Saved selection and donor objects were reused through the offline tool's typed
SelectedUnits and DonorRecords inputs. Reloading validates donor chunk hashes,
durations, frame counts and native lengths. The existing first WAV reproduced
bit for bit and was preserved. Completed results and compiled artifacts have
overwrite guards; other diagnostics default to fresh timestamped output folders.

## Artifact identities and quoted source scope

Final source SHA-256: 8DAD8231FDCBF80C024E2C9C0A4D53FC7CE0E02D3415ABBE2FE73A1AB8E07257

Part 2 render-host source SHA-256: BE1404CD99229D891B6CC0AAA2FF56A51A62CB207338C9895ABBCA0D7557F175.

Donor-stage source SHA-256: 16AAF5C75CF8B3BF82E586E08B5CC0229BF80709E52647724D1981525F156701.

Both emit the same numeric assembly 446FD867E60D8D21F267D9B372A6736D357E84DEF7B680609E8386CBE22D1F8D; final host changes are help/input/preservation guards.

C:\Dev\Kokoro-Hexagon\build\score-capture-20261014\capture.psd1 SHA-256: 5E6C05B6BB2D1B06C94E112FD8A36203A134705DDF97CE2639AEA8B8685DF9EB

C:\Dev\Kokoro-Hexagon\build\node-capture-20261014\nodes.psd1 SHA-256: D0883796849DFDA15B15D3B904E078DBE35417E0D0AD5412B805D28760E8274C

C:\Dev\Kokoro-Hexagon-v15-front-end\build\precomputed-decoder-20261014\selection.clixml SHA-256: 97999C0AC1FAC30432D0AAE156672A30DCE7AA47DEC395F18CC8F256056700EB

Checkpoint SHA-256: 496DBA118D1A58F5F3DB2EFC88DBDC216E0483FC89FE6E47EE1F2C53F18AD1E4.
Voice SHA-256: 0AB5709B8FFAB19BFD849CD11D98F75B60AF7733253AD0D67B12382A102CB4FF.
Their paths remain those in the preserved capture-spec.json; the existing
Torch.Checkpoint reader reads them without Python. Numerical identities come
from observed files and gates. General hardware/SDK behavior beyond the quoted
sources and these observed executions is unverified.

## Exact commands

Commands run from C:\Dev\Kokoro-Hexagon-v15-front-end. The first Join command
generated the full selection and donor records across the integration
corrections described above. The successful render continuation was:

```powershell
& C:/Dev/Pwsh-Development/tools/board.ps1 Claim -Agent Codex -Task 'Offline decoder/generator + precomputed-decoder join test' -Location C:/Dev/Kokoro-Hexagon-v15-front-end -Branch v15-front-end
& ./Invoke-KokoroDevelopment.ps1 PrecomputedDecoder -Parameters @{Mode='Join'; OutputDirectory='C:\Dev\Kokoro-Hexagon-v15-front-end\build\precomputed-decoder-20261014'}
$recordedSelection = Import-Clixml build/precomputed-decoder-20261014/selection.clixml
$recordedDonors = @(Import-Clixml build/precomputed-decoder-20261014/donors.clixml)
& ./Invoke-KokoroDevelopment.ps1 PrecomputedDecoder -Parameters @{Mode='Join'; SelectedUnits=$recordedSelection; DonorRecords=$recordedDonors; OutputDirectory='C:\Dev\Kokoro-Hexagon-v15-front-end\build\precomputed-decoder-20261014'}
& ./Invoke-KokoroDevelopment.ps1 PrecomputedDecoder -Parameters @{Mode='Gate'; Runs=1; OutputDirectory='C:\Dev\Kokoro-Hexagon-v15-front-end\build\precomputed-decoder-reopen-20261014\final-artifact-gate'}
& ./Invoke-KokoroDevelopment.ps1 PrecomputedDecoder -Parameters @{Mode='Levels'; OutputDirectory='C:\Dev\Kokoro-Hexagon-v15-front-end\build\precomputed-decoder-reopen-20261014\final-artifact-levels'}
& ./tools/Invoke-KokoroPrecomputedDecoder.ps1 -h
# The experiment itself executed this meter command from its owning worktree:
Push-Location C:/Users/Scott/.codex/worktrees/measure-audio/Kokoro-Hexagon
try { & ./Invoke-KokoroDevelopment.ps1 MeasureAudio -Path C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-20261014 }
finally { Pop-Location }
# Before each local gated-part commit:
& ./Invoke-KokoroDevelopment.ps1 Verify
# Part 1 commit was created with only its three task paths staged.
git commit -m 'Implement offline decoder generator and reopen stock parity gate'
# Part 2 commit stages only the experiment script and this completion receipt.
git add -- tools/Invoke-KokoroPrecomputedDecoder.ps1 docs/results/precomputed-decoder-join-complete-20261014.md
& ./Invoke-KokoroDevelopment.ps1 Verify
git commit -m 'Complete offline precomputed decoder joins and level controls'
$part2Commit = git rev-parse HEAD
& C:/Dev/Pwsh-Development/tools/board.ps1 Finish -Agent Codex -Task 'Offline decoder/generator + precomputed-decoder join test' -Commits @('0a2bb140aa3c6c84b6dd6b75c059b1607b2cdc03',$part2Commit)
```

The detailed Part 1 receipt records the exact diagnostic/tenth-run commands.
Final-artifact confirmation uses one run; its timings are not substituted for
the tenth-run measurements. Board Finish and the Part 2 commit follow Verify
after receipt preparation. No push command is used.

## Files changed and scope

- C:\Dev\Kokoro-Hexagon-v15-front-end\tools\Invoke-KokoroPrecomputedDecoder.ps1: the requested single offline experiment, compiled numeric kernels, noise/level modes, donor feature storage, seven variants, measurements and help.
- C:\Dev\Kokoro-Hexagon-v15-front-end\Invoke-KokoroDevelopment.ps1: owning PrecomputedDecoder dispatch and help (Part 1 commit).
- C:\Dev\Kokoro-Hexagon-v15-front-end\docs\results\precomputed-decoder-reopen-20261014.md: immutable Part 1 gate/source-fix receipt (Part 1 commit).
- C:\Dev\Kokoro-Hexagon-v15-front-end\docs\results\precomputed-decoder-join-complete-20261014.md: final experimental results and report contract.
- C:\Dev\Pwsh-Development\BOARD.md: required generated claim/finish coordination.
- C:\Dev\Pwsh-Development\build\board\board.clixml: board command's state.
- Ignored native tensors, DLLs, WAVs and typed records under the two named build output roots: per-file paths, hashes and one-line reasons are in [the complete inventory](C:/Dev/Kokoro-Hexagon-v15-front-end/build/precomputed-decoder-reopen-20261014/task-file-inventory.tsv), generated after commit/board finish.

The unchanged reference script itself writes its existing legacy JSON files;
new experiment code neither parses nor serializes JSON. Its copied heldout
input and legacy reference outputs are identified individually in the inventory.

Protected files modified: none. Existing frozen captures, manifests, receipts,
baselines and pins are unchanged. The earlier untracked failed receipt
C:\Dev\Kokoro-Hexagon-v15-front-end\docs\results\precomputed-decoder-join-20261014.md
remains untouched and excluded from commits. All other local status entries
below are unrelated work and were preserved.

Scope beyond the prompt: none.

## Uncommitted state at receipt preparation

Verbatim git status --short output for every repository accessed. This snapshot
precedes creation/staging of this new receipt; the final delivery message
records post-commit status and both created commit SHAs.

C:\Dev\Kokoro-Hexagon-v15-front-end; branch v15-front-end

```text
 M tools/Invoke-KokoroPrecomputedDecoder.ps1
?? docs/results/precomputed-decoder-join-20261014.md
```

C:\Dev\Kokoro-Hexagon; branch main

```text
 M AGENTS.md
 M Invoke-KokoroDevelopment.ps1
 M docs/ROADMAP.md
 M docs/adain-control-stream-design.md
 M docs/end-to-end-campaign.md
 M docs/handoff-20261010.md
 M src/jobs/Kokoro.Generator60x16Run.ps1
 M src/jobs/Kokoro.HarmonicSource16Run.ps1
 M src/jobs/Kokoro.HarmonicStft16Run.ps1
 M src/kernels/Kokoro.Decoder16.ps1
 M tools/Kokoro.CaptureKernels.psm1
?? docs/expanded-student-campaign.md
?? docs/results/student-characterization-20261012.md
```

C:\Dev\Pwsh-Development; branch main

```text
 M AGENTS.md
 M BOARD.md
 M README.md
R  StudentV2/.gitignore -> StudentV2-Deprecated/.gitignore
R  StudentV2/AGENTS.md -> StudentV2-Deprecated/AGENTS.md
RM StudentV2/Invoke-StudentV2.ps1 -> StudentV2-Deprecated/Invoke-StudentV2.ps1
R  StudentV2/README.md -> StudentV2-Deprecated/README.md
R  StudentV2/docs/FOUNDATIONS.md -> StudentV2-Deprecated/docs/FOUNDATIONS.md
R  StudentV2/docs/ROADMAP.md -> StudentV2-Deprecated/docs/ROADMAP.md
R  StudentV2/reference/Baseline.psd1 -> StudentV2-Deprecated/reference/Baseline.psd1
R  StudentV2/src/StudentV2.AcousticMechanics.ps1 -> StudentV2-Deprecated/src/StudentV2.AcousticMechanics.ps1
R  StudentV2/src/StudentV2.Affine.ps1 -> StudentV2-Deprecated/src/StudentV2.Affine.ps1
R  StudentV2/src/StudentV2.Contracts.ps1 -> StudentV2-Deprecated/src/StudentV2.Contracts.ps1
R  StudentV2/src/StudentV2.psm1 -> StudentV2-Deprecated/src/StudentV2.psm1
R  StudentV2/tests/Test-StudentV2.ps1 -> StudentV2-Deprecated/tests/Test-StudentV2.ps1
 M kokoro-hexagon/experiments.tsv
 M kokoro-hexagon/ratchet-latest.json
 M provenance.csv
?? "# English Prosody Rulebook.txt"
?? "# Student V3 Spec.txt"
?? "New Text Document.txt"
?? kokoro-hexagon/archive/
?? subsystem/runspace/Host/
```

C:\Users\Scott\.codex\worktrees\measure-audio\Kokoro-Hexagon; branch measure-audio

```text
```

Empty output (clean).

C:\Dev\.vendor\pytorch; branch detached HEAD

```text
```

Empty output (clean).

Stops: no outstanding STOP condition in the reopened task. The earlier failed PCM gate is preserved in its historical receipt and was explicitly reopened. Integration failures above were resolved without new compiler machinery, reference-tool edits or tuning.
