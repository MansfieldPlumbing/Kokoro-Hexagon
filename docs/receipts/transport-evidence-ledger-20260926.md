# CDSP transport evidence ledger — 2026-09-26

This ledger distinguishes code-execution, transport, and performance claims.
It does not select a product transport.

| Evidence | Established | Not established |
| --- | --- | --- |
| `r0sub0-cross-soc-20260924.md` | The same emitted R0Sub0 kernel ran on SM8550 and SM8635. On SM8635 its DSP-tick median was 2.286–2.302x faster than the LLVM comparison kernel; both were invoked through `libcdsprpc.so`. | A FastRPC bypass, a complete model, or a whole-path speech speedup. |
| `direct-fastrpc-native-open-20260925.md` | A direct libc open of an ADSP-named node returned `EACCES` in both tested app sandboxes. | CDSP access through that node, another node, or a lower transport. |
| Owner-reported cross-device smoke test | The owner reports that a separate FastRPC-bypass test succeeded on the Razr+ with roughly twofold speedup and failed on the S23. | The artifact, mechanism, privilege context, workload, comparator, S23 failure stage, and reproducibility are not yet identified in this checkout. |
| Pinned Qualcomm DSPQueue source | Defines a QNN-independent shared-memory queue layout, a FastRPC queue bootstrap, and driver-signaling capability checks. See `dspqueue-upstream-audit-20260926.md`. | Use of this mechanism in the reported phone tests, Queue Monitor availability on either phone, and a universal no-ioctl-per-job path. |
| `s23-cdsp-node-inventory-20260926.md` | In a read-only S23 shell check, only ADSP-named RPC nodes appeared under the queried paths; the kernel base differs from the external report's LineageOS candidate. | App access, a queue route, the prior S23 failure stage, or a Razr+ comparison. |
| `cross-device-cdsp-inventory-20260926.md` | A same-session read-only check found matching queried RPC nodes, modes, owners, and labels on both devices; neither installed kernel base matches the external candidate revisions. | Equal firmware capabilities, app access, or the cause of the reported queue-test split. |

Next evidence action: locate the reported smoke-test artifact or immutable
source revision, then record its exact execution path, device context,
comparator, measured quantity, and first failing stage on the S23. Keep it
separate from the R0Sub0 receipt.
Do not infer that FastRPC is mandatory or that a kernel modification is needed.
