STOP — Part 1 Supplied-mode PCM gate failed on dog: 23.7528390735695 dB SNR, below the required 60 dB. No tuning or full rerender followed the failure. Part 2 did not run.

1. Location and commits

Repository: `Kokoro-Hexagon`. Worktree: `Kokoro-Hexagon-v15-front-end`. Branch: `v15-front-end`. Starting and ending HEAD: `c67d525d3e4d162e77be121fb8a6fbd546813ed2`.

Commits created for this task: none. Nothing was pushed. No part passed its complete gate, so there was no gated commit. Verify was not run; no commit was attempted. The draft remains uncommitted. The board entry was claimed and finished with no commits. No phone access or phone-lock operation occurred.

The existing TextEncoder commits `362f9223eaabe2c1f946fe488020f2eb0f3d77c3` and `c67d525d3e4d162e77be121fb8a6fbd546813ed2` predate this task; they are not new decoder/generator results.

2. Uncommitted state

`git -C Kokoro-Hexagon-v15-front-end status --short`, verbatim:

```text
 M Invoke-KokoroDevelopment.ps1
?? precomputed-decoder-join-20261014.md
?? tools/Invoke-KokoroPrecomputedDecoder.ps1
```

`git -C Kokoro-Hexagon status --short`, verbatim:

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

`git -C Pwsh-Development status --short`, verbatim:

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

Only BOARD.md and its ignored board state were changed by this task in the shared repository. All other listed changes were preserved.

`git -C ~/.codex\worktrees\measure-audio\Kokoro-Hexagon status --short` emitted zero lines:

```text
```

That read-only checkout is at `93a6d8220ed20734b0f5a943ef95b03c922d5be1`; its MeasureAudio command was inspected but not invoked because no WAV render passed Part 1.

`git -C .vendor\pytorch status --short` emitted zero lines:

```text
```

That source checkout was consulted read-only. Its version correspondence to the frozen reference's installed binary was not established; version-dependent inferences from it are unverified.

3. Files changed

Uncommitted files relative to `Kokoro-Hexagon-v15-front-end`:

- `Invoke-KokoroDevelopment.ps1`: add the PrecomputedDecoder entrypoint dispatch to the experiment script.
- `tools/Invoke-KokoroPrecomputedDecoder.ps1`: one draft script with -h help, compiled Vector128 convolution workers, float32 decoder/generator math, checkpoint loading, captured-noise gate and stage profiles. The Seeded draw helper is present but not render-validated or exposed as a completed mode; Join is unimplemented and rejects execution.
- `precomputed-decoder-join-20261014.md`: requested failure report, identities, status snapshots, profiles and commands.

Coordination writes:

- `Pwsh-Development\BOARD.md`: generated claim/finish entry for this task.
- `Pwsh-Development\build\board\board.clixml`: persisted claim/finish state.

Generated ignored files, relative to the new worktree:

- `build/precomputed-decoder-20261014/dog-decoder-run1-profile.clixml`: first decoder-only development-pass stage profile.
- `build/precomputed-decoder-20261014/dog-decoder-run2-profile.clixml`: second decoder-only development-pass stage profile.
- `build/precomputed-decoder-20261014/dog-decoder-run3-profile.clixml`: third decoder-only development-pass stage profile.
- `build/precomputed-decoder-20261014/dog-decoder-run4-profile.clixml`: fourth decoder-only development-pass stage profile.
- `build/precomputed-decoder-20261014/dog-decoder-run5-profile.clixml`: fifth decoder-only development-pass stage profile.
- `build/precomputed-decoder-20261014/dog-decoder-run6-profile.clixml`: sixth decoder-only development-pass stage profile.
- `build/precomputed-decoder-20261014/dog-decoder-run7-profile.clixml`: seventh decoder-only development-pass stage profile.
- `build/precomputed-decoder-20261014/dog-decoder-run8-profile.clixml`: eighth decoder-only development-pass stage profile.
- `build/precomputed-decoder-20261014/dog-decoder-run9-profile.clixml`: ninth decoder-only development-pass stage profile.
- `build/precomputed-decoder-20261014/dog-decoder-run10-profile.clixml`: tenth decoder-only development-pass stage profile.
- `build/precomputed-decoder-20261014/dog-run1-profile.clixml`: all 58 live AdaIN and 72 convolution stage timings from the failing complete render.
- `build/precomputed-decoder-20261014/part1-gate.clixml`: failed dog PCM comparison, measured times and exact source/assembly identities.
- `build/precomputed-decoder-20261014/dog-failed-pcm.f32`: 52,200 failed float32 PCM samples, retained for diagnosis; not a listening WAV or accepted result.
- `build/precomputed-decoder-20261014/24C930CCCC32CA1C83D98EA4A576F1C8495B3A4C34BA5B50639DE9F483E56B0B/Kokoro.OfflineRender.dll`: initial successful threaded SIMD admission assembly.
- `build/precomputed-decoder-20261014/BF61B77BB933858C67185B6F9BBAD595AF9B884C36F725EDE8BFB0197E74C06C/Kokoro.OfflineRender.dll`: development decoder assembly before handling omitted initialized InstanceNorm affine weights.
- `build/precomputed-decoder-20261014/9F4665C4822475F87EE83A4AAA590960E1C6F5155D2DAE9B677459B6AAD75323/Kokoro.OfflineRender.dll`: development decoder assembly cache.
- `build/precomputed-decoder-20261014/BE25732F296B74876E3326946A20F9C07CC198C64A47CEEBADF12B837EE55918/Kokoro.OfflineRender.dll`: complete-render assembly used for the failed PCM gate and subsequent read-only diagnostic.

Protected files touched: none, including staged-out files. No selector, DSP job, emitter, dependency pin, capture, frozen bank, baseline, manifest or historical receipt was modified. `Pwsh` was not accessed. No Python was executed. No JSON parser or producer was added to the experiment. No change was made in the main Kokoro checkout, the MeasureAudio checkout or the PyTorch source checkout.

4. Scope

Anything built or changed beyond the requested experiment: none. The compiler/SIMD admission check and stage profiling are within the required implementation and gate work. No replacement selector, measurement implementation, dependency or phone machinery was built.

5. Gate results, timing and comparison conditions

Part 1 failed at the first dog Supplied-mode render:

| Case | Run | Samples | PCM SNR, dB | Maximum absolute PCM error | Decoder, ms | Generator, ms |
|---|---:|---:|---:|---:|---:|---:|
| dog | 1 | 52,200 | 23.7528390735695 | 0.0461894497275352 | 14,547.4479 | 145,675.0488 |
| peach | not run | — | — | — | — | — |

The two displayed times are first-run wall-clock scope, not warm tenth-run measurements. They include lazy checkpoint tensor loading, weight-normalization folding, initial numeric JIT and orchestration for each region. They exclude prior compiler execution, checkpoint-descriptor parsing, capture loading and alignment. The first-run decoder time above 10 seconds is not the warm-performance stop condition. The PCM failure stopped execution before another complete render.

The earlier decoder-only development draft completed ten passes on dog. Recorded total milliseconds: 6349.823, 3653.498, 5102.008, 5003.288, 5151.102, 4757.842, 5581.095, 5126.725, 5293.852, 5130.519. No warm pass in that probe exceeded 10 seconds. The timing loop's console values were recorded in the task output; individual stage profiles are persisted above. The profiles did not themselves record their source/assembly identities, so an exact identity-to-profile association remains unverified. This probe does not establish tenth-run performance of the later complete-render artifact.

There is no before/after speed comparison between the decoder-only probe and the complete render. Differences: source/assembly revision, decoder-only versus decoder+generator harness, cold versus tenth-run cache/JIT state, and availability of generator code/weights. Inputs, requested worker count (4), laptop and decoder model equations were retained. Exact instantaneous host load and actual thread concurrency were not measured.

Tenth decoder-only development-pass stage profile (milliseconds; no generator present):

| Stage | ms |
|---|---:|
| F0_conv | 0.229400 |
| N_conv | 0.176700 |
| encode.norm1 | 1.957500 |
| encode.conv1 | 242.240900 |
| encode.norm2 | 1.281300 |
| encode.conv2 | 443.730900 |
| encode.conv1x1 | 109.760900 |
| asr_res.0 | 8.232000 |
| decode.0.norm1 | 1.303500 |
| decode.0.conv1 | 477.704900 |
| decode.0.norm2 | 1.353700 |
| decode.0.conv2 | 429.875500 |
| decode.0.conv1x1 | 175.384100 |
| decode.1.norm1 | 1.428700 |
| decode.1.conv1 | 444.476300 |
| decode.1.norm2 | 1.349200 |
| decode.1.conv2 | 452.413300 |
| decode.1.conv1x1 | 167.493700 |
| decode.2.norm1 | 1.452900 |
| decode.2.conv1 | 513.104600 |
| decode.2.norm2 | 1.271600 |
| decode.2.conv2 | 475.958600 |
| decode.2.conv1x1 | 226.343800 |
| decode.3.norm1 | 1.416400 |
| decode.3.pool | 3.341000 |
| decode.3.conv1 | 530.444200 |
| decode.3.norm2 | 0.992500 |
| decode.3.conv2 | 228.966900 |
| decode.3.conv1x1 | 167.497000 |

Stage timings cover convolution dispatch/wait or live AdaIN evaluation. They omit surrounding concatenation, residual operations, activation calls and host dispatch overhead and therefore are not claimed to sum to the whole-pass wall time.

Numerical comparison conditions: the candidate used the same frozen dog text-encoder tensor aligned by the same captured durations, the same F0/N tensors, captured acoustic style vector and all three captured random draws, in their recorded shapes and order. Each input file was verified against capture.psd1. Both PCM vectors have 52,200 samples. Candidate signal/error sums and maximum error were computed in compiled code.

Differences from the frozen stock reference: current lowered float32 kernels and direct DFT/iDFT implementation versus the original PyTorch operators/backends; SIMD/time-lane reduction and serial float32 weight-normalization/AdaIN reductions versus original framework reduction schedules; current four-task convolution scheduling versus unverified original threading; current runtime versus the frozen capture environment. Candidate coefficients for the DFT are generated using standard Math trigonometric functions and stored float32; no polynomial/table approximation of activations or quantization was introduced. These differences did not satisfy the numerical gate and are not claimed exact.

No matched stock timing run was performed. Only the tensor inputs and reference PCM artifact were matched for the error measurement; the old reference harness/artifact/backend were not recreated. The reported SNR is a candidate-to-frozen-reference error metric, not an interchangeable-harness performance comparison.

Part 2: not run. Donor count, decoder time per donor, A/B/C1/C2/C4 measurements, IntegratedLufs, TruePeakDbtp, join discontinuity ratios and per-unit store sizes are unavailable. The requested WAV folder exists at `Kokoro-Hexagon-v15-front-end\build\precomputed-decoder-20261014`, but no WAVs were generated. No conclusion about runtime decoder removal or overlap-add quality is established.

6. Error boundary, identities and quoted sources

The first confirmed divergent comparison boundary is PCM. The supplied bundle has no same-input stock decoder-output, harmonic STFT or generator intermediate tensors. Therefore the first divergent stock node is unverified; assigning a definite upstream root cause would exceed the evidence.

A diagnostic reused the exact failed assembly and original dog F0/draws/checkpoint source-projection weights, invoking only its existing Harmonic and Stft methods. It did not modify source, synthesize PCM, adjust parameters or rerun the gate. Candidate Nyquist phase minimum was -3.14159274 and maximum +3.14159274. The direct DFT accumulates a small imaginary Nyquist residue; its sign can select opposite phase branches. This is a concrete candidate concern because phase is passed as a feature. The corresponding stock Nyquist phases are not provided, so its contribution to this PCM failure is not independently measured.

Source review also identified a potential rounding-schedule difference in harmonic interpolation: candidate Harmonic uses float32 `(t+0.5)/300-0.5`; the consulted PyTorch UpSample.h uses `scale * (dst_index + 0.5) - 0.5`. Division and multiplication by a rounded reciprocal are not a proven identical float32 schedule. The source checkout's correspondence to the frozen binary is unverified. No change or tuning followed either finding.

Exact failed-artifact identities:

- Script SHA-256: `BE25732F296B74876E3326946A20F9C07CC198C64A47CEEBADF12B837EE55918`.
- DLL SHA-256: `01CF0D67214558A4D973E5068CEE11C9F804AC4CD90C17CC49161E48F27BAD5E`.
- Compiler: unchanged frontend pin `1afabe056235a570da29e268824784557d4f6cdd`, all nine cached source files checked against the existing verified-source.tsv record.
- Checkpoint SHA-256: `496DBA118D1A58F5F3DB2EFC88DBDC216E0483FC89FE6E47EE1F2C53F18AD1E4`, checked before parsing.
- Capture: immutable `build\score-capture-20261014\capture.psd1`; individual tensor hashes were checked by Read-OfflineReference.

Quoted source/evidence for API and implementation claims:

- Stock graph, `build\stock-albert-capture-hello\source\kokoro\istftnet.py`, AdaIN1d.forward: `(1 + gamma) * self.norm(x) + beta`. The candidate measures mean and population variance from the current activation at every call; the full profile contains 58 LiveAdaIN stage entries. No corpus or frozen activation statistics were substituted.
- Same file, TorchSTFT.transform: `return torch.abs(forward_transform), torch.angle(forward_transform)`; Generator.forward: `har = torch.cat([har_spec, har_phase], dim=1)`. Thus opposite phase branches can affect the excitation feature tensor; they are not automatically interchangeable in this graph.
- Same file, SineGen._f02sine: `phase = torch.cumsum(rad_values, dim=1) * 2 * torch.pi`; the source applies linear downsampling and upsampling around that operation. The candidate's backend equivalence failed its final gate and is not claimed established.
- Stock loader, `...\source\kokoro\model.py`, KModel.__init__: `load_state_dict(state_dict, strict=False)` after stripping module prefixes. Installed `micromamba\envs\mono\Lib\site-packages\torch\nn\modules\batchnorm.py`, _NormBase.reset_parameters: `init.ones_(self.weight)` and `init.zeros_(self.bias)`. The checkpoint descriptors omit the decoder InstanceNorm affine tensors; the draft retains those initialized affine values while still measuring activation statistics live.
- Installed `...\torch\_torch_docs.py`, angle documentation: “Starting in PyTorch 1.8, angle returns pi for negative real numbers”. This documents the phase convention; the actual captured Nyquist intermediate values remain unverified.
- Read-only `.vendor\pytorch\aten\src\ATen\native\UpSample.h`, area_pixel_compute_source_index: `scale * (dst_index + static_cast<scalar_t>(0.5)) - static_cast<scalar_t>(0.5)`. Version match to the capture binary is unverified.
- Candidate `tools/Invoke-KokoroPrecomputedDecoder.ps1`, OfflineConvolutionWorker.Run: `[System.Runtime.Intrinsics.X86.Sse]::Add($sum, [System.Runtime.Intrinsics.X86.Sse]::Multiply($values, $weight))`; four lanes are constructed as Vector128<float>. Invoke-OfflineConv creates up to four compiled worker delegates and schedules `[Threading.Tasks.Task]::Run($action)`. Actual simultaneous thread count was not instrumented and is unverified.
- Cached pinned compiler `src/Dev.MansfieldPlumbing.PowerShell.Lowering.psm1`, Test-LoweredAssembly: it enumerates the emitted assembly references through the PE metadata reader. Inspection of the failed DLL returned `AssemblyReferences = {System.Private.CoreLib}` and no SMA reference. The numeric kernels, not PowerShell script blocks, were the task delegates.

There is no hardware/SDK/device performance claim. SIMD instruction support was checked by the script's Sse.IsSupported and Sse41.IsSupported guards, and its small threaded convolution assertion passed on this host. No phone capability, runtime deployment, voice-row-25 join behavior or end-to-end speech quality is established.

Input shape/bounds checks and checkpoint/compiler/capture integrity checks were used. No input-driven code evaluation, runtime C# compilation, native interop, protection bypass or pin change was introduced. The draft has not passed project Verify or the requested full numerical gate and must not be promoted as a working offline renderer.

7. Exact commands and stop disposition

Claim, executed after reading the binding policies and board:

```powershell
& Pwsh-Development\tools\board.ps1 Claim -Agent Codex -Task 'Offline decoder/generator + precomputed-decoder join test' -Location Kokoro-Hexagon-v15-front-end -Branch v15-front-end
```

Executed from `Kokoro-Hexagon-v15-front-end`:

```powershell
& Pwsh-Development\tools\Get-ProjectContext.ps1 -Project Kokoro-Hexagon-v15-front-end
& .\Invoke-KokoroDevelopment.ps1
& .\Invoke-KokoroDevelopment.ps1 PrecomputedDecoder -Parameters @{Mode='Admit'}
& .\Invoke-KokoroDevelopment.ps1 PrecomputedDecoder -Parameters @{Mode='Gate';Threads=4}
```

The Gate command above was also the command for the earlier decoder-only development draft. Its source was subsequently extended before the complete-render gate; those runs are explicitly separated in section 5. Initial source-admission errors were resolved before any PCM gate: fully qualified Vector128 type names, identical explicitly cast arithmetic operand types, and stock initialized affine defaults for omitted checkpoint parameters. No PSLowering change was made. The final failed source has not been changed since its PCM gate.

The read-only failure diagnostic loaded the DLL named in section 6, verified its SHA-256, reused OfflineRenderMath.Harmonic and OfflineRenderMath.Stft with original dog inputs and source-projection weights, copied the 21st zero-based channel (Nyquist phase) into a float[] and used compiled Enumerable.Min/Max. It did not produce a second PCM candidate.

Finish command, with no gated commits:

```powershell
& Pwsh-Development\tools\board.ps1 Finish -Agent Codex -Task 'Offline decoder/generator + precomputed-decoder join test'
```

Stop condition: supplied-noise PCM SNR below 60 dB. No commit, push, tuning, window experiment, donor decoding or MeasureAudio run followed it. The experiment does not answer whether precomputed decoder units can replace the runtime decoder.
