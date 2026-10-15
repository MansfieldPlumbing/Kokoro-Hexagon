# Reopened offline decoder/generator: Part 1

Part 1 passes: dog 94.671656 dB, peach 95.595120 dB against the preserved PCM,
with supplied captured draws. All 25 dog intermediates pass the declared
diagnostic tolerance (SNR >=80 dB and maximum error <=1e-4 times max(1, reference
peak)). This tolerance identifies propagated float32 differences; it does not
assert bitwise stock parity. Live/Export -> Supplied decoder replay is bit exact
for both cases at all ten normalization sites. Part 2 is pending.

## Location and identity

Repository/worktree: `C:\Dev\Kokoro-Hexagon-v15-front-end`, branch `v15-front-end`,
starting commit `c67d525d3e4d162e77be121fb8a6fbd546813ed2`. No commits created
at this report's preparation; nothing pushed. Main repository inputs are under
`C:\Dev\Kokoro-Hexagon` and remain read-only. Board coordination uses
`C:\Dev\Pwsh-Development\tools\board.ps1`. No phone access.

Artifacts are in `build/precomputed-decoder-reopen-20261014/`. The previous
`precomputed-decoder-join-20261014.md` receipt and its failed-run artifacts are
preserved unchanged. Pinned PSLowering revision:
`1afabe056235a570da29e268824784557d4f6cdd`; CoreLib admission and two compiled
SIMD workers are checked before rendering. Weights are resident float32 arrays;
convolutions use four compiled workers and Vector128 operations.

| Run artifact | Source SHA-256 | Assembly SHA-256 |
|---|---|---|
| before-fix1 | 360B83B538319C7DF4C7FC51E6DFDF623235BA3F56A97C16ED1F0A69300A54F6 | C1D046850721E020814F02F085EE1C2B8922F193A35EBD8065BF47C57D9D5EA7 |
| after-fix1 | 59F2162715CEC53D80BE0F69A34B867C7266B7B8A33D0B84D40050FB6150DB43 | 83EB7F5604DC734B0273182DC7FABF9630E183A0A3D91631EF1F3652FA30DD90 |
| after-fix2 | 3831F6D63A49940FA0F4DF4FA554B1D8A7A0BFF4E2DF5A63D57521FD187F3788 | A16BF8F4CCA2331F1CD9BDC1D2180501256847A1AF29306FD5AC6669FB7DBBCF |
| levels-nodes / part1-final | 268C66E84776C8C570D7BC4EA5A2C49FF73BFA5076E6926621FA430169B2CFAF | 04DA4AB56161ADE365662D605A86A5363DA736D929C05C52E79AFD661566D31C |

The later host parameter-name cleanup and Seeded wrapper are not the source hash
of the tenth-run measurements above. They do not change synthesis arithmetic.
Their fresh admission/replay/Seeded results are retained separately in
`part1-current-levels` and `part1-seeded`.
The final Part 1 source hash is
`6B6A9E5B32BF47FB4FE44E6131ACE7F002B444FA3320A92340D6F2E5AAFE32ED`.
Its emitted assembly SHA-256 remains
`04DA4AB56161ADE365662D605A86A5363DA736D929C05C52E79AFD661566D31C`;
all 23 numeric method IL bodies were also compared and are identical to the
tenth-run artifact. Fresh level replay passes both cases. Seeded dog renders
52,200 finite samples with seed 17; repeated draw arrays compare exactly.
Verify passes, including 35 known case-pair findings and zero new findings.

## Source-defined fixes

1. First divergent node: `gen.m_source.out0`. Upstream
   `build/stock-albert-capture-hello/source/kokoro/istftnet.py:155-158`,
   `SineGen._f02sine`, says `mode="linear"` for both interpolations and
   `phase = torch.cumsum(rad_values, dim=1) * 2 * torch.pi`.
   Our upsample index divided the float32 destination coordinate by 300.
   `C:\Dev\.vendor\pytorch\aten\src\ATen\native\UpSample.h:261`,
   `compute_scales_value`, uses `static_cast<scalar_t>(1.0 / scale.value())`;
   `area_pixel_compute_source_index:299` uses
   `scale * (dst_index + static_cast<scalar_t>(0.5))`.
   Changed to float32 multiplication by that reciprocal before subtracting 0.5.
   These expressions have different rounding. No weights or activations tuned.

2. Next divergent node: `gen.har_phase`. `istftnet.py:87-94`, `TorchSTFT`, says
   `torch.hann_window(win_length, periodic=True, dtype=torch.float32)`,
   `return_complex=True`, and `torch.angle(forward_transform)`.
   The direct real-input DFT left tiny imaginary residue in DC/Nyquist; negative
   residue selected -pi rather than stock's +pi for negative real values.
   `C:\Dev\.vendor\pytorch\aten\src\ATen\native\SpectralOpsUtils.h:21`,
   NOTE Fourier Transform Conjugate Symmetry, says real-to-complex transforms
   satisfy `X[i_1, ..., i_K] = X[j_i, ..., j_K]*`. Self-conjugate bins must be
   real. Set their imaginary component to positive zero before atan2. Stock's
   captured Nyquist phase range is 0 to 3.14159274. Phase is a learned input
   feature, so +/-pi cannot be interchanged here. No window/padding tuning.

These local PyTorch definitions corroborate the operators; their exact revision
correspondence to the capture installation is unverified. The independent
captured tensors directly establish the numerical result. No Python executed.

## Every node before and after both fixes

Each cell is maximum absolute error / SNR dB. Middle column is simultaneously
after fix 1 and before fix 2. Same harness, dog inputs, reference files, supplied
draws, four-worker configuration and host throughout. Candidate artifacts differ
only by the respective source fix; hashes above identify each. No timing
comparison is inferred from these diagnostic runs.

| Node (call order) | Before fix 1 | After fix 1 / before fix 2 | After fix 2 |
|---|---:|---:|---:|
| dec.encode | 6.19888306e-6 / 120.297711 | 6.19888306e-6 / 120.297711 | 6.19888306e-6 / 120.297711 |
| dec.decode0 | 4.76837158e-6 / 119.067167 | 4.76837158e-6 / 119.067167 | 4.76837158e-6 / 119.067167 |
| dec.decode1 | 1.52587891e-5 / 119.231631 | 1.52587891e-5 / 119.231631 | 1.52587891e-5 / 119.231631 |
| dec.decode2 | 1.33514404e-5 / 119.412740 | 1.33514404e-5 / 119.412740 | 1.33514404e-5 / 119.412740 |
| dec.decode3 | .000134527683 / 118.004967 | .000134527683 / 118.004967 | .000134527683 / 118.004967 |
| gen.input_x | .000134527683 / 118.004967 | .000134527683 / 118.004967 | .000134527683 / 118.004967 |
| gen.m_source.out0 | .00212550908 / 58.422120 | 2.98023224e-8 / 146.005746 | 2.98023224e-8 / 146.005746 |
| gen.m_source.out1 | 0 / infinity | 0 / infinity | 0 / infinity |
| gen.m_source.out2 | 0 / infinity | 0 / infinity | 0 / infinity |
| gen.har_spec | .0054590106 / 60.887023 | 2.38418579e-7 / 139.654625 | 2.38418579e-7 / 139.654625 |
| gen.har_phase | 6.28318548 / 5.576168 | 6.28318548 / 5.806165 | .000278234482 / 116.929963 |
| gen.noise_convs0 | .516576782 / 16.151501 | .482764781 / 16.328080 | 6.93649054e-6 / 125.795306 |
| gen.noise_res0 | .403468251 / 20.679950 | .37714833 / 20.821186 | 7.15255737e-6 / 125.942560 |
| gen.ups0 | 3.70740891e-5 / 120.103671 | 3.70740891e-5 / 120.103671 | 3.70740891e-5 / 120.103671 |
| gen.resblocks0 | .947060108 / 29.280829 | .949525833 / 29.496985 | 6.10351562e-5 / 115.590528 |
| gen.resblocks1 | 1.07869148 / 33.399781 | 1.01039386 / 33.609618 | .000495910645 / 112.902437 |
| gen.resblocks2 | 1.26479697 / 32.530819 | 1.26872516 / 32.699354 | .000200271606 / 113.605762 |
| gen.noise_convs1 | .620922118 / 16.012583 | .526686966 / 16.020042 | 6.85453415e-7 / 138.182020 |
| gen.noise_res1 | .166611671 / 35.456348 | .16653955 / 35.467545 | 4.76837158e-6 / 129.696539 |
| gen.ups1 | .0716942549 / 38.480963 | .0720101595 / 38.558768 | 1.14440918e-5 / 120.191987 |
| gen.resblocks3 | 1.59267044 / 40.948148 | 1.59772301 / 40.994211 | .000213623047 / 117.961232 |
| gen.resblocks4 | 2.11002636 / 38.748078 | 2.1042676 / 38.995063 | .000367164612 / 112.434301 |
| gen.resblocks5 | 2.38797259 / 35.421258 | 1.95342278 / 35.618250 | .000603199005 / 106.186834 |
| gen.conv_post | .3516922 / 39.572822 | .349700928 / 39.574832 | .000110626221 / 121.419413 |
| pcm | .0461894497 / 23.752839 | .0466709957 / 23.862430 | 7.42822886e-6 / 94.530857 |

## Exported levels and final Part 1 gate

Export retains double sums and squared sums per token/channel at each site's
own temporal resolution. Live mean/variance are derived from exactly these
totals, cast to float32 for normalization. Supplied consumes those values and
does not measure target activations. This replaces the initial float32 two-pass
decoder variance reduction; it is explicitly a reduction-order difference from
stock, not a frozen-statistics approximation. Generator normalization remains
live on each render. Site `decode.3.norm2` uses twice the duration frames;
the other nine sites use duration frames. Both exact replay checks pass.

The SIMD input-index and packed-vector optimizations preserve all 25 node files
bit for bit against after-fix2. The moments reduction changes the final nodes as
follows; every diagnostic gate still passes:

| Node | Max abs error | SNR dB |
|---|---:|---:|
| dec.encode | 7.39097595e-6 | 120.452503 |
| dec.decode0 | 5.00679016e-6 | 119.182121 |
| dec.decode1 | 1.52587891e-5 | 119.333761 |
| dec.decode2 | 1.52587891e-5 | 119.471871 |
| dec.decode3 | .000147342682 | 118.192778 |
| gen.input_x | .000147342682 | 118.192778 |
| gen.m_source.out0 | 2.98023224e-8 | 146.005746 |
| gen.m_source.out1 | 0 | infinity |
| gen.m_source.out2 | 0 | infinity |
| gen.har_spec | 2.38418579e-7 | 139.654625 |
| gen.har_phase | .000278234482 | 116.929963 |
| gen.noise_convs0 | 6.93649054e-6 | 125.795306 |
| gen.noise_res0 | 7.15255737e-6 | 125.942560 |
| gen.ups0 | 4.0769577e-5 | 120.201123 |
| gen.resblocks0 | 6.29425049e-5 | 115.666797 |
| gen.resblocks1 | .00035572052 | 115.071765 |
| gen.resblocks2 | .000208854675 | 113.988132 |
| gen.noise_convs1 | 6.85453415e-7 | 138.182020 |
| gen.noise_res1 | 4.76837158e-6 | 129.696539 |
| gen.ups1 | 1.1920929e-5 | 120.622133 |
| gen.resblocks3 | .000213623047 | 117.965854 |
| gen.resblocks4 | .000371932983 | 112.432301 |
| gen.resblocks5 | .000655174255 | 106.360761 |
| gen.conv_post | .000114440918 | 121.622292 |
| pcm | 7.20471144e-6 | 94.671656 |

| Case | Supplied PCM SNR dB | Max abs error | Decoder tenth ms | Generator tenth ms | Live/Supplied replay |
|---|---:|---:|---:|---:|---|
| dog | 94.671656 | 7.20471143722534e-6 | 1417.1781 | 33601.2676 | bit exact, 10 sites |
| peach | 95.595120 | 6.59748911857605e-6 | 1884.9959 | 41069.1010 | bit exact, 10 sites |

All ten renders per case use one resident checkpoint and the same assembly,
capture and worker count. Times are Stopwatch wall times of each region; they
exclude loading/compilation and include dispatch/allocation. These are individual
case measurements, not a hardware-performance comparison. Laptop hardware model
and load isolation are unverified; another level/admission process was started
during the end of the peach sequence, so peach timing may include contention.
No warm dog decoder exceeded ten seconds. Generator has no user-specified ten
second limit; it remains an offline tool.

## Exact commands

From the worktree, each diagnostic output directory was fresh:

```powershell
& C:/Dev/Pwsh-Development/tools/board.ps1 Claim -Agent Codex -Task 'Offline decoder/generator + precomputed-decoder join test' -Location C:/Dev/Kokoro-Hexagon-v15-front-end -Branch v15-front-end
& ./Invoke-KokoroDevelopment.ps1 PrecomputedDecoder -Parameters @{Mode='Nodes'; OutputDirectory='C:\Dev\Kokoro-Hexagon-v15-front-end\build\precomputed-decoder-reopen-20261014\before-fix1'}
# Repeat the identical Nodes command after each source fix with directories after-fix1 and after-fix2.
& ./Invoke-KokoroDevelopment.ps1 PrecomputedDecoder -Parameters @{Mode='Levels'; OutputDirectory='C:\Dev\Kokoro-Hexagon-v15-front-end\build\precomputed-decoder-reopen-20261014\levels'}
& ./Invoke-KokoroDevelopment.ps1 PrecomputedDecoder -Parameters @{Mode='Nodes'; OutputDirectory='C:\Dev\Kokoro-Hexagon-v15-front-end\build\precomputed-decoder-reopen-20261014\levels-nodes'}
& ./Invoke-KokoroDevelopment.ps1 PrecomputedDecoder -Parameters @{Mode='Gate'; Runs=10; OutputDirectory='C:\Dev\Kokoro-Hexagon-v15-front-end\build\precomputed-decoder-reopen-20261014\part1-final'}
& ./Invoke-KokoroDevelopment.ps1 PrecomputedDecoder -Parameters @{Mode='Levels'; OutputDirectory='C:\Dev\Kokoro-Hexagon-v15-front-end\build\precomputed-decoder-reopen-20261014\part1-current-levels'}
& ./Invoke-KokoroDevelopment.ps1 PrecomputedDecoder -Parameters @{Mode='Seeded'; CaseName='dog'; Runs=1; OutputDirectory='C:\Dev\Kokoro-Hexagon-v15-front-end\build\precomputed-decoder-reopen-20261014\part1-seeded'}
& ./Invoke-KokoroDevelopment.ps1 Verify
```

## Changed files, scope and protected material

- `tools/Invoke-KokoroPrecomputedDecoder.ps1`: requested compiled offline renderer, node diagnostics, level export/replay, noise modes and experiment host.
- `Invoke-KokoroDevelopment.ps1`: requested owning entrypoint dispatch/help.
- `docs/results/precomputed-decoder-reopen-20261014.md`: this new gate receipt.
- `C:\Dev\Pwsh-Development\BOARD.md` and ignored `build/board/board.clixml`: required claim/finish coordination through the board command.
- Ignored `build/precomputed-decoder-reopen-20261014/**`: compiled DLLs, native candidate tensors, node/gate/profile CLIXML and level exports from the commands above. Each run folder and hash identifies its files.

Scope beyond the prompt: none. Protected files touched: none. Existing frozen
captures, pins, receipts, selector and DSP sources were not changed. The old
untracked failed receipt is preexisting task work and remains unchanged.

## Uncommitted state at preparation

Verbatim `git status --short`, worktree:

```text
 M Invoke-KokoroDevelopment.ps1
?? docs/results/precomputed-decoder-join-20261014.md
?? tools/Invoke-KokoroPrecomputedDecoder.ps1
```

This new report was then added; status gains
`?? docs/results/precomputed-decoder-reopen-20261014.md` until committed.
Main repository (read-only; all changes preexisting):

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

Shared repository (only board changes belong to this task):

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

MeasureAudio worktree and `C:\Dev\.vendor\pytorch`: empty output (clean).
Stops: none in the reopened final Part 1 run. The initial failed gate is preserved
in the earlier receipt and was explicitly reopened for this investigation.
