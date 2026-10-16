STOP condition hit: none.

# Shared stroke generator: offline representation experiment

Repository/worktree: `C:\Dev\Kokoro-Hexagon`, `main`, sole checkout. Starting HEAD:
`0c6d7697ddcf53087cd0ee477326b96143e1dc9e`. Reproducible implementation milestone:
`a7d42debee5081c8516c28b5e180042f63f4ce16` (Verify passed). This report's commit
is its containing commit. Nothing pushed; last local `origin/main` is
`8a5bcdd64753281d805189868daed960754b7636`.

**Decision: this tested library and greedy program do not demonstrate a viable
replacement for the runtime decoder/unit store. Do not expand this version into
a production controller.** Sixteen distinct global strokes leave substantial
feature error and PCM error, even with oracle access to the target. This is a
negative result for the bounded experiment, not proof that every possible
global stroke library fails. Scott's listening verdict remains unverified.

| Gate | Result |
| --- | --- |
| A: representation | Not passed: feature SNR 10.93–11.64 dB at 16 strokes, with large worst-frame errors; listening artifacts preserved. |
| B: generalization | Not established. No text/context coefficient predictor was built after this weak oracle result. Saved-program replay is bit exact but uses oracle-selected coefficients. |
| C: economics | Not passed. The library and checked executor alone exceed the matched 32-sentence int16 unit payload; coefficient prediction, F0/duration rules and whole-control generation are absent. |

## Actual numerical boundary and reference gate

The pinned existing offline decoder returns `Features` after `decode.3`. The
generator consumes FP32 `[1,512,T]`, channel-major (`x[c*T+t]`), at 80 frames/s:
one frame per 300 samples at 24 kHz. This is **after the decoder**, not the old
512-value `t_en` unit bank. No meanings were assigned to latent channels.

Independent generator arguments are F0 FP32 `[T]`, acoustic style FP32 `[128]`,
initial source uniform draws `[1,9]`, harmonic Gaussian draws `[1,300*T,9]`, and
extra Gaussian draws `[1,300*T,1]`. `N` is a decoder input, not an additional
argument to this generator. The af_heart acoustic style is the first 128 values
of the selected voice row: dog row 30, peach row 31, training/nine row 25.
All external arguments, source draws and weights are identical within each pair.

The callable frozen offline generator computes live AdaIN and mathematical
Snake internally. It has **no external AdaIN/lock parameters**. Consequently
these renders test that original numerical boundary, not the unfinished
external CONST AdaIN/lock generator. Existing `Kokoro.GeneratorInput.psm1` is a
provisional different packet (including FP16 features and external controls),
not a wired consumer validated here. This experiment neither makes AdaIN/locks
resident tables nor establishes the modified streaming-control implementation.
Extending that consumer or modifying its frozen weights would be separate work.

Alignment uses the existing int32 token durations at 40 Hz, expanded to two
80 Hz decoder-output frames per duration tick. BOS/EOS and other tokens remain
in the alignment. For error diagnostics, a boundary mask includes the frame
immediately before and after a token transition. These are token boundaries,
including stress/space/punctuation, not asserted linguistic phoneme boundaries.
A unit join marks a change to a donor other than the next token of the same
source sentence. State is indexed on the uninterrupted 300-sample timeline;
there is no arbitrary generator-block reset in reconstruction.

Reference source: `tools/Invoke-KokoroPrecomputedDecoder.ps1`, SHA256
`8DAD8231FDCBF80C024E2C9C0A4D53FC7CE0E02D3415ABBE2FE73A1AB8E07257`.
Existing offline render DLL SHA256:
`446FD867E60D8D21F267D9B372A6736D357E84DEF7B680609E8386CBE22D1F8D`.
Checkpoint SHA256:
`496DBA118D1A58F5F3DB2EFC88DBDC216E0483FC89FE6E47EE1F2C53F18AD1E4`.
af_heart pack SHA256:
`0AB5709B8FFAB19BFD849CD11D98F75B60AF7733253AD0D67B12382A102CB4FF`.
PCM comparison uses the existing Student PCM16 rounding/saturation and PCM
comparison kernel, SHA256
`EE4DD6FB9A55CDEFC1B781BA07E19AC9D91307CA911B620AA7D72D90ADB3B017`.
The existing reference implementation is loaded in process, not reimplemented.

Reference reproduction precedes discovery:

| Case | Frames | Audio s | Reproduction |
| --- | ---: | ---: | --- |
| dog | 174 | 2.175 | 94.67166 dB against captured stock float PCM; peak error 0.00000720471 |
| peach | 188 | 2.350 | 95.59512 dB against captured stock float PCM; peak error 0.00000659749 |
| 01–09 | 164,234,212,240,228,230,214,248,226 | 2.050,2.925,2.650,3.000,2.850,2.875,2.675,3.100,2.825 | All nine bit exact PCM16 against the existing selected-bank reference renders |

The nine are held-out selected-unit sequences from the completed replay
experiment, **not nine untouched fresh-text stock decoder captures**. Dog/peach
are intact stock fixtures. This distinction prevents treating the nine's prior
54.41–63.49 dB replay-to-selected-reference result as an untouched-stock result.
Training consists of fixed source sentence IDs 0–31: 8,834 frames, 110.425 s,
1,656 aligned tokens. All eleven test phoneme sequences were compared ordinally
against all training sequences; none overlapped. This is a small training subset,
not a complete-bank rebuild. The eleven evaluation sequences total 2,358 frames,
29.475 s. Captured actual tensors, hashes, alignment, reference metrics and
controls are in `build/student-strokes-boundary-20261015/boundary.clixml`.
These raw tensors are offline evidence only, never the proposed runtime format.

## One global library and deterministic oracle

One BASE is the first real frame of training sentence 0. Candidates are observed
state minus that BASE and observed adjacent-frame differences within each
training sentence. Discovery selects the highest remaining candidate energy
after its best single selected-direction projection. Exact ties choose the
lowest candidate index. Squared absolute cosine >= 0.9999 deduplicates both
near-parallel and near-opposite candidates, since signed coefficients are allowed.
There is no average, centroid, PCA, neural training or fitted projection matrix.
The library has 1,024 FP32 vectors, shared across all test sentences and budgets.

For each oracle frame, score each unused direction by `(residual dot stroke)^2 /
stroke norm`. Choose the best, with ascending stroke-ID ties, and accept only an
actual FP64 squared-error reduction after FP32 replay. After adding a direction,
perform at most eight ordered sweeps of greedy **one-scalar** coefficient
refinements over the active directions (ascending IDs), accepting strict error
reduction. Recomposition always uses BASE and the selected-order FP32 products
and additions. There is no joint linear solve. Record snapshots at 4, 8 and 16
**distinct active directions**. This is the best found by this declared greedy
procedure, not an exhaustive proof of the mathematical sparse optimum.

All final frames use their full distinct budget. The initial draft instead
counted repeated applications; 2,145 of 2,358 frames repeated IDs at budget 16.
That underused the requested active budget. Its partial renders were stopped,
retained separately, and replaced by the corrected `ceiling-20261015-r3` results
and `oracle-render-*-20261015-r2` WAVs. Do not use the earlier draft as final evidence.

## Feature reconstruction and reuse

SNR is `10 log10(sum X^2 / sum (X-Y)^2)` across all channels/frames of a case.
Normalized frame error is `sqrt(sum error^2 / sum X^2)` across its 512 channels.
Quantiles use the lower observed rank. Worst errors are retained rather than
hidden behind the aggregate.

| Budget | Per-case feature SNR dB | Frame-error p10 range | Median range | p90 range | Worst frame error |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 4 | 8.51–9.14 | .18956–.26024 | .37858–.43069 | .50921–.56887 | .76780 |
| 8 | 9.62–10.29 | .16425–.21635 | .33173–.38118 | .45524–.49187 | .65131 |
| 16 | 10.93–11.64 | .13750–.18373 | .29008–.32556 | .39744–.42492 | .55392 |

Per-case p10/median/p90/worst normalized and squared errors, frame SNRs, peaks,
actual stroke counts and masks are preserved in
`build/student-strokes-ceiling-20261015-r3/ceiling.clixml` and `frames.clixml`.
`channels.clixml` contains all 512 channels for all 33 configurations, with
signal/error energy, peak error, absolute-error p10/median/p90 and channel SNR.
Across these case/channel rows, channel SNR distributions are:

| Budget | Minimum | p10 | Median | p90 | Maximum |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 4 | 1.353 | 4.880 | 7.870 | 11.230 | 20.602 |
| 8 | 2.300 | 5.855 | 8.931 | 12.569 | 22.283 |
| 16 | 3.193 | 6.999 | 10.203 | 14.054 | 23.685 |

At 16 strokes, token-boundary frames contain 37.48–47.10% of error energy but
29.50–35.47% of reference signal energy. For nine selected-unit cases, join
frames contain 18.11–30.21% of error energy versus 14.38–24.68% of signal energy.
Dog/peach have no selected-unit joins. The error concentration therefore does
not consist solely of joins; it is also present in intact fixtures.

| Case, 16 strokes | Boundary frames | Boundary error/signal share | Join frames | Join error/signal share |
| --- | ---: | ---: | ---: | ---: |
| dog | 64/174 | .4482/.3485 | 0 | 0/0 |
| peach | 66/188 | .3967/.3139 | 0 | 0/0 |
| 01 | 54/164 | .3777/.3095 | 32 | .2251/.1941 |
| 02 | 90/234 | .4549/.3386 | 46 | .2209/.1815 |
| 03 | 82/212 | .4319/.3234 | 38 | .1994/.1641 |
| 04 | 90/240 | .4075/.3160 | 50 | .2258/.1873 |
| 05 | 84/228 | .4227/.3056 | 38 | .1811/.1571 |
| 06 | 86/230 | .4106/.2950 | 40 | .1834/.1438 |
| 07 | 90/214 | .4710/.3547 | 48 | .2537/.2029 |
| 08 | 84/248 | .3748/.3036 | 52 | .2324/.1940 |
| 09 | 90/226 | .4562/.3359 | 62 | .3021/.2468 |

| Budget | Dictionary rows used /1024 | Reused across sentences | Used in all 11 | Applications |
| ---: | ---: | ---: | ---: | ---: |
| 4 | 990 | 891 | 44 | 9,432 |
| 8 | 1,007 | 960 | 188 | 18,864 |
| 16 | 1,020 | 994 | 328 | 37,728 |

Reuse is real; a small disjoint sentence/phoneme dictionary was not substituted.
Nearly the entire global library is needed, yet reconstruction remains weak.
Per-stroke counts and distinct-sentence coverage are in `utilization.clixml`.

## PCM, listening artifacts and matching conditions

All pairs are mono 24 kHz PCM16: **reference first, 0.6 seconds silence, oracle
second**, no gain normalization or resampling. Durations, F0, acoustic style,
source draws, generator code and weights are matched within each pair. Only
the 512-channel input changes. Every output is checked for finite values;
clipping and peak/error metrics are retained. PCM16 SNR does not substitute for
Scott's ear, and no listening acceptance is claimed.

Final listening metrics and the complete path table follow in the final section.
All33 pairs passed integer-byte extent checks, 24kHz mono PCM16 headers,
reference/candidate segment identity, silent-gap verification and recorded
SHA256 checks. All33 candidate renders have zero clipped samples. An initial
audit used a floating-point duration equality; its roundoff-sensitive check was
replaced by exact integer PCM-byte extents. No WAV was changed for that audit.

## Typed binary layout and full byte bill

Library: `build/student-strokes-library-20261015-r2/stroke-library.bin`, SHA256
`7FA5692EF6275BC239F8A882687C033849CB12EB123D7B3C1DE611C249BB1A87`.
Little-endian native layout:

| Region | Offset | Bytes | Type/content |
| --- | ---: | ---: | --- |
| Header | 0 | 64 | ASCII `KHSTROK1`, then 14 u32: version1, channels512, strokes1024, bases1, precision1(F32), provenance-row12, baseOffset64, strokeOffset2112, provenanceOffset2099264, trainingFrames8834, four reserved zeros |
| BASE | 64 | 2,048 | 512 F32, one selected real state |
| Strokes | 2,112 | 2,097,152 | 1024×512 F32, stroke-major |
| Provenance | 2,099,264 | 12,288 | 1024×(u32 sourceSentence, u32 sourceFrame, u32 kind); kind0 state−BASE, kind1 adjacent difference |
| Total native library | | 2,111,552 | No quantization scales; F32 values are direct |
| Discovery description CLIXML | | 24,051 | Source-frame hashes, training identity, discovery rules and layout |
| Original discovery DLL | | 7,168 | Preserved with the discovery artifact |
| Checked replay DLL | | 10,752 | Actual executor SHA256 `ACFB9D2E6072BD1B46135465CD79D94DE40FF77259A7C65247583B835C832A52` |

The library directory totals **2,142,771 bytes**, including its original DLL.
Replacing that DLL by the checked executor gives **2,146,355 bytes**; retaining
both gives **2,153,523 bytes**. This bill includes provenance/description even
though they could be omitted from a future appliance. No future stripping or
coefficient quantization saving is assumed. Coefficients are F32 and IDs are
int32 in this experiment. Oracle diagnostics additionally occupy **631,944
bytes** (IDs, three coefficient snapshots, and used counts). They are per-frame
oracle recordings, explicitly excluded from any deployable compression claim.
There is no residual fallback, hidden per-phoneme dictionary or runtime raw
feature-track store.

For matched coverage of source sentences 0–31 (1,656 tokens, 110.425 s):

| Component | Bytes | Bytes/audio-s | Bytes/aligned token | Qualification |
| --- | ---: | ---: | ---: | --- |
| Existing int16 `t_en` payload | 1,695,744 | 15,356.52 | 1,024 | Before decoder; excludes common alignment/control support |
| Existing 46 dB opcode native components | 4,782,809 | 43,312.74 | 2,888.17 | Same first 1,656 tokens; reachable exemplars/directions, program prefix, offsets and voice key; before decoder |
| Existing 70 dB opcode native components | 6,577,265 | 59,563.19 | 3,971.78 | Same prefix and accounting; before decoder |
| Hypothetical int16 postdecoder frames | 9,046,016 | 81,920 | 5,462.57 | 8,834×512×2; different interface, no quality claim for this hypothetical quantization |
| Shared library + description + checked executor | 2,146,355 | 19,437.22 | 1,296.11 | Incomplete generative system; no coefficient-generation, duration or F0 program |

The prior stores were only inspected: 46 dB prefix program3,070,737,
offsets13,256, reachable1,655 exemplar rows×1,024, one direction×2,048 and
voice key2,048. At 70 dB, prefix program4,865,193; other counts identical.
These native component comparisons exclude old/new textual executable source
and common infrastructure; neither is a full deployable package comparison.
The complete previous experiment covers 2,429,833 units/43,679 sentences:
2,488,148,992 int16 bytes, 6,432,642,550 total bytes at46 dB and 9,042,325,042
at70 dB. **That full corpus is unmatched to this 32-sentence library discovery.**
No extrapolated compression ratio is claimed. The old stores also reconstruct
`t_en`, not this postdecoder target, so their SNRs are not comparable quality bars.

Generated feature transport, if materialized, is 512×4×80 = **163,840 bytes/s**;
F0 adds320 bytes/s, style512 bytes per selected voice row. These transient
streams are not permanent stored programs. Exact source-draw arrays are fixed
reference-test inputs, not proposed stored speech tracks. This experiment has
no deployable generator for their replacement, F0/duration rules, or external
AdaIN/lock events, so no complete coordinated Student storage total can be
claimed. Token durations for the 32 examples occupy6,624 bytes and captured
training F0 occupies35,336 bytes, exclusively offline evidence.

Checked scalar replay needs one 2,048-byte generated frame, shared2,048-byte
BASE, shared2,097,152-byte dictionary, and at most128 bytes of active i32 IDs/F32
coefficients per frame, plus managed array/header/validation overhead. The
current batch evaluator allocates4,829,184 bytes for one2358-frame output; it
is not a measured allocation-free streaming appliance. Greedy search uses
current/residual/candidate512-vectors (6,144 payload bytes per worker), norm
table8,192 and additional worker arrays plus full input/snapshot buffers.
Those are transient experiment allocations, not proof of DSP VTCM residency.
Complete process memory and object overhead were not profiled.

## Numerical work, execution timing and historical comparison

Replay arithmetic per frame is512 BASE assignments plus512U scalar F32
multiplies and512U adds, where U is active strokes: 2,048/4,096/8,192 of each
at budgets4/8/16. Validation, ID/index loads and finite checks are additional.
No neural decoder executes in this replay primitive. It accepts supplied IDs
and coefficients; it is **not** a text-to-coefficient Student policy.

The oracle batch performs38,350,512 search dots,2,533,890 refinement dots,
37,728 accepted additions and2,342,000 accepted coefficient refinements.
Each dot has512 FP64 multiplies/accumulations; scores add square/divide and
comparisons. Thus dots alone total20,932,813,824 multiplies and the same number
of accumulation adds (8,877,359.55 each per frame). Residual updates, candidate
recompositions, SSE reductions and rejected refinements add work; their exact
operation totals were not instrumented. Search was30,622.5807 ms for29.475 s
audio, **1,038.934 ms/audio-s**, an offline oracle cost, not runtime inference.
Discovery was19,354.3988 ms for110.425 s training audio, **175.272 ms/audio-s**,
a one-time batch cost, not synthesis throughput.

Truth-free replay of all33 saved oracle programs is bit exact to the measured
tensors (`replay-check.clixml`). Five warm Windows scalar compiled replay batches,
allocation/validation included and IO excluded, give medians:

| Budget | Replay ms/audio-s | Scope |
| ---: | ---: | --- |
| 4 | 2.51 | Supplied oracle instructions only |
| 8 | 6.30 | Supplied oracle instructions only |
| 16 | 12.09 | Supplied oracle instructions only |

This timing excludes coefficient prediction and generator synthesis. The host
CPU model is unverified; no phone was used. The kernel is PowerShell-authored,
compiled in process through pinned PSLowering
`1afabe056235a570da29e268824784557d4f6cdd`, CLR-only admission. It uses scalar
FP64 dots/F32 replay; no SIMD, SDK/API speed or hardware residency claim is made.
An initial SIMD investigation failed admission/runtime validation and was
replaced; it is not used in the reported numbers.

Scott's historical approximate85 ms for2.125 s means **40 ms/audio-s**, about25x.
The protected receipt `peach-combined-constants-sm8550-20261012.md` says
"DSP region, median of five warm runs"99.593 ms: **46.867 ms/audio-s**, and
records `ResidentHvxThreads=4`. Its scope is combined decoder/source/generator,
captured constants fixture, SM8550 integer DSP. Current timings are Windows
FP32 offline generator/source on different2.175/2.350 s fixtures, with three
concurrent four-thread render jobs, no DSP/dispatch and no warm-median protocol.
They establish no speedup or regression versus that receipt. Bundling and
four-thread HVX restoration are outside this offline task; none was changed.

## Reproduction

Use fresh output folders; the stage guards prevent overwriting evidence.
All commands run through `Invoke-KokoroDevelopment.ps1 Student`:

```powershell
./Invoke-KokoroDevelopment.ps1 Student -Parameters @{Step='StrokeBoundary';TrainingSentences=32} -OutputDirectory build/strokes-boundary-reproduction
./Invoke-KokoroDevelopment.ps1 Student -Parameters @{Step='Strokes';Stage='Library';ExperimentDirectory='build/strokes-boundary-reproduction';LibrarySize=1024} -OutputDirectory build/strokes-library-reproduction
./Invoke-KokoroDevelopment.ps1 Student -Parameters @{Step='Strokes';Stage='Ceiling';ExperimentDirectory='build/strokes-boundary-reproduction';LibraryDirectory='build/strokes-library-reproduction';Threads=8} -OutputDirectory build/strokes-ceiling-reproduction
./Invoke-KokoroDevelopment.ps1 Student -Parameters @{Step='Strokes';Stage='ReplayCheck';ExperimentDirectory='build/strokes-boundary-reproduction';LibraryDirectory='build/strokes-library-reproduction';ReconstructionDirectory='build/strokes-ceiling-reproduction'} -OutputDirectory build/strokes-replay-reproduction
./Invoke-KokoroDevelopment.ps1 Student -Parameters @{Step='Strokes';Stage='Render';ExperimentDirectory='build/strokes-boundary-reproduction';ReconstructionDirectory='build/strokes-ceiling-reproduction';Threads=4} -OutputDirectory build/strokes-render-reproduction
```

Requires the existing pinned checkpoint, voice, bank, selection/captured-reference
artifacts and compiler; source and input hashes are checked. Render invokes the
existing `MeasureAudio` command and saves its output. No new JSON, Python,
standalone harness, bank rebuild or old compression campaign is involved.
The minimal Student integration is experiment dispatch plus BASE/STROKE
execution with no reference-vector argument. There is no claim of learned
coefficient generalization, new RAMP/ACCENT subsystem or unified external
conditioning player. Their conditional quality prerequisite was not established.

## Changed paths, protection and repository state

Changed for this experiment:

- `Invoke-KokoroDevelopment.ps1`: expose offline experiment commands in existing help.
- `tools/Kokoro.Student.psm1`: capture the actual boundary using the existing reference, preserve alignment/controls, dispatch stroke stages.
- `tools/Kokoro.StudentStrokes.psm1`: bounded library discovery, distinct-budget oracle, replay validation and existing-generator listening comparisons.
- `docs/results/student-shared-strokes-20261015.md`: this experimental evidence and decision.
- `C:\Dev\Pwsh-Development\BOARD.md` and ignored `build/board/board.clixml`: task coordination through the existing board command only.
- Ignored `build/student-strokes-*`: typed library, admission artifacts, captured experiment inputs, diagnostic programs/metrics, WAVs and logs; no proposed raw runtime store.

Protected files touched: **none**. Captures, frozen bank, model/voice weights,
manifests and earlier measurement receipts remain read-only. No phone access,
push, history rewrite, branch deletion, worktree creation or unrelated profiling
change. Unrequested scope: **none**. Unrelated pre-existing modifications were
preserved; shared repository WIP was neither committed nor cleaned.

## Final audio measurements

Reference compared with itself is exact (zero peak error; finite SNR is undefined).
Its independent stock/previous-reference reproduction is reported above. Every
row below is **oracle-generated**, never Student-predicted. Host timings are
single generator/source runs in ms per second of audio under the unequal
concurrent load described above; they are not matched benchmark speed comparisons.

| Case | Active strokes | Feature SNR dB | PCM16 SNR dB | PCM16 peak absolute error | Host generator ms/audio-s |
| --- | ---: | ---: | ---: | ---: | ---: |
| dog | 4 | 8.610 | 2.574 | .43365 | 44285.17 |
| dog | 8 | 9.686 | 3.012 | .44754 | 39708.91 |
| dog | 16 | 10.962 | 3.650 | .43069 | 41105.43 |
| peach | 4 | 8.594 | 2.569 | .54895 | 43991.15 |
| peach | 8 | 9.677 | 3.068 | .41058 | 39586.13 |
| peach | 16 | 11.003 | 3.625 | .36438 | 41979.38 |
| 01 | 4 | 8.506 | 4.852 | .29147 | 41086.28 |
| 01 | 8 | 9.624 | 4.915 | .28461 | 39977.39 |
| 01 | 16 | 10.925 | 5.550 | .27835 | 41876.92 |
| 02 | 4 | 8.973 | 1.955 | .60669 | 39728.50 |
| 02 | 8 | 10.128 | 3.279 | .51413 | 40007.06 |
| 02 | 16 | 11.476 | 5.799 | .47522 | 39509.83 |
| 03 | 4 | 8.640 | 2.569 | .36682 | 43964.26 |
| 03 | 8 | 9.776 | 4.160 | .45139 | 40127.29 |
| 03 | 16 | 11.113 | 4.541 | .44308 | 42263.37 |
| 04 | 4 | 9.138 | 2.420 | .39401 | 39554.28 |
| 04 | 8 | 10.287 | 3.659 | .32474 | 44350.07 |
| 04 | 16 | 11.640 | 4.675 | .32474 | 42708.38 |
| 05 | 4 | 8.700 | 3.097 | .37302 | 43804.92 |
| 05 | 8 | 9.818 | 3.985 | .40048 | 42813.68 |
| 05 | 16 | 11.142 | 4.518 | .40125 | 42815.63 |
| 06 | 4 | 8.819 | 3.614 | .26749 | 40337.62 |
| 06 | 8 | 9.993 | 4.916 | .25525 | 41190.74 |
| 06 | 16 | 11.413 | 6.474 | .29889 | 39989.55 |
| 07 | 4 | 8.579 | 1.188 | .59879 | 42855.65 |
| 07 | 8 | 9.737 | 1.688 | .61050 | 37522.82 |
| 07 | 16 | 11.089 | 2.123 | .61115 | 28360.60 |
| 08 | 4 | 8.706 | 1.025 | .46939 | 37667.51 |
| 08 | 8 | 9.786 | 1.677 | .46683 | 25080.63 |
| 08 | 16 | 11.104 | 2.037 | .52917 | 15017.22 |
| 09 | 4 | 9.099 | 2.418 | .28442 | 46109.54 |
| 09 | 8 | 10.280 | 3.239 | .30032 | 42015.00 |
| 09 | 16 | 11.600 | 4.173 | .27881 | 44629.25 |

Existing `MeasureAudio` results (integrated LUFS and true peak dBTP):

| Case | Ref LUFS | 4 LUFS | 8 LUFS | 16 LUFS | Ref dBTP | 4 dBTP | 8 dBTP | 16 dBTP |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dog | -25.47 | -25.98 | -25.89 | -25.75 | -10.23 | -10.85 | -11.30 | -11.39 |
| peach | -26.04 | -26.44 | -26.38 | -26.26 | -9.15 | -8.81 | -9.65 | -9.68 |
| 01 | -25.62 | -25.93 | -25.80 | -25.72 | -10.92 | -10.84 | -10.24 | -10.14 |
| 02 | -25.80 | -26.23 | -26.09 | -25.95 | -6.05 | -7.68 | -7.44 | -7.13 |
| 03 | -26.05 | -26.75 | -26.55 | -26.28 | -10.66 | -10.52 | -10.83 | -9.07 |
| 04 | -26.30 | -27.08 | -26.91 | -26.73 | -10.44 | -10.96 | -11.16 | -11.56 |
| 05 | -26.70 | -27.45 | -27.09 | -27.12 | -11.03 | -11.08 | -10.90 | -11.17 |
| 06 | -26.79 | -27.48 | -27.33 | -27.18 | -10.94 | -11.88 | -11.54 | -11.45 |
| 07 | -26.02 | -26.73 | -26.56 | -26.40 | -9.33 | -9.71 | -9.98 | -9.55 |
| 08 | -26.02 | -26.72 | -26.63 | -26.30 | -6.18 | -9.36 | -9.03 | -9.58 |
| 09 | -26.87 | -27.54 | -27.41 | -27.19 | -10.41 | -10.54 | -10.53 | -10.95 |

Full RMS, momentary/short-term loudness and unrounded measurements are in each
render folder's `measure-audio.clixml`. Float PCM SNR/peak and WAV SHA256 are in
its `render.clixml`. Loudness remaining close does not establish articulation
or spectral fidelity.

The boundary reference runs' decoder/generator times, normalized to ms/audio-s,
are retained for completeness, not compared as speedups with concurrently
loaded candidate runs:

| Case | Decoder ms/audio-s | Generator ms/audio-s |
| --- | ---: | ---: |
| dog | 766.815 | 10386.164 |
| peach | 656.845 | 11191.310 |
| 01 | 700.174 | 17602.745 |
| 02 | 931.866 | 17892.146 |
| 03 | 703.662 | 15529.412 |
| 04 | 668.585 | 15805.767 |
| 05 | 715.490 | 15743.595 |
| 06 | 687.229 | 16786.261 |
| 07 | 974.855 | 16499.469 |
| 08 | 680.635 | 16522.573 |
| 09 | 700.636 | 16711.242 |

## Listening paths and evidence inventory

All33 pair paths are specified by the following exact folder/case matrix and
the three filenames `<case>-reference-then-oracle-4.wav`,
`<case>-reference-then-oracle-8.wav`, `<case>-reference-then-oracle-16.wav`.
Individual reference/candidate WAVs are alongside each pair. Absolute root is
`C:\Dev\Kokoro-Hexagon\build\`.

| Exact folder under that root | Cases |
| --- | --- |
| `student-strokes-oracle-render-a-20261015-r2` | dog, 01, 04, 07 |
| `student-strokes-oracle-render-b-20261015-r2` | peach, 02, 05, 08 |
| `student-strokes-oracle-render-c-20261015-r2` | 03, 06, 09 |

Convenient 16-stroke listening links, always reference then oracle:

- [dog](C:/Dev/Kokoro-Hexagon/build/student-strokes-oracle-render-a-20261015-r2/dog-reference-then-oracle-16.wav)
- [peach](C:/Dev/Kokoro-Hexagon/build/student-strokes-oracle-render-b-20261015-r2/peach-reference-then-oracle-16.wav)
- [01](C:/Dev/Kokoro-Hexagon/build/student-strokes-oracle-render-a-20261015-r2/01-reference-then-oracle-16.wav)
- [02](C:/Dev/Kokoro-Hexagon/build/student-strokes-oracle-render-b-20261015-r2/02-reference-then-oracle-16.wav)
- [03](C:/Dev/Kokoro-Hexagon/build/student-strokes-oracle-render-c-20261015-r2/03-reference-then-oracle-16.wav)
- [04](C:/Dev/Kokoro-Hexagon/build/student-strokes-oracle-render-a-20261015-r2/04-reference-then-oracle-16.wav)
- [05](C:/Dev/Kokoro-Hexagon/build/student-strokes-oracle-render-b-20261015-r2/05-reference-then-oracle-16.wav)
- [06](C:/Dev/Kokoro-Hexagon/build/student-strokes-oracle-render-c-20261015-r2/06-reference-then-oracle-16.wav)
- [07](C:/Dev/Kokoro-Hexagon/build/student-strokes-oracle-render-a-20261015-r2/07-reference-then-oracle-16.wav)
- [08](C:/Dev/Kokoro-Hexagon/build/student-strokes-oracle-render-b-20261015-r2/08-reference-then-oracle-16.wav)
- [09](C:/Dev/Kokoro-Hexagon/build/student-strokes-oracle-render-c-20261015-r2/09-reference-then-oracle-16.wav)

Actual final evidence-directory totals (all files, including duplicated kernels,
CLIXML and reference/candidate/pair WAVs; separate from proposed model cost):

| Directory `build/student-strokes-...` | Files | Bytes |
| --- | ---: | ---: |
| boundary-20261015 | 228 | 55,681,093 |
| library-20261015-r2 | 3 | 2,142,771 |
| ceiling-20261015-r3 | 42 | 28,512,464 |
| replay-check-20261015 | 3 | 14,881 |
| final-replay-check-20261015 | 2 | 12,149 |
| oracle-render-a-20261015-r2 | 31 | 5,147,968 |
| oracle-render-b-20261015-r2 | 31 | 5,784,000 |
| oracle-render-c-20261015-r2 | 24 | 4,307,463 |

Earlier failed/draft admission and render artifacts/logs are retained outside
these final-directory totals. Source sizes at implementation milestone:
entrypoint221,079 bytes; existing Student module133,258; new experiment
module41,165. They are host experiment infrastructure, not hidden deployed
coefficient-prediction programs. Existing checkpoint, bank, source compiler and
reference DLL are read-only prerequisites, not part of the proposed runtime
stroke library. No complete deployable package exists to measure.

## Validation and status receipt

Verify passed before implementation commit (`student-strokes-source-final-verify-20261015.log`).
The subsequent tracked-file audit failed because the new module assigned locals
named `$error`, which collide with PowerShell's automatic `$Error`. Those
locals were renamed to `$squaredError`; the first precommit audit had excluded
the then-untracked module. This was a source-policy failure with a found cause,
not a numerical failure or a reason to abandon the experiment. Final replay
validation after the rename passes all33 comparisons and produces the identical
compiled DLL SHA256. The failed audit log is retained.
Admission fixtures cover signed/fractional composition, opposite-direction
deduplication, ordering, distinct-budget coefficient refinement and exact saved
program replay. Final source/report Verify and whitespace check run before the
report commit. All11 reference reproductions, all33 oracle tensors' bit-exact
program replay and all33 WAV-pair checks passed. No NaN/Inf occurred.

Kokoro status after committing this report (unrelated work preserved):

```text
 M README.md
 M src/jobs/Kokoro.GeneratorMainRun.ps1
 M src/jobs/Kokoro.GeneratorTemplate1Run.ps1
 M tools/Emit-HexagonProbe.ps1
 M tools/Test-HexagonEmission.ps1
```

Shared repository `C:\Dev\Pwsh-Development`, main, HEAD
`aac85159ec3130a7a48e88f53a534047069d8d8b`; no commit/push in this experiment.
Only board coordination belongs to this task. Verbatim status (other entries
pre-existing and preserved):

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
?? Kokoro_Generator_Register_Datapath.md
?? Kokoro_Hexagon_Unified_Sub20ms_Architecture.md
?? "New Text Document.txt"
?? kokoro-hexagon/MANIFESTO.md
?? kokoro-hexagon/PROJECT.md
?? kokoro-hexagon/archive/scripts/
?? kokoro-hexagon/prompts/
?? subsystem/runspace/Host/
```

Established: the actual512-channel boundary reproduces existing references;
one globally shared selected-direction library executes deterministic signed
fractional programs; the declared oracle budgets have measured feature/audio
errors and a complete partial byte bill. Failed: this bounded representation
has not preserved numerical/audio fidelity or demonstrated storage economy
against the matched original unit payload. Unverified: Scott's listening
assessment, a stronger library/search, reference-free Student coefficient
generalization, coordinated external control generation, a complete executable
program's total cost, streaming block execution, and device speed/residency.
The oracle-to-Student gap cannot be measured without a Student policy; it is
not zero. No production replacement is justified by these results.
