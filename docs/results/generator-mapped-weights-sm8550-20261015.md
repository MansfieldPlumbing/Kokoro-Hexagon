STOP condition: none.

# Managed generator weights and resident first-block transport

The S23/SM8550 executed the connected first 16-frame generator main block with weights read from an uncompressed managed assembly resource. Its 262,144-byte FP16 native mean handoff was byte-identical to the preceding unbundled, nonresident first-block build. The tail and whole-sentence PCM are not included in this result.

## Payload and launch

| Artifact | Bytes | SHA256 |
|---|---:|---|
| Native generator main weights | 29,687,808 | `51E58ED0CABA65D5607C0F9EB9C4A9420ED339EACF1DFCDFB98CB3439FB6C2E0` |
| Measured weight assembly | 29,689,856 | `15F294D90DE890F8A6C3F9F3D148B61944D43D7D78752047553EFE2CAF9A65E2` |
| Resident DSP library | 155,880 | `7D16A86CEB4C15AE8998C1CC2A6390E4997671118120A9A60A80F3CAC1CE81B3` |

The assembly adds 2,048 bytes to the native weights. The resource starts at file offset 1,016. Its module identity is `51e58ed0-caba-65d5-607c-0f9eb9c4a942`, stored at offset 868. The separately emitted mapped-resource owner is 4,096 bytes and references CoreLib and `System.IO.MemoryMappedFiles`; it has no SMA dependency. This is the managed payload owner, not admission of the complete frontend or generator as managed code. Generator arithmetic still executes in project-emitted Hexagon code.

Manufacturing validates the PE/CLI format, managed identity, length and resource hash before moving the completed staged assembly into place. Device staging checks the producer-pinned file hash and length before an atomic file rename. An activation record retains the verified identity. Later launches check the activated file's length and 16-byte module identity, then map it read-only; the weight file is not hashed at launch. This diagnostic does not introduce cryptographic payload signing or change the host APK's signing contract. A signed production-update integration is not established by this receipt.

The mapped owner retains its file and view for the session and invalidates the borrowed pointer on close. The resident transport makes one native copy into `rpcmem` and one static CDSP mapping per payload at startup. Weights are not materialized as a managed byte array on the device. Tables use the reused resident path. Subsequent invocations pass configuration, frame inputs and the diagnostic output buffer. That output remains a temporary main-block handoff until the tail supplies PCM.

| Timing scope | First call | Median of five subsequent calls |
|---|---:|---:|
| Launch mapping, length and identity check, isolated probe | 10.753 ms | 0.059 ms |
| Connected main DSP execution, resident weights/tables | 17.737916667 ms | 17.661822917 ms |
| Host FastRPC invoke, same six main-block runs | 21.117 ms | 18.628 ms |

The isolated mapping probe's first call includes first-use/JIT work. Its warm calls are repeated mappings in one process, not five fresh application launches. The actual connected runner reported 11.216 ms for launch mapping and 70.765 ms for the separate startup allocation/copy/CDSP-map of weights and tables. Both shared payloads unmapped with return code 0. Startup files were restored with hash verification and the phone lock was released.

A subsequent fresh application launch reused the existing activation record and reported `WeightActivationReused=True PayloadHashPasses=0`. Its length/identity check and mapping took 11.525 ms; native handoff bytes again matched the baseline exactly. That launch's separate resident allocation/copy/map took 84.885 ms. These startup costs are paid once per application session.

The preceding hash-on-launch probe took 141.448 ms. That probe used the same weight bytes and device, but a different loader, container hash and operation scope: two full hash passes were replaced by length and identity checks. It is not a synthesis-speed comparison.

## Connected main gate and timing conditions

The baseline is `build/generator-templates/main-first-block-bounce-20261015`, library `9AA06BD56742879C28818BD1317DDE0CDFE234258B597236356E57857AF8A598`. Its warm DSP median was 17.666406250 ms and host invoke median was 30.232 ms. Both runs use the same S23, captured dog inputs, supplied source tiles, fixed constants, 16-frame main block, hardware Lock setting, and one first call followed by five warm calls. The candidate changes transport and adds the reused 264-byte resident entry wrapper; the computed native handoff matches byte for byte. No whole-generator or peach timing is claimed.

Convolution-only FP16 HMX rates were 2.954249–4.183410 TMAC/s on run 0 and 3.513719–4.185057 TMAC/s at each layer's median of five warm runs. These windows exclude DMA, upsampling and epilogues. All 36 per-layer timer rows are retained in `build/generator-weight-assembly-20261015-activated/resident-layer-table.clixml` and the full report. The prior standalone own-input layer comparisons were 70.93992–73.3968 dB; those references were not recomputed from the newly connected internal inputs. The present gate establishes transport parity with the already-finite native handoff.

VTCM requested by the fixed main job is 5,570,560 bytes. Inputs are 671,744 bytes, weights 29,687,808 bytes, tables 6,832,128 bytes, and diagnostic output 263,168 bytes including its 1,024-byte header. The tables still contain utterance-specific Lock streams in this temporary first-block protocol. They are not yet a permanent resident deployment-table contract.

The bounce replaces only the Lock phase wrap. From the existing dog tile at `resblocks.3.adain2.0`, 423/122,880 values (0.34423828125%) lay beyond `-pi/2` or `pi`: 194 below and 229 above. This is that saved tile's count, not a whole-dog aggregate. The device and offline Lock reference use absolute value below zero, reflection above `pi/2`, then clamp. Smoothstep's unused polynomial and existing fixed normalization values remain unchanged. Fixed normalization and one-layer diagnostic wrappers remain temporary scaffolding.

## Reproduction and remaining work

```powershell
& ./Invoke-KokoroDevelopment.ps1 WeightAssembly `
    -Path ./build/generator-templates/main-first-block-bounce-20261015/weights.bin `
    -OutputDirectory ./build/generator-weight-assembly-20261015-staging-verified2

& ./build/generator-weight-assembly-20261015-activated/Test-Mapping.ps1
& ./build/generator-weight-assembly-20261015-activated/Invoke-Resident.ps1
& ./build/generator-weight-assembly-20261015-activated/Invoke-Resident.ps1 -Runs 1 -Tag relaunch
& ./Invoke-KokoroDevelopment.ps1 Verify
```

The measured assembly was manufactured before the final staging-validation ordering change; its weight bytes and managed-owner source are the same. The final manufacturing command separately passed with resource verification before activation. Host checks cover exact resource bytes, invalid identity, invalid file length, invalid extent, closed-pointer access and file-handle cleanup.

The independent SDK check for the resident entry did not complete: WSL stalled in `wslpath` before invoking the assembler. Only this task's stalled `wslpath` child was stopped. A fresh SDK match for this artifact is unverified; the device execution and exact native-output comparison above completed. No production assembler was introduced.

The two requested committed resident changes were cherry-picked with conflict adaptation: `973544fceb1a8c56dcb573de18610b9ac8f09228` became `f9c002aa92967f467d9991f87c1bcceada294bd5`; `98f0cc2360d093f483b9fd00be4b1d52d2d5c612` became `6c7ed89a633f3f6015942a5e3295ec72cc62c923`. Verify preceded each commit. No uncommitted files from that worktree were copied. The local generator edits were preserved in a temporary stash, reapplied, and the backup stash was retained.

Repository/worktree: `Kokoro-Hexagon-generator-templates`, branch `generator-templates`. The parent before this connected/mapped integration is `6c7ed89a633f3f6015942a5e3295ec72cc62c923`; no push. The full report under `build/generator-weight-assembly-20261015-activated/report.md` records final commit identity, verbatim repository statuses and changed-path reasons. Protected captures and original constants were not modified. The imported frozen resident receipts retain their original provenance. Unrequested scope: none. WAV paths: none for these main-block and mapping runs.

Temporal carry across blocks, the tail, dog/peach/nine whole-PCM comparisons, the live frontend input bridge and hand bundling remain unfinished. Arbitrary-text synthesis and a complete resident generator are not claimed by this receipt.
