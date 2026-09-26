# DSPQueue capability comparison — 2026-09-26

This is a reference-only probe through the installed AndroidSMA diagnostic
app, not Kokoro synthesis or an owned product transport. Both attached phones
ran the same PowerShell source from
`tools/reference/dspqueue-echo/Get-DspQueueCapabilities.ps1`. The source
created a CDSP queue, read `DSPQUEUE_STAT_SIGNALING_PERF`, and closed it;
it did not load an echo worker or send packets. The statistic number and
levels come from the SHA-256-pinned Hexagon SDK 6.4.0.2 `incs/dspqueue.h`
used by `tools/reference/dspqueue-echo/Build-DspQueueEchoProbe.ps1`.

| Gate | Razr+ 2024 | S23 |
| --- | ---: | ---: |
| Unsigned PD / queue create | 0 / 0 | 0 / 0 |
| Signaling-performance query result | 0 | 0 |
| Signaling-performance level | 1000 | 1000 |
| Queue close | 0 | 0 |
| Probe passed | Yes | Yes |
| Prior startup scripts and receipt restored | Yes | Yes |

The SDK calls level 1000 optimized signaling. Equal values rule out a
different **reported signaling-performance level** as the explanation for
the observed median split; they do not establish that the phones selected
the same driver-signaling branch or that their firmware/host scheduling is
equivalent. A separate `fastrpc_get_cap` attempt was unavailable through
this diagnostic binding on both phones, so no DSP/driver capability value
was recorded. The temporary probe source was removed from both apps after
the run.

Repeatable gate (the runner stages the probe, verifies its digest, restores
the prior startup scripts and receipt, and removes the probe):

```powershell
pwsh -NoProfile -File tools/reference/Invoke-DspQueueCapabilityProbe.ps1 -Device Razr
pwsh -NoProfile -File tools/reference/Invoke-DspQueueCapabilityProbe.ps1 -Device S23
```

Both commands passed in a subsequent rerun with the same reported level.
The PowerShell sources parsed without errors, `tools/Test-DspQueueLayout.ps1`
passed, and `git diff --check` was clean.

The preceding identical fresh-worker echo receipt measured 120.364 µs on
Razr+ and 283.907 µs on S23, with the larger S23 interval in response read.
Poll-mode medians were 152.135 µs and 249.062 µs, respectively. This suggests
that host blocking-wakeup overhead alone cannot explain the entire gap,
but it does not locate whether DSP execution, response-queue publication,
polling cadence, or host scheduling first diverges. The next attribution
gate is same-artifact phase timing around response availability and an
unambiguous source-defined readout of the actual signaling branch.

No QNN API was used by this probe. The diagnostic still loads
`libcdsprpc.so` and a historical QNN-named delegate factory; neither is
promoted to the product closure by this result.
