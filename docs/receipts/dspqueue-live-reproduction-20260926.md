# Live DSPQueue diagnostic reproduction — 2026-09-26

The historical diagnostic echo script was rerun through the installed
AndroidSMA preview app on the attached Razr+ 2024 and S23. This was a
diagnostic investigation only, not Kokoro synthesis or a product transport
test. The runner backed up and restored each app's startup scripts and prior
receipt byte-for-byte after each attempt.

The first Razr+ attempt created and exported a queue, but could not open its
custom DSP skeleton because that artifact was absent from the diagnostic
app's private library directory. A byte-identical copy of the S23 diagnostic
app's archived skeleton was then staged to the Razr+ diagnostic app and
verified by SHA-256. This binary's source is not in the current repository;
it was neither inspected nor admitted to the production build. The generated
transfer copy is in git-ignored `build/diagnostics/`. The diagnostic-app copy
remains on the Razr+; it was not present before this test.

| Gate | Razr+ with recovered skeleton | S23 with existing skeleton |
| --- | --- | --- |
| Unsigned PD, queue create/export | Pass | Pass |
| Skeleton open and queue import/start | Pass | Pass |
| First queue write | Success (script reached read) | Success (script reached read) |
| First response read | Error 12 | Error 12 |
| Recovery status | 0 packets received; DSP error 14 | 0 packets received; DSP error 14 |
| Startup scripts and prior receipt restored | Yes | Yes |

The pinned Qualcomm [error definitions](https://github.com/qualcomm/fastrpc/blob/d247519650fe5cb16de6c78edaa95bcc4be25073/inc/AEEStdErr.h#L41-L43)
name 12 `AEE_EEXPIRED` and 14 `AEE_EBADPARM`. Its
[CPU queue reader](https://github.com/qualcomm/fastrpc/blob/d247519650fe5cb16de6c78edaa95bcc4be25073/src/dspqueue/dspqueue_cpu.c#L2271-L2347)
passes a read timeout to `wait_signal_locked`, which maps expiration to 12.
That explains the host-side read result but does not identify why the custom
worker reports 14.

The two archived echo scripts differ overall, but their queue creation,
worker start, and first 32-packet echo-loop source blocks are byte-identical.
Their older stored receipts passed, so the current failure is a regression
relative to those records, not proof that either chipset lacks the queue.
The reported ~0.1 ms round trip was **not reproduced with the archived
binary**: no packet completed in that phase, so it produced no latency sample.

Do not infer the worker error's cause from Antigravity's candidate kernel
sources: the installed kernels do not match those revisions, and both phones
reach the same application-level worker failure.

## Source recovery and source-matched rerun

A one-time, read-only inspection of the exact diagnostic source and build
script in the separate Antigravity checkout located the authored worker at
`src/kernels/queue-echo/echo.c` and its build script at
`tools/Build-DspQueueEchoProbe.ps1`, commit
`85b20cc80570c20c53d2ca1c43dc03a66aae08ae`. Both files match that
commit. The pinned SDK 6.4.0.2 build script verified its tool and header
digests and emitted a fresh diagnostic worker into this repository's ignored
`build/diagnostics/`; it made no changes to the Antigravity checkout. The
new library has the same byte length as, but a different digest from, the
archived installed library. Binary contents were not inspected.

The source shows that status error 14 can come from the callback error
argument before any packet is received. It does not establish why the
archived binary took that path. Replacing the worker temporarily with the
fresh source-built artifact, while retaining and then restoring the original
worker on each phone, produced these same-session results:

| Source-built worker | Razr+ 2024 | S23 |
| --- | ---: | ---: |
| Queue packets completed | 32 | 32 |
| Warm queue round-trip median | 120.364 µs | 283.907 µs |
| Warm queue round-trip p95 | 163.177 µs | 354.948 µs |
| Warm queue write median | 56.823 µs | 12.969 µs |
| Warm queue read median | 62.708 µs | 270.990 µs |
| Poll-mode warm median | 152.135 µs | 249.062 µs |
| Poll read attempts median | 1 | 24 |
| Synchronous-invoke warm median | 230.000 µs | 347.709 µs |
| DSP received / error | 64 / 0 | 64 / 0 |
| Diagnostic passed | Yes | Yes |
| Prior worker and app state restored | Yes | Yes |

This reproduces an approximately 0.1 ms diagnostic queue round trip on the
Razr+ (measured 0.120 ms in this run), not a 0.100 ms exact figure or Kokoro
speech. The identical freshly built worker completes on both devices. The
S23 response-read interval is much longer, but the receipt alone does not
identify whether DSP execution, queue signaling, scheduler behavior, or
another factor accounts for it. No per-packet explicit FastRPC invoke occurs
in the PowerShell packet loop; library-internal signaling remains unmeasured.
