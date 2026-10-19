# Generator lock handoff and warm convolution timing, 2026-10-15

No numerical STOP condition. This is a connected two-convolution diagnostic,
not a complete main path or whole-generator PCM admission.

Worktree: `C:\Dev\Kokoro-Hexagon-generator-templates`, branch
`generator-templates`, parent commit `6b392cd5645fe79130079cc225ea2584392d02bf`.
The six-file parent change passed Verify before commit. Nothing was pushed.

## Conditions and result

One attached SM8550 phone, package `dev.mansfieldplumbing.kokoro`, dog capture,
captured draws, 128 channels, 960 positions, kernel 3, dilation 1, default Lock,
16-frame lock blocks. The reference consumes each operation's actual decoded
FP16 device input, including the supplied diagnostic halos. The checkpoint and
admitted offline assembly identities are those in
`generator-main-fp16-stamps-20261014.md`; no reference artifact was changed.

| Layer | Own-input SNR dB | Peak error | Run-0 HMX ms | Run-0 TMAC/s | Five-warm median HMX ms | Five-warm median TMAC/s |
|---|---:|---:|---:|---:|---:|---:|
| resblocks.3.convs1.0 | 70.93992187 | 0.003094673157 | 0.01328125 | 3.55282221 | 0.01468750 | 3.21265838 |
| resblocks.3.convs2.0 | 71.99225824 | 0.004550933838 | 0.01369792 | 3.44475157 | 0.01411458 | 3.34306149 |

Both timers measure only their convolution, after operand preparation and before
the following handoff. Six invocations were made in the same diagnostic handle;
warm medians use runs 1 through 5, excluding run 0. Rates use the same issued MAC
count as their corresponding timer. Warm runs were slightly slower in this case.
No whole-generator, resident-transport or phone-speaker speed is inferred.

The lock operand matches its own equations at 73.75686728 dB, peak error
0.003663063049. Its distance from stock Snake is 17.34866707 dB; this is the
deliberately different lock setting, not the smoothstep whole-generator stop gate.
All decoded diagnostic outputs were finite.

The partial offline continuation measures 55.86035888 dB against stock, peak error
0.001637995243. This replaces one tested operand block in the offline continuation;
it is not a whole-phone generator result. The older 1,920-position
lock receipt has different conditions and is not a before/after comparison.

Artifact SHA256:
`70C32BB96833E499D47BE5A848A3953A751F597A45917AE343DC4D5C855472A8`.
SDK assembler byte comparison passed for the same 7,248-byte emitted code.
VTCM admission is 1,572,864 bytes. General SDK/API portability is unverified.

Native outputs, `gate.clixml`, `invocation-timings.clixml`, and WAVs are under
`build/generator-templates/lock-warm-both-layers-20261015/`.
`stock-then-template1.wav` is 16-bit mono at 24 kHz, stock first, with a 0.6 s gap.
No whole-generator WAV pairs have been admitted yet.

## Boundary failure and correction

The original 960-position lock layout placed the consumer activation at VTCM
offset 860,160. The phone failed with eight tiles remaining at input offset
1,040,384: the addressed crouton pair crossed 1,048,576. The epilogue had completed,
and its last streamed-table address and the consumer's five arguments matched
their declared layouts. Filtered receipts and native trace outputs are retained
under the ignored `lock-identity-b-*` case directories and emission artifacts.

The existing `docs/generator60x-resident-design.md` correction dated 2026-10-09
reports that simulator fault boundaries occur at 1 MiB, and describes the
`:single` operand as "one tile from two 2 KiB croutons". It cites V81 HMX PRM
80-N2040-62 Rev. AA section 4.4.1 with an explicit V81/V73 qualification.
The layout now keeps each complete HMX activation window within one 1 MiB
region. The failed and corrected phone cases support this admission constraint;
they do not establish a general hardware page-size specification.

Temporary address and progress trace stores were removed before the passing run.
The device harness now retains both convolution timer pairs on every invocation.
The owning application's receipt parser splits multi-line receipt items before
selecting run records. Existing run-0 receipts remain unchanged; they cannot
provide missing warm convolution timers retrospectively.

## Reproduction

From this worktree, choose a fresh output directory:

```powershell
& C:/Dev/Pwsh-Development/tools/board.ps1 Lock -Agent Codex -Reason 'Both layer timers with five warm runs'
try {
    & ./Invoke-KokoroDevelopment.ps1 Run -Case generator-template1 -Runs 6 -Soc SM8550 -Parameters @{
        ConnectedConsumer=$true; Shape='Lock'
    } -OutputDirectory C:/Dev/Kokoro-Hexagon-generator-templates/build/generator-templates/lock-warm-both-layers-recheck
} finally {
    & C:/Dev/Pwsh-Development/tools/board.ps1 Unlock -Agent Codex
}
& ./Invoke-KokoroDevelopment.ps1 Verify
```

The measured command used `lock-warm-both-layers-20261015` as its output directory.
No protected captures, manifests, pins or frozen receipts were modified.
Unrequested product scope: none.
