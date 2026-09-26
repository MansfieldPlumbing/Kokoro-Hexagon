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
worker reports 14. The worker's source is needed for that diagnosis.

The two archived echo scripts differ overall, but their queue creation,
worker start, and first 32-packet echo-loop source blocks are byte-identical.
Their older stored receipts passed, so the current failure is a regression
relative to those records, not proof that either chipset lacks the queue.
The reported ~0.1 ms round trip was **not reproduced** in this live session:
no packet completed, so no latency measurement exists to report.

Do not infer the worker error's cause from Antigravity's candidate kernel
sources: the installed kernels do not match those revisions, and both phones
reach the same application-level worker failure. The next evidence gate is
the authored DSP skeleton source and exact build recipe, followed by a
source-matched rebuild and identical artifact run on both devices.
