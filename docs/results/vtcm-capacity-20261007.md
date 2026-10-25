# VTCM capacity on SM8550 and SM8635 — 2026-10-07

Emitted skel `src/emit/Kokoro.VtcmQueryProbe.ps1` (instruction bytes match the pinned
`hexagon-llvm-mc`, SHA-256 `fc64c65a…`), run by `tools/Invoke-VtcmQueryProbe.ps1`.
For each application ID it calls `compute_resource_query_VTCM`, votes HVX, DCVS and HMX
power, then acquires the whole reported partition with HMX
(`compute_resource_attr_set_app_type`, `..._set_vtcm_param_v2`, `..._set_hmx_param`,
`compute_resource_acquire`) and records what `compute_resource_attr_get_vtcm_ptr_v2`
returns. Base commit `313fddd` plus the uncommitted probe.

| SoC | Skel SHA-256 | Application IDs | Total | Available | Granted with HMX | Pages |
| --- | --- | --- | ---: | ---: | ---: | --- |
| SM8550 | `48AD10BA…` (ID 0 only) | 0, 3 runs | 8,388,608 | 8,388,608 | 8,388,608 | 1 × 8 MiB (available as 2 × 4 MiB) |
| SM8635 | `48AD10BA…` | 0, 3 runs | 4,194,304 | 4,194,304 | 4,194,304 | 1 × 4 MiB |
| SM8635 | `9BEE9667…` | 0 to 8 | 4,194,304 each | 4,194,304 each | 4,194,304 each | 1 × 4 MiB |

All query, power, acquire and release return codes were 0, and every granted pointer
was non-null. The SDK header says an application ID not defined in the device tree
selects the primary partition, so identical results for IDs 1 to 8 show no larger
partition is reachable this way; they do not prove the silicon holds only 4 MiB.
`/proc/device-tree` on both phones has no VTCM nodes.

Independent source: ExecuTorch's Qualcomm backend SoC table
(`backends/qualcomm/serialization/qc_schema.py`, `_soc_info_table`, read at commit
`adc0bccadc06ea5facda3c332c14f9612ea59494`) lists `SM8550 HtpInfo(V73, 8)`,
`SM8635 HtpInfo(V73, 4)`, `SM7675 HtpInfo(V73, 4)`, `SM8650 HtpInfo(V75, 8)`,
`SM8750 HtpInfo(V79, 8)`, `SM8850 HtpInfo(V81, 8)` (VTCM in MB). The measured
values match: SM8635 is a 4 MB VTCM part, not a reservation on this phone.
Not yet run: the QNN runtime's own on-device report
(`QnnHtpDevice_OnChipDeviceInfoExtension_t.vtcmSize`, `tools/Invoke-QnnPlatformInfoProbe.ps1`).
