# Exact lockstep publication and HMX group loops on SM8550

The best primary warm median was **99.868 ms**, or **117.91× DSP
realtime**, leaving 1.743 ms to the 98.125 ms budget for 120×. The repeat
took 100.955 ms. The comparison started at local commit
`005b2d66be53542530c19d48f888a5bde29cf305` and used the same SM8550,
pinned WinUSB PowerShell ADB client and 24 kHz lighthouse fixture.

## Publication fence

The lockstep controller already waits for its neighbor and executes
`syncht` before acquiring the matrix lock. Lock acquisition does not
write the caller's activation window. This variant uses that existing
barrier for the writes preceding the progress publication. It retains
the progress store after acquiring the lock, and the fences around
convolution consumption and combine. Emitted code shrank by 2,784 bytes.

Primary warm medians were 100.641 / 101.365 / 101.367 ms in
candidate/control/candidate order. Seed two measured 100.661 ms. Both
seeds matched their PCM references, and the repeat tied the
control, leaving the standalone timing effect inconclusive. This
variant is the control for the HMX group-loop comparison. Its ELF
SHA-256 is
`E858076D564C9BCDE3949C143900F23B50F7D736BC28CEA0BDEF6511E8B3AD61`.
[Per-invocation fence comparison](../../tools/experiments/generator-throughput-20261119/exact-publication-fence-runs.csv).

## HMX output-group hardware loop

The compact HMX convolution body holds the number of output groups
in hardware loop 0. It no longer saves and reloads a scalar group
counter or emits a decrement, comparison and branch after each group.
The loop-end packet advances the table and output bases. Weight
panel order, accumulator clears, numeric stores and tile traversal
are unchanged.

| Trial | Warm DSP median ms | Warm DSP range ms | DSP realtime | Host invoke ms | Host setup ms | Invoke outside region ms | Output handling ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Candidate A | 99.868 | 99.515–101.453 | 117.91× | 135.453 | 2.903 | 35.262 | 1.330 |
| One-fence control | 101.277 | 99.698–101.929 | 116.27× | 135.132 | 3.007 | 33.899 | 1.350 |
| Candidate B | 100.955 | 99.422–102.458 | 116.64× | 136.569 | 2.875 | 34.896 | 1.400 |
| Candidate, second seed | 101.433 | 100.138–102.206 | 116.09× | 134.357 | 3.257 | 32.924 | 1.892 |

Both primary candidate medians led the control, by 1.409 and 0.322 ms.
The warm ranges overlapped. The combined ELF SHA-256 was
`2E0B824CA8F9496035F4FD1780F674F1486314DEC3550327CB5B73742530D340`.
Each primary arm used one cold and twelve warm runs. The second seed
used one cold and four warm runs. Every invocation returned 282,600
samples at 24 kHz, and every trial verified startup restoration.

- Primary PCM `B61ACE349E3090D910E1F6E6EB20378FE70F89D38DD421B4C0AF978BFBE1A6BF`
- Second seed `B4DDB8805D48110587F1752F7DC4D7A653BE05EB235FE1D201CE4966DA50B52F`

Rebuild `section-hmx-group-loop` and `section-one-publication-fence`
with the existing experiment checkout and export tools. Follow the
[fixture instructions](generator-exact-packed-fraction-sm8550-20261120.md)
to capture both seeds. The
[per-invocation HMX comparison](../../tools/experiments/generator-throughput-20261119/exact-hmx-group-loop-runs.csv)
includes cold runs, independent host timings, and ELF and PCM checks.

## Branch-zero readiness in the chunked section

The `section-branch-ready-trace` diagnostic samples block 8, stage 0 of
the 256-channel main section. It records a tick after each worker fences
both branch-zero windows and another when the worker returns from its
last fill. The controller records the completion of its join and its
arrival at HMX setup after the weight DMA wait. This diagnostic inserts
one barrier per worker after branch zero and emits the sampled interior
block outside the loop. Its timings describe the instrumented path.

| Interval in the cold capture | Time |
| --- | ---: |
| Last branch-zero fenced window to last fill return | 7.552 µs |
| Last fill return to join complete | 0.156 µs |
| Join complete to HMX setup after DMA wait | 0.208 µs |
| Last branch-zero fenced window to HMX setup | 7.917 µs |

The diagnostic ELF SHA-256 was
`8B3797D8A97CA0B61CAA84078BDC71FE5DD8FB0B5011964B884EC047F1791AF9`.
The probe returned exact PCM and restored startup. Rebuild the trace
variant and omit `-CapturePcm` to retrieve run zero's buffer. Its
little-endian uint32 at byte 48 points to the record. The first 64
bytes contain four pairs of uint64 ticks, ordered by worker and then
by timestamp. The next 16 bytes contain the join and HMX setup ticks.
Subtract the job's start tick at byte zero to reproduce the
[worker](../../tools/experiments/generator-throughput-20261119/branch-ready-worker-times.csv)
and [controller readings](../../tools/experiments/generator-throughput-20261119/branch-ready-controller-times.csv).
The 7.917 µs is a local interval before first convolution setup.
It cannot determine when the weight DMA would have completed under
earlier issue, or how much overlap is available across the whole section.

## Short screens

All these screens retained exact primary-seed PCM and restored startup.
The medians are from four warm invocations and have no intervening control.

| Candidate | DSP median ms |
| --- | ---: |
| Fuse the fill pointer advances into its loop-end packet | 101.179 |
| Add HMX group loops directly to the combine-loop baseline | 100.540 |
| Keep independent pointers for both pairs of combine planes | 101.432 |
| Specialize AdaIN/Snake fill for one tile | 101.556 |
| Specialize lockstep HMX calls for one tile on the group-loop variant | 100.634 |

The first, third, fourth and fifth screens gave no clear incremental
gain. The [screening receipts](../../tools/experiments/generator-throughput-20261119/exact-publication-hmx-screening-runs.csv)
record both hashes and cold run zero.

## Early HMX issue for branch zero

The `section-early-branch-zero` experiment starts the first convolution
after each worker fences its branch-zero tile and after the weight DMA
wait. The controller fills branch zero before issuing HMX. Workers 1
and 2 finish the controller's branch 1 and 2 fills in addition to their
own, while worker 3 finishes its own tile. The join and the publication
barrier still precede HMX reads of branches 1 and 2. The early path
applies only to interior blocks of the four-thread, 256-channel
three-branch chunked section with asynchronous weights.

The candidate ELF SHA-256 was
`EC859D987734AF4AAEA56844127084314357E8D3E3C4AFF594AE44617FA3B53E`.
The primary screen matched reference PCM and measured 100.714 ms over
four warm runs.

The full primary comparison measured **100.430 / 100.309 / 100.269 ms**
in candidate/control/candidate order. The second seed took 101.193 ms.
Every run was exact and every trial restored startup. The primary
medians straddled the fresh HMX group-loop control, so this particular
overlap schedule has no confirmed speed gain.
[Per-invocation results](../../tools/experiments/generator-throughput-20261119/exact-early-branch-zero-runs.csv).

The remaining 1.743 ms in the best group-loop trial is DSP time. The
sampled readiness interval is measurable, and starting the first HMX
call there preserved PCM. Recovering time there depends on the cost
of readiness polling, the finish time of the workers with an extra
tile branch, and any contention while HMX and HVX execute together.
The elapsed comparison does not assign costs among those effects.

## Aligned activation panel span

The `section-aligned-panel-span` experiment replaces the four
128-channel input-panel issues of an aligned tap with one pair using
the existing `activation.ub` and `weight.b :deep` forms and an
8 KiB range. The other taps keep the existing `:single` reads.
This tests which panels that particular paired instruction consumes.
It retains both accumulator windows and their output and combine code.

The SM8550 candidate completed its first DSP region but failed the
primary PCM check. The probe stopped before playback and verified
startup restoration. The candidate ELF SHA-256 was
`682DC480FDE47ABDC24042F69C48A8F46F4AEF0BFDBA77E834AAEDBD65868258`.
There is no qualifying warm measurement for this variant. The fresh
managed resident control matched the reference at **101.849 ms DSP**
and **104.138 ms host invoke** over twelve warm runs. The 125× target
is 94.200 ms for 11.775 seconds of audio. Receipts are under
`build/residual-layout-20261120` with the `aligned-range` and
`target125-control` prefixes.

The failure leaves the operand range and weight pairing semantics
unresolved. For a standalone follow-up, populate each input panel and
both output halves with different values. Compare the reference
`:single` issue sequence against candidate issue forms before
changing the generator. Probe a wrapped activation window and dense
64-row `:cm` packing independently, with both conversions checked.

## SM8550 operand and worker timeline follow-up

The [standalone V73 probe](../../tools/experiments/generator-throughput-20261119/Invoke-V73OperandProbe.ps1)
uses four distinct activation panels and sparse weights with different
coefficients in each output half. The four individual `:single` issues
and their accumulated sum matched the scalar oracle for all 2,048
output lanes. The probe recovers both accumulator halves with the
generator's retained high-byte and releasing low-byte stores. Neither
half saturates in this fixture.

- A single `activation.ub` / `weight.b :deep` pair with 2, 4 or 8 KiB
  ranges produced panel zero alone in both halves. Extending the range
  on the `:single` weight operand also produced panel zero alone.
  This accounts for the aligned-span PCM failure. Three dot-product
  contributions were missing from each affected tap.
- Plain `weight.b` gave panel zero in the first half and left the
  second half at its bias-only value at all three ranges.
- The 16-row shifted ring read matched the physically contiguous
  poison continuation in both halves. The explicitly packed logical
  wrap gave different results. The unmodified `:single` operand
  therefore needs the mirrored data when crossing this ring boundary.

The [raw-window comparison](../../tools/experiments/generator-throughput-20261119/v73-operand-windows.csv)
records both half digests. The probe ELF was
`C960AA2DE6F62A64BDCEFBBEABED87C2C6A1D4C53CA2B2BC5E455A4A62FFE1E2`.
Dense `:cm` received no speed credit. A valid comparison still needs
shifted 64-row input preparation and exact writeback for both windows.

The [worker timeline variant](../../tools/experiments/generator-throughput-20261119/section-worker-timeline.patch)
records the last observed stage per worker in each backward section.
Activation ready is after the neighbor dependency and publication fence.
First issue is sampled immediately before the first HMX pair. Last
result visible is confirmed by reading the final wrapping-plane word
after unlock, so that interval includes unlock and the confirmation
load. The combine marker follows a fence. These are instrumented
snapshots from one invocation. The chunked Main256 section is outside
this trace.

| Backward section | Fill start to ready µs | Ready to lock µs | Lock to first issue µs | First issue to visible µs | Visible to combine complete µs |
| --- | ---: | ---: | ---: | ---: | ---: |
| Main128 | 14.349 | 1.536 | 0.182 | 2.656 | 2.188 |
| Source256 | 6.068 | 0.625 | 0.104 | 3.021 | 1.875 |
| Source128 | 6.849 | 1.016 | 0.052 | 1.458 | 0.964 |

The table gives per-section medians over 24 worker-stage records.
The [tick capture](../../tools/experiments/generator-throughput-20261119/worker-timeline-ticks.csv)
contains the individual timelines. Build `section-worker-timeline`
with the experiment checkout and resident export scripts, then run
the managed fixture probe once with raw output capture. Extract the
records with
[read-worker-timeline.py](../../tools/experiments/generator-throughput-20261119/read-worker-timeline.py).
The trace ELF `CB68C246D22BE9981DE703905FB8EA3BF51B7A5D8A20A55C9E0C2CA590CB3FD9`
matched primary PCM and restored startup.

The fresh direct-copy managed control
`388F24CB7B96E00975AF97E2A3E6ED438E112722ECFE79F631A3B042B9FD6737`
matched the reference on all 18 invocations across both seeds.
Both sessions restored startup. The 125× and 130× DSP budgets are
94.200 ms and 90.577 ms.

| Control seed | Warm runs | DSP median ms | Host invoke median ms | DSP realtime |
| --- | ---: | ---: | ---: | ---: |
| Primary | 12 | 102.020 | 104.172 | 115.42× |
| Second | 4 | 101.579 | 103.803 | 115.92× |

Phone access used `C:/Dev/pwsh/scripts/adb.ps1`. Raw artifacts are under
`build/residual-layout-20261120`, with `operand-probe`,
`operand-fresh-control` and `worker-timeline` prefixes.
