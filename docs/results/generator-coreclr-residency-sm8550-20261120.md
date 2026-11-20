# CoreCLR resident generator and exact DSP screens on SM8550

The measured DSP source is `section-hmx-group-loop` from local
`de4e6ca03400abf573c2f301933376a5f3f87b8c`, whose fastest primary
confirmation median was 99.868 ms. The trials used the same SM8550,
the pinned WinUSB PowerShell ADB client and the 282,600-sample, 24 kHz
lighthouse fixture. Remote main remained at `0adfc12` when fetched.

## Managed assembly and shared workspace

The CoreCLR runspace opens the generator program, weights, tables and
layout from the managed `Kokoroku.dll`. It materializes the ELF once
under a unique session name. The two immutable resource streams each
populate one native shared payload with a static FastRPC mapping.
The session keeps the FastRPC handle and both mappings across warm calls.
The output workspace uses one 123,560,128-byte shared allocation. The
runspace copies a 1,024-byte header and 565,200 PCM bytes and returns
only PCM to the workstation probe. The benchmark still clears the
workspace between invocations to preserve the fixture's reset behavior.

The managed, resident and shared changes are measured together against
the raw fixture ABI. Both use the same DSP job, with a resident entry
adapter in the managed arms. Thus the difference quantifies the combined
delivery path and does not separately attribute savings to CLR loading,
payload mapping or output allocation.

| Trial | Warm DSP median ms | DSP warm range ms | Host invoke ms | Host setup ms | Invoke outside DSP region ms | Output handling ms | Host setup + invoke + output ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Managed A | 100.937 | 99.960–101.865 | 103.374 | 5.103 | 2.427 | 2.618 | 111.58 |
| Raw fixture control | 100.910 | 99.663–101.468 | 139.338 | 2.835 | 38.486 | 1.070 | 144.31 |
| Managed B | 100.745 | 100.256–101.024 | 103.246 | 4.632 | 2.397 | 1.912 | 110.47 |
| Managed, second seed | 100.979 | 100.827–101.762 | 104.259 | 4.950 | 2.813 | 4.329 | 113.17 |

The host total is the median of each invocation's summed intervals.
It excludes deployment, one-time mapping and playback. Host invocation
fell by 35.964 and 36.092 ms. The summed host intervals fell by about
33 ms. The DSP medians straddled the control, so the delivery path
does not establish a DSP speed gain.

Assembly preparation took 48.585 / 44.729 / 43.307 ms across the two
primary managed sessions and second seed. The two static payload
mappings took 87.017 / 83.747 / 74.040 ms once per session and both
unmaps succeeded each time. Warm managed skel entry-to-region and
region-to-return measurements were about 0.27–0.32 and 0.13–0.15 ms
respectively. Invoke time outside the DSP region includes those
intervals as well as the runtime and transport boundary.

The probe verified the managed ELF loaded on the phone, exact PCM on
all 44 runs, sample count and startup restoration on every trial.
Primary arms used one cold and twelve warm invocations. The second
seed used one cold and four warm invocations.

| Artifact | SHA-256 |
| --- | --- |
| Managed assembly | `86019637D11CBC1B9A7E58A9247C3359D5E1977299DFCD72C33127B8D96DA157` |
| Resident ELF | `388F24CB7B96E00975AF97E2A3E6ED438E112722ECFE79F631A3B042B9FD6737` |
| Raw control ELF | `2E0B824CA8F9496035F4FD1780F674F1486314DEC3550327CB5B73742530D340` |
| Primary PCM | `B61ACE349E3090D910E1F6E6EB20378FE70F89D38DD421B4C0AF978BFBE1A6BF` |
| Second seed PCM | `B4DDB8805D48110587F1752F7DC4D7A653BE05EB235FE1D201CE4966DA50B52F` |

Rebuild `section-hmx-group-loop` with `Export-ExperimentGenerator.ps1`
both with and without `-ResidentPayloads`. Package the resident export
with `New-ManagedGeneratorAssembly.ps1` and the primary fixture. Run
`tools/Invoke-GeneratorTailProbe.ps1` with `-GeneratorAssembly`,
`-ResidentPayloads`, `-SharedWorkspace` and `-CapturePcm`. The raw
control uses the normal export directory and `-CapturePcm` alone.
Reuse the same package for the second-seed fixture, whose immutable
weights and tables match the primary fixture. The
[per-invocation comparison](../../tools/experiments/generator-throughput-20261119/exact-coreclr-residency-runs.csv)
includes cold runs and verified ELF and PCM hashes.

## DSP history and addressing screens

Shortening the compact HMX group's address setup preserved PCM and
measured 101.342 ms. Moving early-branch readiness flags to unused
VTCM moments space under host coefficients also preserved PCM and
measured 100.842 ms. These screens gave no clear gains.

The history experiment mirrors the trailing crouton writes from
AdaIN/Snake during interior blocks. The high and low plane mirror
deltas are independent. Boundary blocks keep their post-padding
copy path. The first variant makes each writer restore the same
slot before overwriting it. This preserves read/write order, but
shifts all restoration onto the two trailing workers. Its exact
screen ran at 101.652 ms.

The second variant alternates two history banks by block parity.
The second bank packs only the preceding tiles each branch and
stage needs. Balanced restoration reads the old bank while the
trailing workers write the new one. Both edge and interior blocks
advance bank ownership, including span boundaries. This preserves
the original activation and convolution arithmetic. The exact short
screen measured 100.321 ms. The candidate ELF SHA-256 was
`C02A97CDD4816AEF3E5FE5DA668057A0C143DD282E81926DDB6FB1F164C8F9EF`.
The [four-warm screening data](../../tools/experiments/generator-throughput-20261119/exact-history-screening-runs.csv)
records the ELF hashes, exact PCM and verified startup restoration.

The full history-bank comparison measured **101.255 / 100.309 /
102.220 ms** in candidate/control/candidate order. The second seed
measured 101.958 ms. Both candidates were slower than the fresh
control despite the favorable short screen. All 44 invocations
matched their reference PCM, verified the staged ELF and restored
startup. [Per-run history-bank timing and host overhead](../../tools/experiments/generator-throughput-20261119/exact-history-banks-runs.csv).

The 99.868 ms HMX group-loop checkpoint remains the fastest qualified
primary result. It exceeds the 98.125 ms exact-PCM target by 1.743 ms.
The resident assembly is a verified host-side latency improvement
for that job. Direct history stores, even with balanced restoration
and separate banks, did not recover DSP time on this schedule.

## Direct manifest resource copy

The managed resident probe now copies a memory-backed manifest resource
directly to its FastRPC allocation. The probe keeps the stream open
through the native copy and retains the buffered path for other stream
types or runtimes without dynamic code. FastRPC maps the allocations
once and the DSP reads the same packed weight and table bytes.

The resident ELF stayed at `388F24CB7B96E00975AF97E2A3E6ED438E112722ECFE79F631A3B042B9FD6737`.
Each trial below used one cold invocation and four warm invocations.
Both seeds matched their reference PCM and startup restoration passed.

| Trial | One-time copy and map ms | Warm DSP median ms | Warm host invoke median ms |
| --- | ---: | ---: | ---: |
| Direct A | 87.328 | 101.583 | 104.678 |
| Buffered control | 106.165 | 101.684 | 104.663 |
| Direct B | 71.879 | 101.737 | 104.698 |
| Direct, second seed | 190.977 | 101.807 | 104.502 |

The two primary direct trials saved 18.837 and 34.286 ms in the combined
startup interval. That interval includes allocation, copy, and static
mapping. The second seed shows the variability of the cold interval.
The warm medians were close with the same DSP program.
Receipts are under `build/residual-layout-20261120` with the
`direct-resource` prefix.

The tracked implementation was also run with both seeds. Ten additional
invocations verified the direct copy for both resources, the expected
PCM, and startup restoration. These receipts use the `direct-integrated`
prefix.
