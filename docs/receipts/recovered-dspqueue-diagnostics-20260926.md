# Recovered device DSPQueue diagnostics — 2026-09-26

Read-only inspection of the two installed diagnostic-app private directories
found authored PowerShell `DspQueueProbe.ps1`, `DspQueueEchoProbe.ps1`, and
`DspQueueAudioShellProbe.ps1` with receipts on both phones. These scripts and
their DSP skeleton are not checked into this repository. No diagnostic was
rerun, no package was changed, and no vendor binary was inspected.

The echo script creates and exports a DSPQueue, opens a custom DSP skeleton,
and invokes its queue-import entry once. Its packet loop then calls
`dspqueue_write` and `dspqueue_read` rather than explicitly calling
`remote_handle64_invoke` per packet. The script still loads
`libcdsprpc.so`, uses a QNN-named delegate helper, and uses managed Android
types. The historical diagnostic is not the product transport; zero
*explicit* remote invokes in its packet loop does not prove that the
DSPQueue library makes zero FastRPC ioctls or signals internally.

| Historical echo receipt | S23 | Razr+ 2024 |
| --- | ---: | ---: |
| Queue packets | 32 | 32 |
| Queue warm median | 283.282 µs | 141.406 µs |
| Synchronous-invoke warm median | 343.229 µs | 274.323 µs |
| Within-device median ratio | 1.21x | 1.94x |
| Explicit remote invokes in queue packet loop | 0 | 0 |
| Receipt passed | Yes | Yes |

The two stored echo scripts are different revisions (295 versus 261 lines).
Their medians are within-device comparisons, not a controlled cross-device
speed comparison. The owner's earlier account of an S23 failure may refer
to an earlier attempt or a different test; its failing stage was not found
in the inspected current receipts.

The separate audio-shell probe has the same normalized script text on both
devices and reports 100 ordered packets and 24,000 output frames from a
fixed-state synthetic oscillator, explicitly **not Kokoro**. Both stored
receipts report completion. S23 reports zero AAudio xruns; Razr+ reports 88.
The script's `Passed` predicate does not require `UnderrunFree`, so neither
receipt establishes glitch-free playback on both phones or live speech.

This recovery establishes that the diagnostic queue creation, export,
custom-skeleton import, and echo loop reached successful receipt states on
both phones. It does not establish a QNN-free, vendor-library-free appliance,
an owned queue implementation, or a same-artifact emitted worker in this repo.
