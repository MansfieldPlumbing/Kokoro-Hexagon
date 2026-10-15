# Resident payloads and skel overhead, SM8550, 2026-10-12

Continuation of [invoke attribution](invoke-gap-sm8550-20261012.md), based on
commit `8794b65`; PCM reference receipt `541aa1e`. Target is the authorized
SM8550, under `dev.mansfieldplumbing.kokoro`. These are captured peach decoder
inputs, not fresh-text synthesis or end-to-end application latency.

## Payload ownership and session lifetime

`Native.Binding.psm1:95` allocates each complete, unchanged payload with
`rpcmem_alloc(25, 0, alignedBytes)`: system heap, uncached CPU allocation.
It copies the payload once, obtains its DMA fd with `rpcmem_to_fd`, and maps
it once with `remote_mem_map(3, fd, 0, address, size, &remoteAddress)`.
The addresses and lengths are bounded to the DSP's 32-bit address space.
The buffers remain immutable until session cleanup. Mapping is removed
with `remote_mem_unmap` before allocation release. A failed unmap retains
the allocation rather than freeing memory the DSP could still reference.

| Payload | Original bytes | Page-aligned allocation bytes |
| --- | ---: | ---: |
| Weights | 69,683,200 | 69,685,248 |
| Parameter tables | 2,601,344 | 2,605,056 |

ABI evidence: FastRPC revision
`d247519650fe5cb16de6c78edaa95bcc4be25073`, `inc/rpcmem.h` (heap 25,
uncached flag 0, allocation/free/fd signatures) and `inc/remote.h:629`
(static map lifetime/cache contract), `inc/remote.h:1080` (domain map ABI).
`remote_mem_map` is a documented deprecated API, admitted here by actual
application-UID execution. No vendor implementation is incorporated.
CPU writes finish before mapping; no post-map payload updates are supported.

The opt-in emitted entry adapter uses method 3, scalar `0x03020100`:
20 bytes of control input, 202,624 bytes of activations, and 22,519,808 bytes
of output. Control contains tiles and the two mapped DSP addresses/lengths;
it does not contain either payload. These three per-call buffers are pinned
managed arrays; their ARM64 argument block is 48 bytes. The DSP adapter builds
the original five-entry descriptor block locally and calls the existing
synthesis body. Model math, weights, tables and runtime-frame source are
unchanged. The original method 2 remains available.

**Lifetime limitation:** the existing diagnostic runner restarts the app once
before the six-call batch and stops it after the batch, then verifies startup
restoration. All six calls reuse one app process, FastRPC handle and pair of
payload mappings. This establishes session reuse within a batch, not a
resident application serving separate requests. App startup, app shutdown,
connection opening and payload file reads are outside the invoke timers.
App teardown is not part of the measured warm invoke gap.

## Final artifact and measurements

Worker SHA256:
`FFF1155E6FEE0124FF7832F0BA73333A7DB834A81BFF7C02A84EA2BA5FBFCAC5`.
All six calls matched all 102,000 baseline PCM bytes by the preserved hash:
`67E722EF3D6D3671ADFC8E15ADC870A9A0A5EC91C15B0A4E0F398D6B4BB66028`.
The harness checks this before playback and stops on mismatch. The retrieved
run-0 PCM was also compared directly against the baseline WAV's 102,000 data
bytes: zero differing bytes.

| Run | Host invoke ms | DSP region ms | Entry to region ms | Region to return ms |
| --- | ---: | ---: | ---: | ---: |
| 0, first | 117.599 | 100.026 | 1.527 | 0.146 |
| 1 | 112.689 | 100.118 | 0.283 | 0.147 |
| 2 | 114.796 | 98.876 | 0.279 | 0.141 |
| 3 | 118.993 | 100.428 | 0.295 | 0.146 |
| 4 | 114.196 | 100.304 | 0.294 | 0.142 |
| 5 | 120.036 | 100.654 | 0.293 | 0.142 |
| **Five warm median** | **114.796** | **100.304** | **0.293** | **0.142** |

Baseline medians were 138.739 ms host and 99.593 ms DSP. The host median is
23.943 ms lower. DSP intervals overlap the baseline's observed range; this
batch does not establish a DSP speed change. First-call payload setup was
55.496 ms, including native binding, allocation, copying, mapping and control
construction. Payload setup plus first-call argument setup and invoke was
186.105 ms; this is a sum of those recorded scopes, not total startup latency.

The preliminary adapter batch also passed all PCM and cleanup gates. Its
warm medians were 122.623 ms host and 98.535 ms DSP. Finalization added an
error-return guard before telemetry writes and safer cleanup handling; it
did not optimize synthesis. The two batches demonstrate substantial host
timing variation. The final five-run table is the acceptance measurement.

## What the outer skel intervals contain

The first emitted instruction is `hwticks` at
`src/jobs/Kokoro.ResidentPayload.ps1:6`, before dispatch or frame allocation.
Entry ticks are saved on the adapter stack and published only after the body
returns. The final tick at line 43 follows all original job cleanup. Strictly,
its timestamp store and `dealloc-return` still follow it; those two instructions
are outside the sampled interval. It is a near-return timestamp, not a claim
that a timestamp can be stored after the return instruction.

The unchanged region boundaries are
`src/jobs/Kokoro.Generator60x16Run.ps1:418` and `:670`.
Both tick domains use 19,200 ticks/ms.

| Work | Position and source |
| --- | --- |
| Descriptor adaptation, argument validation, saved-register setup | Before region; `Kokoro.ResidentPayload.ps1:20`, `Kokoro.HmxConvRun.ps1:54` |
| Power votes | Before region; `Kokoro.HmxConvRun.ps1:83` |
| VTCM/HMX attribute setup, resource request and VTCM pointer query | Before region; `Kokoro.HmxConvRun.ps1:94`, `:98`, `:102` |
| Main-thread HVX and HMX locks | Before region; `Kokoro.HmxConvRun.ps1:118`, `:119` |
| DMA descriptor-slot and workspace pointer alignment | Before region; `Kokoro.Generator60x16Run.ps1:416`, `:417` |
| HVX worker create, worker HVX lock, stop/join/unlock | **Inside region**; `Kokoro.Generator60x16Run.ps1:531`, `:336`, `:723`, `:664`, `:347`, `:739` |
| DMA descriptors and transfers | **Inside region**; `Kokoro.Generator60x16Run.ps1:353`, `:356` |
| Connected-job telemetry and register/frame restore | After region; `Kokoro.Generator60x16Run.ps1:671`, `:673` |
| Main HMX/HVX unlock and VTCM/resource release | After region; `Kokoro.HmxConvRun.ps1:140`, `:142`, `:148` |
| Outer frame restore and final telemetry | After region; `Kokoro.HmxConvRun.ps1:150`, `Kokoro.ResidentPayload.ps1:38` |

The combined emitter inherits this resource wrapper through
`Kokoro.Generator60x16Run.ps1:391` and `Kokoro.ResBlockRun.ps1:13`.
It omits the original single-convolution staging/output memcpy; those calls
must not be charged to the combined job (`Kokoro.ResBlockRun.ps1:143`, `:145`).

The two measured outer intervals total about 0.435 ms. Per-call subtraction
of the complete sampled skel duration from host invoke leaves a **15.499 ms
warm median outside the skel**. This still includes FastRPC transfer/cache
handling for inputs/output, transport scheduling and managed binding overhead;
the present instrumentation does not subdivide them. The original ~15 ms
remainder is therefore not explained by DSP VTCM acquisition/release or main
locks. Worker startup/join and DMA remain inside the DSP region and have not
been timed individually here. A persistent DSP worker is not justified by
this invoke-gap attribution alone. No DSP lifecycle fix was made.

## Validation and reproduction

The final batch played 51,000 frames, completed drain, reported zero xruns,
successfully unmapped both payloads and verified startup restoration.
No exclusive-mode change or new listening assessment was made.

Emit through `tools/Emit-HexagonProbe.ps1 -Kernel KokoroDecoderGenerator16Run
-ResBlockFrames 10201 -ResidentHvxThreads 4 -ResidentBatchTiles 14
-DecoderMoments Constants -GeneratorMoments Constants -ResidentPayloads`.
Pass the returned typed artifact to `tools/Invoke-GeneratorTailProbe.ps1`
with `-Runs 6 -Soc SM8550 -Package dev.mansfieldplumbing.kokoro
-ExpectedPcmSHA256 <baseline hash> -ResidentPayloads` and the preserved binary
fixture. Evidence is in `build/resident-payloads-final/`: emitted worker,
typed artifact, raw device receipt/output, `device-run.txt`,
`warm-measurements.clixml` and `verify.log`. Preliminary evidence remains in
`build/resident-payloads/`.

Verify passed. The shared case-pair check was also run explicitly over all five
changed PowerShell files: zero collisions. Review checked ABI widths,
payload bounds, immutable ownership and unmap-before-free cleanup. No runtime-
frame files were edited, no DSP lifecycle optimization was introduced, and
no push was performed.
