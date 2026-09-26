# Same-session CDSP interface inventory — 2026-09-26

A read-only ADB check reached both installed devices in one session. No APK
was installed, no app process was started, and no DSP job was invoked. Only
source-named `/dev/fastrpc-*` and `/dev/*dsprpc*` paths were listed.
The installed `dev.mansfieldplumbing.kokorohexagon` base APK was readable
on both devices and its SHA-256 matched across them. This establishes a
same-base-APK comparison, not a shared model or queue-test artifact.

| Device | Android | Kernel base | Observed RPC nodes |
| --- | --- | --- | --- |
| Galaxy S23, SM8550 | 16 | 5.15.189 | `/dev/adsprpc-smd`; `/dev/adsprpc-smd-secure` |
| Razr+ 2024, SM8635 | 16 | 6.1.145 | `/dev/adsprpc-smd`; `/dev/adsprpc-smd-secure` |

On both devices, the first node was mode `0664`, owned by `system:system`,
and labeled `vendor_qdsp_device`; the secure node was mode `0644`, also
`system:system`, and labeled `vendor_xdsp_device`. Neither queried path set
contained a CDSP-named node. The external report's proposed 5.15.208 and
6.1.57 kernel revisions are not exact matches to these installed kernels.

This inventory does not establish app access, a CDSP queue capability, or
the cause of the owner's reported Razr+ success and S23 failure. Node
similarity does not imply firmware or signaling equivalence. The separate
app-context raw-open probe remains a failed ADSP-node probe.

A search of the tracked PowerShell sources and their Git history found no
DSPQueue smoke-test implementation in this checkout. The earlier
`kokoro-affine-emitted-20260923.md` receipt calls DSPQueue a candidate based
on an SDK header; it does not report a device queue execution.
