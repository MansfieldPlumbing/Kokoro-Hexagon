# Generator16 PMU interval attribution, SM8550, 2026-10-12

Base commit: `f6e5489`; the PMU instrumentation is committed with this receipt. Target: SM8550 through `dev.mansfieldplumbing.kokoro`. Only P1 and P3 were rerun. No optimization, model, quantization or runtime-frame changes are included.

Command: `Invoke-KokoroDevelopment.ps1 Run -Case generator-pmu -OutputDirectory build/generator-pmu-unmarked-20261012-162931`. Both profiles use `ResBlockFrames=10201`, `ResidentHvxThreads=4`, and `ResidentBatchTiles=14`. P1 is `KokoroDecoderGenerator16Run` with statistics. P3 is `KokoroGeneratorWholeSource16Run` with `GeneratorMoments=Constants`, using variant G's packed input from `build/generator-constants-full-corpus-20261012-143702-run.clixml`.

Evidence: `build/generator-pmu-unmarked-20261012-162931/profile.clixml` and its four profile/event-set CLIXML files. Three executions per event set; DSP totals below are medians. Category, stage and site counters are from the final execution's output, not medians of three counter records. Category and stage ticks agree exactly for every output. The host command, including six emissions, completed in approximately 386 seconds; this is not DSP execution time.

## Byte and PCM gates

Profiling-off libraries match the accepted bytes:

| Profile | Library SHA256 |
|---|---|
| P1 | `FEFF54DF8340F184FA909C35CFEE48D3F0010F8B37E7C7F0967759403F9672A5` |
| P3 | `DE2178331D4CB7FC83EA272FFC15A603F614ED8FCC97FCBF1E15D57FAC7C4CD2` |

Profiled artifacts and median DSP times:

| Profile | Counter set | DSP ms | Library SHA256 |
|---|---|---:|---|
| P1 | A | 150.239 | `F5FBB5F023C776911C25C9EB31E49ACA23DFB2316EE181E819ECE75DB2E046E2` |
| P1 | B | 149.363 | `45D1921C9FC1A6BCB45AB650328B3F1AC38D5BB014768B6172D3F1A4271D9B0F` |
| P3 | A | 124.365 | `E100BB6E15BC5D02E70A2719CD5D5051AB57D6BF8FC971737B9602EFE0771BE5` |
| P3 | B | 123.475 | `A163C0689433BEA13B7676021657D2C35A261560234D9A7316D4DAA9BAD63FCF` |

All four profiled PCM outputs match their corresponding reference exactly. P1 PCM SHA256 is `E6456751BDBCCE0D5CB38DA8226B4EEC8B1C514E16626755C5BD975699374054`; P3 is `452A5A96CB9A15C6A75ADF191F99743EFBBD9035B382E7A033057D01C3B79449`. No listening labels were assigned.

## Measurement boundaries

The PMU mark charges the interval since the previous mark to the current mark. `Unmarked` is appended after all existing categories. Each of the 51 helper call sites has an indexed mark immediately before `$fill`, `$padRows` or `$sync`; site 0 is inside `$sync`, immediately before its `syncht`. There are no `syncht` instructions inside `$fill` or `$padRows`.

The 52 site records occupy scratch offsets 8192 through 11519. Category records end before the existing pool at 4096. Existing regions and stacks were not moved. The PMU reader retains each site separately and sums them only for the category table. The additional marks and record handling execute only with profiling enabled.

TileFix now encloses the fill and padding helpers themselves. `$fill` emits a vector-store loop; `$padRows` emits scalar load/mask/or/store loops over invalid rows. Sync encloses `syncht`. These intervals include measurement overhead and any hardware wait experienced by those instructions; they are not overhead-subtracted instruction timings. Site 0 separately exposes the interval between the caller's Unmarked mark and the helper's pre-`syncht` mark.

## Categories

Times and HVX packets are from counter set A; permutes are from B. A is `0x003,0x111,0x100,0x101,0x105,0x128,0x129,0x103`; B is `0x12a,0x12b,0x115,0x116,0x117,0x12c,0x003,0x111`, the event selection used by the earlier generator profile. HVX packets are event `0x111`, permutes event `0x12b`. The two sets are separate executions.

| Category | P1 ms | P3 ms | P1 HVX packets | P3 HVX packets | P1 / P3 permutes |
|---|---:|---:|---:|---:|---:|
| Setup | 0.007 | 0.007 | 0 | 0 | 0 / 0 |
| Dma | 2.053 | 8.191 | 963 | 648 | 0 / 0 |
| Coefficients | 11.296 | 0.000 | 0 | 0 | 0 / 0 |
| AdaInSnake | 24.395 | 24.051 | 44,600,742 | 44,602,236 | 0 / 0 |
| HmxConv | 26.817 | 26.493 | 0 | 0 | 0 / 0 |
| Combine | 14.256 | 13.864 | 16,205,696 | 16,205,282 | 0 / 0 |
| Moments | 7.916 | 0.000 | 5,222,186 | 0 | 0 / 0 |
| Mean | 0.216 | 0.216 | 355,404 | 355,404 | 0 / 0 |
| Sync | 0.706 | 0.658 | 0 | 0 | 0 / 0 |
| TileFix | 22.556 | 22.537 | 47,525 | 47,822 | 0 / 0 |
| Source | 5.119 | 5.135 | 2,875,116 | 2,875,116 | 20,304 / 20,304 |
| Decoder | 14.533 | 0.000 | 1,440,074 | 0 | 0 / 0 |
| Tail | 3.977 | 3.996 | 1,446,271 | 1,446,280 | 5,104 / 5,104 |
| Boundary | 0.085 | 0.079 | 9 | 9 | 0 / 0 |
| Unmarked | 16.569 | 18.385 | 31,952 | 30,752 | 0 / 0 |

P1's previous Sync attribution was 15.612 ms; the isolated interval is 0.706 ms. The harmonic layout work accounts for 14.878 ms at site 33. P1 TileFix remains 22.556 ms, compared with the previous 22.503 ms. Its large cost persists after the added boundary marks. These measurements do not change the other categories' existing interval boundaries: for example, unmarked constant-coefficient preparation can still be charged to a subsequent Dma mark.

## Top ten Unmarked sites per profile

All source locations below refer to `src/jobs/Kokoro.Generator60x16Run.ps1` in the committed PMU-only patch. The raw CLIXML preserves the measured worktree's line numbers, which include unrelated runtime-frame edits. Site IDs identify the same source call sites in both versions. A source predecessor is lexical; conditional calls need the execution qualifications below. All top-ten sites have zero measured permutes in set B.

### P1

| Rank | Site | ms | Calls | HVX packets | Preceding source step, file line |
|---|---:|---:|---:|---:|---|
| 1 | 33 | 14.878125 | 1 | 0 | Harmonic phase-major calls, ending with `body_har_phase_major_last`, :538; main call :536 |
| 2 | 0 | 0.711719 | 1,417 | 0 | Caller Unmarked mark to the helper's pre-`syncht` boundary, :358; PMU instrumentation |
| 3 | 43 | 0.366510 | 648 | 0 | After `HmxConv` mark on the convolution call line, :599; convolution is already charged to HmxConv |
| 4 | 42 | 0.284479 | 648 | 0 | After the conditional low-window `padRows`, :595, or the AdaInSnake mark when no padding executes |
| 5 | 32 | 0.054583 | 1 | 13,826 | Two phase-major destination `fillVectors` calls, ending :533 |
| 6 | 36 | 0.040521 | 48 | 1,200 | Moment-record clearing before first window fill, :581 |
| 7 | 24 | 0.031094 | 1 | 16,900 | `body_leaky_up`, :509 |
| 8 | 41 | 0.023750 | 48 | 0 | After high-window `padRows` and its TileFix mark, :595 |
| 9 | 38 | 0.021250 | 48 | 0 | Final-batch halo entry, :588; previous first-batch low fill is conditional at :587 |
| 10 | 6 | 0.020833 | 24 | 0 | After front-up convolution's HmxConv mark, :467 |

### P3

| Rank | Site | ms | Calls | HVX packets | Preceding source step, file line |
|---|---:|---:|---:|---:|---|
| 1 | 33 | 14.879687 | 1 | 0 | Harmonic phase-major calls, ending with `body_har_phase_major_last`, :538; main call :536 |
| 2 | 36 | 2.010521 | 48 | 0 | Setup before first window fill; includes unmarked `body_constant` on noise paths, :574; lexical `zeroRecord` at :581 does not execute in Constants mode |
| 3 | 0 | 0.636927 | 1,416 | 0 | Caller Unmarked mark to the helper's pre-`syncht` boundary, :358; PMU instrumentation |
| 4 | 43 | 0.336146 | 648 | 0 | After convolution's HmxConv mark, :599 |
| 5 | 42 | 0.263750 | 648 | 0 | After conditional low-window padding, :595, or AdaInSnake when no padding executes |
| 6 | 32 | 0.050573 | 1 | 13,826 | Two destination `fillVectors` calls, ending :533 |
| 7 | 24 | 0.031354 | 1 | 16,900 | `body_leaky_up`, :509 |
| 8 | 38 | 0.020573 | 48 | 0 | Final-batch halo entry, :588; first-batch low fill at :587 is conditional |
| 9 | 40 | 0.020521 | 48 | 0 | After AdaInSnake mark, :590; lexical runtime `padCapacity` at :593 does not execute in these fixed jobs |
| 10 | 41 | 0.019896 | 48 | 0 | After high-window padding and its TileFix mark, :595 |

Site 0's original raw metadata selected a lexical command from the preceding helper definition. It is corrected in the source metadata and described accurately here; its counters and mark location are unchanged. Source metadata and sparse-site validation corrections after measurement change no emitted instruction for these jobs.

## Stages

Stage totals independently accumulate the same intervals; they must not be added to category totals. Sums are P1 150.501510 ms and P3 123.611979 ms for the final set-A executions. The DSP medians above are separate measurements.

| Stage | P1 ms | P3 ms |
|---|---:|---:|
| Setup | 0.031 | 0.031 |
| Decoder | 14.533 | 0.000 |
| Source | 5.119 | 5.135 |
| HarLayout | 15.028 | 15.033 |
| Front256 | 0.689 | 0.690 |
| Noise256 | 12.011 | 10.864 |
| Ups256 | 1.337 | 1.333 |
| Res256_0 | 10.655 | 9.638 |
| Res256_1 | 11.812 | 10.911 |
| Res256_2 | 13.316 | 12.246 |
| Mean256 | 0.128 | 0.129 |
| Front128 | 0.822 | 0.802 |
| Noise128 | 15.885 | 13.741 |
| Ups128 | 2.390 | 2.373 |
| Res128_0 | 12.333 | 10.208 |
| Res128_1 | 14.151 | 12.036 |
| Res128_2 | 15.906 | 14.074 |
| Mean128 | 0.321 | 0.322 |
| Tail | 3.979 | 3.998 |
| Exit | 0.054 | 0.048 |

The generator scheduler runs on one control thread. Its `$parallel` calls distribute AdaInSnake, Combine, Moments and Mean across the four-thread pool when the tile count admits it; front convolution and layout calls, coefficient preparation, fills, scalar row padding and explicit sync run on the control thread. A stage containing pool calls is not exclusively parallel. Decoder, harmonic source/STFT and tail remain their existing single job paths; no internal marks were added to their protected files. The profile does not assign worker-specific time or hardware stall causes.

`Invoke-KokoroDevelopment.ps1 Verify` passed. The cached generator patch was reviewed separately from the unchanged unstaged runtime-frame hunks. Other protected source files and existing documentation were preserved. No optimization changes or pushes were made.
