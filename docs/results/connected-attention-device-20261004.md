# Connected attention DSP receipt, 2026-10-04

Status: working-tree, fixed-shape diagnostic passes. Not a complete ALBERT
iteration, stock-framework FP32 promotion, product transport, or speech result.
Testing used the exclusively assigned arm64/API-36 test device and the existing
independent Kokoro diagnostic APK. No other installed application was replaced.

## Connected computation and artifact identity

`src/emit/Kokoro.AlbertConnectedAttention3.ps1` composes context, output dense
projection, the original hidden-state residual, and LayerNorm in one emitted
entry. Tensor arithmetic and intermediate copies execute on DSP; there is no
PowerShell math or per-region dispatch between these consumers. The diagnostic
runspace still performs launch, repeated-call timing, and result verification.
It is not the eventual compiled inference-control artifact.

Geometry is three tokens, hidden width 768, 12 heads of 64. Input is fused QKV
followed by the original hidden state. One 36,864-byte output arena holds four
disjoint 9,216-byte edges: context, hidden copy, projection, normalized result.
Weights occupy 2,368,512 bytes and retain the existing output-major layout.
The original descriptor remains live; no mutable local descriptors or additional
callee-saved registers are introduced. Floating-point instruction order matches
the preceding region bodies. Context retains its existing bounded approximation.

- ELF SHA-256: `0502E64043BFEB7CD979F7626D30908B438BAA5A26F12EBFE7A2BA298781CF11`.
- ELF/code lengths: 41,152 / 33,672 bytes; zero imports and relocations.
- Fixture SHA-256: `35C4AB66C4C8CB32194D117F2A56006B7D6E35F8B1AD3AA8A749AA9577643D7F`.
- Checkpoint SHA-256: `496DBA118D1A58F5F3DB2EFC88DBDC216E0483FC89FE6E47EE1F2C53F18AD1E4`.
- Encoding reference SHA-256: `FC64C65ACA06186106A73BA93E65DDF7C906BF4905B786DC748D3F034401EA27`.

The first connected artifact failed physical invocation. A pointer-adapter
lifetime error was corrected; the failed artifact and receipt remain under
ignored `build/spikes/connected-attention-20261004/emitted/`. The corrected
artifact is under `emitted-v2/`. A regression gate now rejects three variants
of that adapter error. The corrected artifact matches the independent assembler
byte-for-byte; that assembler does not supply deployed bytes.

## Recorded numerical and safety results

Declared limits remain context maximum error `2e-5`, exact hidden copy,
projection/LayerNorm maximum error `1e-4`, and SNR at least 80 dB.

| Boundary | Values | Maximum absolute error | SNR dB |
| --- | ---: | ---: | ---: |
| Context | 2,304 | 4.76837158203125e-7 | 141.9047 |
| Original hidden copy | 2,304 | 0 | infinite |
| Projection | 2,304 | 3.0517578125e-5 | 125.0347 |
| Residual LayerNorm | 2,304 | 7.62939453125e-6 | 128.4828 |

Reference coverage is the integrity-pinned existing PowerShell approximation
and double-accumulating projection fixture. This checks propagated consumer
error, not an independent original-framework FP32 whole-region comparison.
No new Python runner, exported graph, or downstream implementation supplies
model semantics. Original source pins remain in the iteration ledger.

Local gate: 31 malformed layouts rejected, three pointer-lifetime regressions
rejected, unchanged FP instruction order, resolved labels, retained descriptor,
and disjoint arena edges. These local results are not physical alignment/alias
tests. Physical gate: four short buffers return 14; non-finite input/weights
return 33; wrong geometry returns 14; a finite late-domain case returns 33 after
projection. All preserve the published tensor. Restored inputs and weights are
exact, a subsequent valid call reproduces the valid output, and close returns 0.

RPC output-only bytes are private staging. They are copied to separate published
storage only after synchronous status zero. The earlier raw-output-preservation
failure is not erased: the first short-buffer rejection still changes raw
transport output. Its internal copy-back cause remains unestablished, and raw
staging is never treated as a successful tensor. The ABI direction fields are
source-traced to Qualcomm `remote.h` at
`d247519650fe5cb16de6c78edaa95bcc4be25073:92-125`; that userspace header does
not establish this firmware's internal error-copy behavior. The existing vendor
client is diagnostic only, not a release dependency or direct-driver proof.

## Timing boundary

One cold call plus 12 warm calls: cold 46.399 ms; warm median 35.759 ms,
minimum 32.482 ms, maximum 54.886 ms. Timing brackets only synchronous native
invocation through the managed binding: it includes vendor transport/marshalling,
not just DSP cycles, and excludes launch, fixture loading, verification,
publication copy, and playback. No thermal, clock, or power normalization was
performed. Do not claim a controlled speedup against another session's 33.922 ms
projection-only median, or compare either number to online full-speech TTFA.

Scalar dense projection remains a correctness baseline, not the performance
target. See the [benchmark and forecast ledger](kokoro-performance-targets-20261004.md).
Independent stock-FP32 comparison, vectorized projection, QKV composition,
FFN/`gelu_new`, second residual LayerNorm, repeats, real lengths, product admission,
compiled dispatch, and audible PCM remain open.

## Reproduction

Run from Windows PowerShell 7 in this repository; generated files stay in ignored
`build/`. Device execution requires an exclusive test-device handoff.

```powershell
./tools/Test-KokoroOutputPublication.ps1
./tools/Test-KokoroAlbertAttentionOutput3Admission.ps1 -Connected
./tools/New-KokoroAlbertConnectedAttention3Fixture.ps1 -OutputDirectory "$PWD/build/connected-fixture-new"
./tools/Test-HexagonEmission.ps1 -Kernel KokoroAlbertConnectedAttention3 -OutputDirectory "$PWD/build/connected-emission-new"
./tools/Invoke-KokoroAlbertAttention3Probe.ps1 -Stage Connected -ApiLevel 36 `
    -FixtureDirectory "$PWD/build/connected-fixture-new" `
    -EmissionDirectory "$PWD/build/connected-emission-new/KokoroAlbertConnectedAttention3"
```

Native-binding, fixture and ELF identities are checked on Windows and after
private staging. This is the existing diagnostic host-verified admission seam,
not a completed on-device model-download verifier. Profile and uniquely scoped
temporary/private sessions are restored/removed by the runner. No log buffer,
system setting, or unrelated app data is changed.

Final handoff verification: startup Profile absent, zero run-created private
and temporary sessions, Kokoro stopped, and the installed diagnostic APK hash
unchanged. The test device is available for the next session. The other
capability targets were inventoried only; no application work ran on them.
