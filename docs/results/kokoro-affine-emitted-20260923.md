# Kokoro affine subgraph emitted as V73 instructions

## Device result

The two-node AdaIN affine subgraph from `generator.resblocks.3.adain1.0`
executes on the S23 as PowerShell-emitted V73 instructions:

```powershell
$scaled = Mul $normalized $gain
$output = Add $scaled $shift
```

The existing SMA AST lowerer produces two DAG nodes. The new backend validates
that DAG and specializes its channel-first loop for 128 channels, 7681 samples,
and the gain/shift offsets in the existing prepared-weight manifest. Both
arithmetic operations run inside one loop, with the intermediate in a register.
The multiplication and addition retain separate fp32 rounding; this is not FMA.

All 983,168 output values match the PowerShell/SMA fp32 reference bit-for-bit.
Wrong geometry and short geometry/input/weights/output buffers are rejected.
Input and weight hashes remain unchanged after execution. The handle closes.

| Measured item | Result |
| --- | ---: |
| Host setup, including reads, hashing, binding and opening | 225.629 ms |
| First fused call | 28.970 ms |
| Fused warm median, 12 calls | 25.998 ms |
| Two-pass warm median, 12 pairs | 45.505 ms |
| Split median / fused median | 1.750 |
| Library bytes | 8,384 |
| Code bytes, including guards, controls and length diagnostic | 1,216 |
| Imports / relocations | 0 / 0 |

The comparison uses the same emitted scalar multiply and add, first fused and
then in separate passes/calls. Order alternates across 12 measured pairs. Times
include host invocation and transport; they exclude reference creation and
setup. No explicit performance vote was set. Timing drift is visible in the
raw pairs, so this is an exploratory within-run comparison, not a stable device
performance specification. It is not a QNN comparison or a full-Kokoro speedup.

## Existing weights and buffer ownership

The phone already contained `r0/r0_static.bin`, `in_z.f32` and `in_mask1.f32`.
The weight file matched the host's prepared-weight manifest before testing.
No weights were uploaded, reformatted, quantized, or embedded in executable code.
Gain and shift are read at offsets 1,182,720 and 1,183,232 in that same weight file.

The existing file is read into one managed byte array and pinned for the session.
The normalized activation, intermediate control output and final outputs are
also pinned. There is no application-side rpcmem staging copy in this test.
However, ordinary pinned host memory does not establish shared DSP backing:
FastRPC may copy/map these buffers internally, and every call still describes
the full static buffer. Persistent DSP registration and zero-copy weight access
are not proven here. The prepared file is preserved unchanged on device.

The reference input is prepared from actual `r0` activations and its mask using
PowerShell/SMA with double-precision normalization, then rounded to fp32. The
affine reference explicitly rounds after multiplication and addition. This
tests the affine arithmetic on representative normalized activations; it is not
full AdaIN, Snake, convolution, full-PyTorch parity, or vocalization.

## Provenance

- Model source: `src/models/Kokoro.Affine.ps1`.
- Existing frontend: `src/lower/Lower-Model.ps1`.
- Backend: `src/emit/Kokoro.Affine.ps1` and `src/emit/Hexagon.ps1`.
- ELF generation: `tools/Emit-HexagonProbe.ps1 -Kernel KokoroAffine`, reusing
  the hash-pinned Pwsh ELF writer described in `hexagon-emitted-elf-20260923.md`.
- SMA-only reference: `tools/Prepare-AffineReference.ps1`.
- Independent instruction comparison: `tools/Test-HexagonEmission.ps1
  -Kernel KokoroAffine`. All 1,216 bytes match the pinned SDK assembler's output.
  The assembler is used only for verification; it does not produce the loaded ELF.
- Device harness: `src/runspace/KokoroAffineProbe.ps1`.
- V73 PRM Rev. AB: scalar fp32 add p. 456, multiply p. 476;
  add-immediate p. 157. Existing instruction/ELF source pins remain unchanged.

SHA-256 values:

| Artifact | SHA-256 |
| --- | --- |
| Final emitted library | `E12719773385A53CDC3E21DD8E5D89E89E95C975C04FA2C3E6C6DD964044A1DD` |
| Existing r0 weights | `997CF6049BBDF8BD987CC757CE04D5EEF73C167315C4E426FEF275AB4A0F3B05` |
| Existing r0 input | `95BBBE5BAC44721D49F43A773A17728AD75308F3505676DA29B2D47FA5656662` |
| SMA normalized input | `2392D4BA33E9A036BA3A33902A7DEE4FC9035BCBFE7D1FD2C6171B34ECF526C0` |
| SMA reference and both DSP outputs | `FB44F04A5776DC460C67EE74AB9D25C5063D606663A5A06F511EDFC9CEF85C8F` |

Final outputs and raw receipt are under
`..\Build\Kokoro-QNN\hexagon-emission\affine-v3`;
reference data is under `affine\reference-sma`.

## Final timing and checks

```text
Pair=0 FusedMs=27.437 SplitMs=49.330
Pair=1 FusedMs=27.544 SplitMs=47.933
Pair=2 FusedMs=28.264 SplitMs=49.053
Pair=3 FusedMs=27.595 SplitMs=46.826
Pair=4 FusedMs=27.977 SplitMs=48.459
Pair=5 FusedMs=25.837 SplitMs=44.183
Pair=6 FusedMs=25.635 SplitMs=43.209
Pair=7 FusedMs=25.781 SplitMs=46.831
Pair=8 FusedMs=26.159 SplitMs=40.678
Pair=9 FusedMs=23.445 SplitMs=39.622
Pair=10 FusedMs=24.272 SplitMs=42.045
Pair=11 FusedMs=23.701 SplitMs=41.839
FusedMedianMs=25.998 SplitMedianMs=45.505 SplitOverFused=1.750
PostTimingIntegrity=True
WrongGeometryRc=14
LengthEchoRc=0 HostInputLength=4 DspLengths=8,4,1195008,3932672
ShortInputRc=14
Short-geometry-Rc=14
Short-weights-Rc=14
Short-output-Rc=14
CloseRc=0
Passed=True
```

Controls: hash-checked sources and artifacts, AST parsing, independent assembly
comparison, exact output hashes, geometry/buffer rejection, zeroed scratch
buffers and released handles/pins. The existing interop host uses FullLanguage;
no ConstrainedLanguage portability claim is made. Device identifiers stay in
`KOKORO_QNN_SERIAL`. The app startup scripts were restored and their hashes
verified. No changes were committed or pushed.

## Lower submission boundary investigated

The device exposes `/dev/adsprpc-smd` and `/dev/adsprpc-smd-secure`; its kernel
identifies as 5.15.189-android13-8-33413713-abS911USQS8FZH3. That inventory does
not establish permission to open or invoke either node from the application.

Qualcomm's public implementation at commit
`d247519650fe5cb16de6c78edaa95bcc4be25073`, `src/fastrpc_apps_user.c:1428`,
submits through `ioctl_invoke`. Its `inc/fastrpc_ioctl.h` defines the driver
invoke structure. This identifies a userspace-library bypass candidate, not
an exact source match to this phone's vendor driver. No unverified ioctls were
issued to the phone. Direct submission performance is unverified.

The installed SDK 6.4.0.2 `incs/dspqueue.h` documents asynchronous packets with
buffer references and explicit cache-maintenance flags. That is another candidate
for persistent submission, not a verified device capability. Neither route is
required by the model/backend abstraction; the current callable envelope is a
working test harness while the submission mechanism is evaluated separately.
