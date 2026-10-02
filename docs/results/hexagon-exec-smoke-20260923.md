# Delayed shared-buffer execute mapping smoke test

## Measured result

On the S23 / SM8550 / V73, in the existing unsigned cDSP session:

| Stage | Result |
| --- | --- |
| Load diagnostic bootstrap | Success, OpenRc=0 |
| rpcmem allocation and fd acquisition | Success |
| fastrpc_mmap, domain 3, FASTRPC_MAP_FD_DELAYED (3) | Success for every case |
| DSP HAP_mmap READ\|WRITE | Success for every preparation |
| Write and read back the emitted instructions | Match |
| qurt_mem_cache_clean, DCACHE FLUSH | Success |
| HAP_munmap after preparation | Success |
| Remap READ\|WRITE control | Success; instruction readback matches |
| Remap READ\|EXEC | No usable mapping returned |
| Remap READ\|WRITE\|EXEC | No usable mapping returned |
| Execute shared-buffer instructions | Not attempted after mapping rejection |
| Host unmap and handle close | Success |

This is a measurement of this API path on this device/session. It does not prove
that all executable allocation APIs, all DSP process types, or direct target
registration paths are unavailable. The independently proven PowerShell-emitted
ELF loading path is unaffected.

## Test construction

`src/kernels/exec-smoke/exec_smoke.c` is a small diagnostic bootstrap compiled
with SDK 6.4.0.2 / Hexagon Clang 19.0.04, `-mv73 -O2 -fPIC -G0 -shared
-nostdlib -Wall -Wextra -Werror`. Its only undefined dynamic symbols are
`HAP_mmap`, `HAP_munmap`, and `qurt_mem_cache_clean`. No qaic-generated glue is
needed; it implements the already-tested handle calling convention directly.

The eight-byte function under test is emitted by `src/emit/Hexagon.ps1`:
`r0 = #73`, then `jumpr r31`, in separate packets. It is not compiler output.

Each case allocates a fresh 4096-byte rpcmem buffer on the host and registers
delayed mapping. The bootstrap first obtains an RW mapping, copies the two
emitted instruction words from the RPC input, verifies them, flushes the DSP
data cache, and unmaps. It then requests the tested protection flags. A separate
execution call is permitted only after a mapping-only call succeeds; execution
would invalidate the instruction cache and invoke the mapped address.

Copying the instruction words on the DSP keeps host-to-shared-buffer cache
maintenance out of this first test. It does not establish host-written,
zero-copy code publication. All bootstrap results are returned in an explicit
parameter block. The host saves progress before potentially executing code.

Bootstrap SHA-256:
`E22A8B4D98893AFE45A3C02E632F8C303BBB36DE62A7A01B99B5D986527C0D8A`.

Emitted function SHA-256:
`D358D9C78B0FE0B715986D088178242968D3C0626B5C9E853195DD885B26036F`.

Source contracts, all in SDK 6.4.0.2:

- `remote.h`: delayed map flag and host mmap/munmap signatures. SHA-256
  `F61E1F92C88DBC642D17DF3855DD6FF9D5E605D442A5DE73B8A7E023C225BC0D`.
- `HAP_mem.h`: mapping, protections, failure convention and unmapping. SHA-256
  `4056CFF8017393CB4AEF7E2EC07540F2466003EC74A66A53000D2562697D5EAF`.
- `computev73/include/qurt/qurt_memory.h`: cache flush/invalidate APIs. SHA-256
  `5D75BC9998A99EDCF18DE86BB7D6E37DFA908195C620488ECAD33A10A75B1556`.

## Receipt

```text
UnsignedPdRc=0
OpenRc=0
Case=RW-control HostDelayedMapRc=0
Case=RW-control RwMapped=1 DataFlushRc=0 RwUnmapRc=0 TargetMapped=1 ICacheRc=0 Called=0 Value=0 TargetUnmapRc=0 WriteMatch=1 ReadMatch=1
Case=RW-control HostUnmapRc=0
Case=RX-map HostDelayedMapRc=0
Case=RX-map RwMapped=1 DataFlushRc=0 RwUnmapRc=0 TargetMapped=0 ICacheRc=-999 Called=-999 Value=-999 TargetUnmapRc=-999 WriteMatch=1 ReadMatch=-999
Case=RX-map HostUnmapRc=0
Case=RX-execute Skipped=MappingRejected
Case=RWX-map HostDelayedMapRc=0
Case=RWX-map RwMapped=1 DataFlushRc=0 RwUnmapRc=0 TargetMapped=0 ICacheRc=-999 Called=-999 Value=-999 TargetUnmapRc=-999 WriteMatch=1 ReadMatch=-999
Case=RWX-map HostUnmapRc=0
Case=RWX-execute Skipped=MappingRejected
CloseRc=0
Completed=True
```

`-999` means that stage was not reached; `Completed=True` means the planned
controls and mapping probes completed, not that executable mapping succeeded.

## Reproduction and controls

Build with `tools/Build-HexagonExecSmoke.ps1`, using a fresh output directory.
The script checks pinned compiler/API hashes. The host script is
`src/runspace/HexagonExecSmoke.ps1`; it validates the bootstrap, emitted function,
and delegate factory hashes before invoking anything. Device selection is via
`KOKORO_QNN_SERIAL`. Build artifacts and the full device receipt remain in
`..\Build\Kokoro-QNN\exec-smoke`.

The startup scripts were backed up, restored and hash-checked. All measured
mappings were released and the handle closed. Host buffers are zeroed before
release. No device security configuration was changed. The test uses the
existing FullLanguage interop host. No QNN graph or Kokoro model was run.
