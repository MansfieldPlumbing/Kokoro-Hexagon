# Hardware Receipt: Qualcomm Hexagon V73 Hardware Capability & VTCM Geometry

- Date: 2026-09-23
- Target: Samsung Galaxy S23 (SM-S911U / Snapdragon 8 Gen 2 / SM8550 / Hexagon V73)
- Host Harness: Pure PowerShell 7.4 over FastRPC `libcdsprpc.so` (`dev.mansfieldplumbing.androidsma.preview`)
- Execution Boundary: Unsigned CDSP User Process Domain (Domain ID 3)

## Objective & Invariant

Directly query physical silicon and firmware capability registers via FastRPC `remote_handle_control(DSPRPC_GET_DSP_INFO)` to establish empirical ground truth for:
1. Hexagon architecture version (`ARCH_VER`).
2. Maximum physical VTCM page size (`VTCM_PAGE`) and block count (`VTCM_COUNT`).
3. 128-byte HVX vector thread context support (`HVX_SUPPORT_128B`).
4. FastRPC unsigned process domain admission support (`UNSIGNED_PD_SUPPORT`).

## Hardware Evidence

Device query executed via `tools/Invoke-DspCapabilityProbe.ps1`:

```text
Job=dsp-capability-probe
UnsignedPdRc=0
Cap_DOMAIN_SUPPORT=0 (rc=0)
Cap_UNSIGNED_PD_SUPPORT=1 (rc=0)
Cap_HVX_SUPPORT_64B=0 (rc=0)
Cap_HVX_SUPPORT_128B=4 (rc=0)
Cap_VTCM_PAGE=8388608 (rc=0)
Cap_VTCM_COUNT=1 (rc=0)
Cap_ARCH_VER=16813171 (rc=0)
Cap_HMX_SUPPORT_DEPTH=0 (rc=0)
Cap_HMX_SUPPORT_SPATIAL=0 (rc=0)
Cap_ASYNC_FASTRPC_SUPPORT=1 (rc=0)
Cap_STATUS_NOTIFICATION_SUPPORT=1 (rc=0)
Cap_MCID_MULTICAST=0 (rc=14)
Cap_EXTENDED_MAP_SUPPORT=0 (rc=14)
Cap_HANDLE_PRIORITY_SUPPORT=0 (rc=14)
Cap_DSP_IMAGE_CONFIG=0 (rc=14)
ElapsedMs=158.268
Passed=True
StartupRestored=True
```

## Physical Parameters Established

1. **VTCM Advertised Hardware Geometry**:
   - `Cap_VTCM_PAGE = 8,388,608` bytes (**8.0 MiB** advertised hardware page size).
   - `Cap_VTCM_COUNT = 1` single physical pool.
   - **Boundary Condition**: `DSPRPC_GET_DSP_INFO` queries FastRPC capability attributes; it is an attribute query, not an active allocation. This establishes physical silicon capability, but does *not* yet guarantee that an unsigned User PD can allocate a single contiguous 8.0 MiB block. Firmware reservations or system carveouts may restrict the usable pool size. An explicit runtime allocation probe (`compute_resource_query_VTCM` / allocation syscall) is required before asserting 8.0 MiB is fully usable by our process.

2. **Architecture Version**:
   - `Cap_ARCH_VER = 16813171` (`0x01008C73`).
   - Lower byte: `0x73` (Hexagon V73 ISA).

3. **Vector Execution Units**:
   - `Cap_HVX_SUPPORT_128B = 4` parallel 128-byte vector contexts/threads.
   - `Cap_HVX_SUPPORT_64B = 0` (64-byte legacy mode completely deprecated).

4. **FastRPC Capabilities**:
   - `Cap_UNSIGNED_PD_SUPPORT = 1` (Unsigned user PD active and functional).
   - `Cap_ASYNC_FASTRPC_SUPPORT = 1`.

5. **Epistemic Discrepancy (HMX Capability Flags vs Physical Silicon)**:
   - `Cap_HMX_SUPPORT_DEPTH = 0` (rc=0) and `Cap_HMX_SUPPORT_SPATIAL = 0` (rc=0).
   - Despite FastRPC capability flags reporting zero for HMX support, physical acquisition via `qurt_hmx_try_lock()` and execution of native HMX instructions (`mxclracc`) succeeded on this exact silicon in unsigned PD (see [`hmx-hardware-lock-20260923.md`](file:///c:/Dev/Antigravity/Kokoro-Hexagon/docs/receipts/hmx-hardware-lock-20260923.md)).
   - Epistemic conclusion: The FastRPC capability fields are not authoritative predicates for unsigned PD HMX availability on retail SM8550 devices; physical instruction execution on silicon is the primary source of truth.
