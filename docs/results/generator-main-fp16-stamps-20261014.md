# Generator main-resblock FP16 stamps, 2026-10-14

No numerical STOP condition. These are independent two-convolution layer
diagnostics, not the connected generator, and do not admit whole-generator PCM.
Stage A's convolutions execute on the device in these checks.

Worktree: `C:\Dev\Kokoro-Hexagon-generator-templates`, branch
`generator-templates`, starting commit `1acb237b0bddf07617202b5ce38116b6b61fcb47`.
Measurements precede this change's commit. Nothing was pushed.

## Conditions and reference

One attached SM8550 target, Kokoro package `dev.mansfieldplumbing.kokoro`,
five invocations per case on the existing diagnostic transport. Each artifact
passed `Test-KokoroKernel.AssemblerMatch` before the same library was executed.
The harness verifies completion and restores startup files; the board lock was
taken and released around each device session. Device identifiers were not
recorded. No phone-speaker speech is claimed by these Samples=1 diagnostics.

Input is the preserved dog capture with its captured draws, af_heart style, and
checkpoint SHA256
`496DBA118D1A58F5F3DB2EFC88DBDC216E0483FC89FE6E47EE1F2C53F18AD1E4`.
The existing admitted offline numeric assembly is
`446FD867E60D8D21F267D9B372A6736D357E84DEF7B680609E8386CBE22D1F8D`,
from source
`8DAD8231FDCBF80C024E2C9C0A4D53FC7CE0E02D3415ABBE2FE73A1AB8E07257`.
The convolution reference consumes the decoded FP16 device input, not the
preceding stock tensor. The second convolution's reference consumes the actual
device epilogue output and the exact supplied FP16 halo. The operand column
compares the smoothstep operand with stock Snake evaluated on that epilogue's
own device input. No layer-to-layer SNR-drop criterion is used.

Normalization constants in this diagnostic are supplied offline for the tested
site. They are not the seven-utterance deployment calibration. These runs
do not establish connected streaming, a complete main path, the tail, resident
transport, playback, or the 25 dB whole-generator gate.

## Layer table

`b/j` identifies `generator.resblocks.b.convs1.j` and `.convs2.j`.
There are 160 stage-A positions and 960 stage-B positions, each 16 frames.
Both convolutions use the block's kernel 3/7/11; convs1 dilation is 1/3/5,
and convs2 dilation is one. All outputs were finite.

HMX milliseconds and TMAC/s below are **run-0 convolution-only telemetry**,
excluding DMA, the epilogue and the second convolution. They are not five-warm-run
medians. The original transport's median also includes run 0. Later full-generator
and resident-transport measurements must explicitly exclude warm-up.

| b/j | convs1 SNR dB | operand vs stock dB | convs2 SNR dB | HMX ms | HMX TMAC/s |
|---|---:|---:|---:|---:|---:|
| 0/0 | 70.95833 | 40.61523 | 71.47784 | 0.010833 | 2.90375 |
| 0/1 | 71.10268 | 41.03235 | 71.35914 | 0.008542 | 3.68280 |
| 0/2 | 71.46235 | 42.93905 | 71.90835 | 0.009896 | 3.17884 |
| 1/0 | 71.87889 | 41.02446 | 72.16721 | 0.022656 | 3.23974 |
| 1/1 | 71.76993 | 41.12231 | 72.13350 | 0.020000 | 3.67002 |
| 1/2 | 71.80223 | 42.65192 | 72.69343 | 0.022969 | 3.19566 |
| 2/0 | 72.12909 | 41.46809 | 72.50882 | 0.034740 | 3.32023 |
| 2/1 | 71.95658 | 39.80853 | 72.36026 | 0.035990 | 3.20491 |
| 2/2 | 72.32586 | 41.29652 | 72.78297 | 0.035417 | 3.25675 |
| 3/0 | 70.93992 | 36.92838 | 72.04254 | 0.013958 | 3.38048 |
| 3/1 | 71.69423 | 42.03449 | 72.67060 | 0.013437 | 3.51151 |
| 3/2 | 71.11006 | 42.77960 | 73.21336 | 0.013281 | 3.55282 |
| 4/0 | 71.43341 | 41.18626 | 71.46533 | 0.030052 | 3.66366 |
| 4/1 | 71.82721 | 41.13840 | 71.17763 | 0.028854 | 3.81576 |
| 4/2 | 72.24174 | 40.67307 | 73.09050 | 0.028958 | 3.80203 |
| 5/0 | 72.00207 | 39.79594 | 71.72345 | 0.046302 | 3.73666 |
| 5/1 | 71.89869 | 39.83855 | 71.61366 | 0.046510 | 3.71992 |
| 5/2 | 72.01521 | 40.13929 | 73.39680 | 0.044167 | 3.91732 |

Full precision values, peak errors, library hashes and VTCM sizes are preserved
in `build/generator-templates/main-layer-table.clixml` and each case's
`gate.clixml`. Each case's generated native inputs and output are retained.
Case directories are `stamp-smoothstep-r<b>-d<j>`; 2/2 uses
`stamp-a-k11-d5-20261014`. Stage-B directories also contain
`stock-then-template1.wav`, 16-bit, 24 kHz, stock first with a 0.6 s gap,
using the offline continuation. Stage-A diagnostics produce no PCM.

## Default phase lock

The reference probe was read, not executed, from
`C:\Dev\Kokoro-Hexagon\build\snake-lock-20261014\snake_lock.py`, SHA256
`84E9927E98E94AC619A30F9C553988774730F045B5530D65F74671B7265F6576`.
The PowerShell producer computes per-seat means, excludes padded frames from
the block count, and replicate-pads a partial stage-B frame for that reduction.
It streams prepacked affine phase and tangent coefficients derived from each
seat's mean, folded phase, sin-squared value, slope and direction. The device
evaluates the equivalent folded closed form and bounded tangent. There is no
device sine, lookup table or carried state between blocks.

`Shape` defaults to `Lock`; `Smoothstep` is the other build setting.
`BlockFrames` defaults to 16. The checkpoint contains negative alpha values;
the bounded quantity is w in [0,1], followed by `u + w/a`, preserving their sign.

The default-lock diagnostic has 1,920 positions, so it differs from the
16-frame layer table above. It checks resblocks.3.convs1.0 and convs2.0 only:
70.94160 dB and 72.16323 dB versus their own-input float convolution references.
The lock operand agrees with the offline lock equations at 73.71908 dB,
peak error 0.00366306305. Its partial offline continuation is 40.00125 dB
against stock; this is not a whole-generator admission or a listening verdict.
Library SHA256:
`C67BC173889540B90F524A940F8C5591057E48B56D86D0FD65245BC13D95290B`.
Run-0 HMX time is 0.0267708333 ms, 3.52517379 TMAC/s. The WAV pair is
`build/generator-templates/default-lock-20261014/stock-then-template1.wav`.

## Reproduction

From the worktree, choose fresh output directories:

```powershell
for ($block = 0; $block -lt 6; $block++) {
    for ($stage = 0; $stage -lt 3; $stage++) {
        & C:/Dev/Pwsh-Development/tools/board.ps1 Lock -Agent Codex -Reason 'Main resblock stamp'
        try {
            & ./Invoke-KokoroDevelopment.ps1 Run -Case generator-template1 -Runs 5 -Soc SM8550 -Parameters @{
                ConnectedConsumer = $true; Shape = 'Smoothstep'; ResBlockIndex = $block; DilationIndex = $stage
            } -OutputDirectory (Join-Path $PWD "build/generator-templates/recheck-r$block-d$stage")
        } finally {
            & C:/Dev/Pwsh-Development/tools/board.ps1 Unlock -Agent Codex
        }
    }
}
& ./Invoke-KokoroDevelopment.ps1 Verify
```

For the lock check, use `Parameters @{ConnectedConsumer=$true;Tiles=60}`
and a fresh directory. No before/after speed or quality improvement is inferred
across different shapes, inputs, lengths or reference definitions.

The added 512-input/32-output HMX declarations, third-input mean and leaky
epilogue options are preparation for the remaining joins; their selected modes
have not yet been executed on the phone. General SDK or API portability is
unverified. Frozen receipts, captures, manifests and dependency pins were not
modified. No unrequested product scope was added.
