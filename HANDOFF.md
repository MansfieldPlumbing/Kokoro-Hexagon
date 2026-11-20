# Current handoff — 2026-11-19, tools down

Resume at local main ed913f1. GitHub main was last verified at ac510b0. The three local commits are 4328e37 (direct calls), 776623d (HVX shift-accumulate), and ed913f1 (exact spectral CORDIC absolute value). The user requested local commits only after the push was denied. This handoff is intentionally untracked.

The latest exact candidate, section-cordic-abs, measured 107.132 and 106.787 ms (109.91× and 110.27× DSP realtime) around a 107.837 ms shift-accumulate control. One of the two medians cleared 110×. Both candidate trials matched the complete reference PCM on all 26 invocations. All five second-seed invocations matched their separate reference. For 11.775 seconds of valid audio, 120× requires 98.125 ms, another 8.66–9.01 ms. These timings cover 24 kHz PCM. The proposed fourth phase has no learned weights and would emit native 48 kHz Opus with procedural air. It has no qualified throughput measurement.

Use pwsh and C:/dev/pwsh/scripts/adb.ps1 exclusively for phone access. The experiment is a patch chain rather than the default emitter. Use tools/experiments/generator-throughput-20261119/New-ExperimentCheckout.ps1 with -Variant section-cordic-abs and a new destination, then Export-ExperimentGenerator.ps1. Expected library SHA-256 is A2F62789957701CDBF08C07A69EAD98A378277D7F1C6EEB591D00F63C282757F. Existing binary is build/rt80-1795102334443/shift-abs120. Its matching experimental source directory is shift-cordic120-src. Use the tracked variant name for a fresh reproduction.

[Comparison](build/rt80-1795102334443/confirm-shift-abs120-174049/summary.txt) · [Second seed](build/rt80-1795102334443/shift-abs120-seed2/phone.log) · [Tracked report and reproduction instructions](docs/results/generator-depth-first-throughput-sm8550-20261119.md)

The spectral gain came from replacing sign-mask XOR and subtraction on the shifted y operand with non-saturating vector absolute value. Enabling general word-subtraction packetization separately changed the reference hash to ED816B96…; its timing is invalid for this contract. The earlier 3+7 / 11 HMX ownership split slowed the workload. On resumption, use shift-abs120 as the control and profile the current candidate by stage before attributing the remaining gap to HMX. Keep all publication fences and the final waveform check when exploring tile ownership or dispatch fusion.

---

## Historical SM8550 generator handoff — 2026-11-19

## Where to resume

Local main is at 1ebca4f. The measured workload is the whole Kokoro generator with computed harmonic source, stock seeded noise, and PCM output. It produces 282,600 samples at 24 kHz, or 11.775 seconds of audio. DSP real-time factor is 11,775 divided by warm median DSP milliseconds. Host invocation time is measured separately. The targets of 110×, 116×, and 120× require 107.05, 101.51, and 98.13 ms respectively.

## Latest verified change

The source noise convolutions add a scaled convolution result to an initially zero residual. Commit 1ebca4f writes the scaled result directly, preserving Q15 rounding, saturation and output bias. It removes the zero fill and the subsequent residual read and add. The prior release is e7eb9db. Earlier milestones are 4697cc3 (90×) and 19e3fbd (81×).

| Trial | Warm median DSP ms | DSP real-time factor | Host median ms |
|---|---:|---:|---:|
| Candidate A | 115.404 | 102.03× | 158.304 |
| Prior release | 116.039 | 101.47× | 149.737 |
| Candidate B | 114.534 | 102.81× | 147.521 |

Each trial used one cold and twelve warm invocations. Both candidate trials matched reference PCM. Five additional runs matched the second seed. The host medians varied in both directions.

## Reproduce and inspect

Use pwsh on the Windows host and C:/dev/pwsh/scripts/adb.ps1 for every phone operation. The archive contains the checkout, Git history and local build directory. From the repository root, the existing qualified binaries and fixtures can be retested with:

```powershell
$d = (Resolve-Path build/rt80-1795102334443).Path
& "$d/Confirm90.ps1" -Candidate zero-source -Control release100-qualified
```

The harness uses SM8550, 56,521 frames, four-tile batches, four HVX threads, 120-tile spans, one weight plane, resident source channels 128 and 256, asynchronous weights, host coefficients, and vector packets. It checks the emitted library hash and the hash of the full PCM. See [comparison](build/rt80-1795102334443/confirm-zero-source-121348/summary.txt), [second seed](build/rt80-1795102334443/zero-source-seed2/phone.log), and [emission settings](build/rt80-1795102334443/Span90.ps1).

## Open experiment

The release alternates sections within a span and saves section state to DDR between visits. Two experiments reordered the work to keep a section in VTCM across the utterance. Both produced the same incorrect PCM hash beginning 720D5468. One ran each section in a single pass. The other retained the original section segment boundaries. Both are unqualified. The experimental source directory currently holds the segmented variant. Start diagnosis by comparing the first differing tensor with the release at the noise convolution, source residual section, front and main section handoffs. Check DDR lifetimes, offsets and emitted step counts before attributing the error to hardware. [Single-pass receipt](build/rt80-1795102334443/utterance-section/phone.log) and [segmented receipt](build/rt80-1795102334443/utterance-section-segments/phone.log).

A four-pair HMX burst straddled the control across two trials. An exact 64 KiB Snake lookup matched PCM but took 120.81 ms versus 116.10 ms for the polynomial. Keep the three-pair and polynomial paths as controls. HMX operand dependencies can be reconstructed from VTCM addresses, while internal fetch timing and systolic behavior remain unverified. A procedural fourth output phase and native Opus remain separate, unmeasured output contracts. [HMX trials](build/rt80-1795102334443/confirm-hmx4-116-115952/summary.txt) and [lookup receipt](build/rt80-1795102334443/lookup116/phone.log).
