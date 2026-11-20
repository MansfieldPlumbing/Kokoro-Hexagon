# Exact packed fractional turns on SM8550

Starting from Kokoroku `0adfc12948b278a4e1dcab333687ebefe3f985f3`, the
`section-snake-packed-fraction` experiment saved **2.379 and 2.505 ms**
against the rebuilt `section-cordic-abs` control. Both trials produced
282,600 reference-identical samples at 24 kHz. The faster primary trial
reached **112.56× DSP realtime**, 6.485 ms over the 98.125 ms budget for 120×.

## Change

Each Snake crouton vector holds two rows. The old kernel shifted the two
phase vectors separately and shuffled their low halfwords. V73
`V6_vasrwh` shifts both vectors and selects those halfwords in one
instruction. The shift counts are six and eight. Sign extension starts
above the retained 16 bits for both counts, so arithmetic and logical
right shifts yield identical retained bits for every phase word. The
non-saturating form preserves the low halfwords and places each row in its
original lane. The scalar loop comparisons use an immediate zero to free
the low register required by the packed shift.

The emitted code is 224 bytes smaller. The activation high and low planes,
HMX products, accumulation order, weight panels, FastRPC invocation and PCM
packing are unchanged.

## Device results

The pinned WinUSB PowerShell ADB client selected one SM8550. The probe
verified the staged ELF and captured PCM, and reported successful startup
restoration in every trial. Each primary trial used one cold and twelve warm
invocations. The second seed used one cold and four warm invocations.
Medians below average the two middle warm samples. The DSP timer runs at
19.2 MHz and 282,600 samples represent 11.775 seconds.

| Trial | DSP median ms | DSP warm range ms | DSP realtime | Host invoke ms | Setup ms | Invoke outside DSP region ms | Output handling ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Candidate A | 104.737 | 103.550–105.585 | 112.42× | 142.618 | 3.092 | 37.623 | 1.249 |
| Control | 107.115 | 105.883–107.574 | 109.93× | 147.148 | 2.874 | 39.990 | 1.287 |
| Candidate B | 104.610 | 103.595–105.003 | 112.56× | 151.712 | 2.807 | 47.174 | 1.253 |
| Candidate, second seed | 104.618 | 103.991–105.018 | 112.55× | 145.825 | 3.821 | 41.178 | 1.445 |

Invoke outside the DSP timed region includes transport and wrapper time.
This probe does not isolate transport from the wrapper. The trials used
the same fixture ABI with PCM-only output capture.

| Artifact | SHA-256 |
| --- | --- |
| Candidate ELF | `7BD56523941A690E55F787EF1236626F078990C12D79FADA9C9A516C8B3B6ED6` |
| Control ELF | `A2F62789957701CDBF08C07A69EAD98A378277D7F1C6EEB591D00F63C282757F` |
| Primary PCM, every run | `B61ACE349E3090D910E1F6E6EB20378FE70F89D38DD421B4C0AF978BFBE1A6BF` |
| Second-seed PCM, every run | `B4DDB8805D48110587F1752F7DC4D7A653BE05EB235FE1D201CE4966DA50B52F` |
| Primary activations | `FCD019515B2968EDAAE8E6EE83A6C80A52F3535B71845CDE1E7CE68B2B2E3870` |
| Second-seed activations | `AFA0D269A83BDC50FDC4AB06F00508D148016E0687878B32C3759AC8BDEE7423` |
| Weights, both seeds | `74FE3CDA2B681588517B85ACED79093A9354FDF12C8F8A80ADFBB530D3AF375A` |
| Tables, both seeds | `0CECC381D7F0FC692CA958C4AC890FD2B32F0DA699A34EF2BA8898B0785985A5` |

The [per-invocation CSV](../../tools/experiments/generator-throughput-20261119/exact-packed-fraction-runs.csv)
includes run zero for each trial. Rebuild both variants with
`New-ExperimentCheckout.ps1` and `Export-ExperimentGenerator.ps1` in that
directory. Invoke `tools/Invoke-GeneratorTailProbe.ps1` using
`-EmissionDirectory`, `-FixtureDirectory`, `-Adb`, `-CapturePcm`,
`-ExpectedPcmSHA256` and `-Runs 13` in candidate/control/candidate order.
Repeat with the second seed and `-Runs 5`. On this host the two fixture
directories were `build/lighthouse-60x-20261119T092441/fixture` and
`build/rt80-1795102334443/second-seed-fixture` under the original checkout.

## Remaining work

The faster historical paired-args test remains ahead of the packed shift
alone. Its original ELF and source were absent from the local build and
archives searched. Earlier main-span instrumentation measured about 14 ms
for activation fill and about 18 ms for HMX plus queue work on an older
instrumented schedule. Those numbers motivate measuring the current fill,
neighbor publication, matrix issue and DMA separately. They cannot
establish current HMX occupancy or a recoverable idle interval.

The [SM8550 HMX reduction probe](hmx-timing-reduction-sm8550-20261113.md)
demonstrates native half-precision multiply and rounding during
accumulation. FP16 also cannot represent every signed 16-bit input. Any
single-plane replacement needs an explicit representability and
accumulation argument before it can compete for the exact-PCM budget.
