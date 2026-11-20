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
