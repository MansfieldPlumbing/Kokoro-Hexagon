# Student native replay and initial library, 2026-10-15

Implemented in `tools/Kokoro.Student.psm1`, through the owning `Student Replay`
command. `docs/student-opcodes.md` defines the byte contract. The nine COPY-only
listening pairs were completed and committed first at
`46b29e7026c432f8032aeb2b89a595e504956dbc`.

The complete read-only measured bank has **2,429,833 units**, 43,679 sentences
and **933 admitted real medoid directions**. Order and all 44 chunk hashes match
the structural measurement. No nearest-neighbor or medoid search was repeated.

Each exemplar remains a real bank occurrence. Its 512 values are re-encoded as
int16 using one shared per-channel voice key, selected as the largest real
observed chunk key. All units fit without saturation. This key conversion is
not claimed bit exact against original dequantized FP32 features; the later
climber must measure against those original features. No averages or fitted
projections are used. Directions are selected real within-sentence medoids,
stored as their observed FP32 difference.

Initial programs are native COPY-only, five bytes per unit, using the measured
best other exemplar. No RESIDUAL, control track or quality-bar claim is hidden
in initialization. The interpreter also admits DIRECTION, signed-int16 channel
RESIDUALs with a declared fixed-point shift, and uint32 FLAGS. COPY-previous
uses the immediately previous source-unit replay, not a selected playback
neighbor from another source sentence.

| Core store component | Bytes |
| --- | ---: |
| All real exemplar int16 tiles | 2,488,148,992 |
| 933 real direction vectors | 1,910,784 |
| Shared voice key | 2,048 |
| Initial COPY programs | 12,149,165 |
| **Core total before climbing** | **2,502,210,989** |

The learning-only pair lookup adds 9,719,332 bytes. Descriptions, fixtures and
compiled code are separately retained. This is an unpruned initial library,
not a compression result. The full bank's int16 feature baseline is
2,488,148,992 bytes. The requested 51k-unit baseline is approximately 52 MB
(51,000 × 1,024 = 52,224,000 bytes); its unit count differs from this full run.

Packing took **35,682.1532 ms** for the complete bank, excluding bank loading,
library writing and hashing. This is a batch preparation operation with no
synthesized-audio denominator; it is not compared as synthesis speed. For the
requested historical timing reference, the approximate old int8 generator is
40 ms/audio-s; the preserved separate run is 41.918118 ms/audio-s; the cited
combined decoder/source/generator receipt is 46.867294 ms/audio-s and states
`ResidentHvxThreads=4`. No new DSP timing or hardware claim is made.

## Verification and artifacts

Native fixtures pass all four instructions, COPY-previous, determinism and
exact flags. Six malformed programs are rejected: truncation, invalid exemplar,
missing predecessor, invalid channel, invalid direction and unknown opcode.
The native COPY program encoder matches independently declared fixture bytes.
Original feature-expansion, exact nearest/tie/self-exclusion and medoid fixtures
also pass. The pinned compiler admits CLR-only assemblies. Explicit numeric
types and the result constructor satisfy its existing lowering contract.

Outputs are in `build/student-replay-full-20261015/`. The initial full library
was produced before adding bulk COPY-program encoding; that encoding was then
admitted and applied to the preserved nearest IDs without rebuilding the bank.
The producer now does both in one invocation. The two assembly identities below
record that distinction. The generated description was extended with component
hashes and the COPY-program description before freezing this receipt.

| Artifact | SHA256 |
| --- | --- |
| Initial packing/replay kernel | `F6973CA429D3A4F127280482520309D4EFB15D2A22B0A5642DD7E8684563C3B6` |
| Replay/COPY-program kernel | `1158D7EC4D11BE2C90AD1AE6F0BAE0FFB60D10D4EACA9DDEA35F7F9B611C853C` |
| exemplars.i16 | `D70BBE613EF9215DFCA132EEC0F4FB5375F1987378BAC57B54DDEBE02021D622` |
| voice-key.f32 | `0E8D43B6C45253778ED04D002C02554CA07E8FCF11BC3D66D99DCB9289B42474` |
| directions.f32 | `F2AE0066A773FCE5552B7E1254A5487ADBE77F602312CF91AA67E14341AF6985` |
| pair-ids.i32 | `A30D0201B9B04C6E675546574BC33A9BEDC9A8799B69AB2EE005442B55E7111B` |
| copy-programs.bin | `FC220852DAAA2D9123B79D56DFA7AD519E62DFABDFCE4FFCE03693BB6335E9DF` |
| native-library.clixml | `9C4494B80037BAFD298E03D1D016878BB16B61C6A976F8AAE4136351156C4B05` |

No phone, new JSON, Python, worktree or push. Protected bank, captures,
manifests and previous receipts remain unchanged. Earlier profiling WIP is
preserved outside this step. The 46/70 dB climber and CONST-control listening
gate remain subsequent work; this receipt does not claim them complete.
