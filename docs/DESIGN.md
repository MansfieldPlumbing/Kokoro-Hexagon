# Design and HTP findings

This is a historical QNN/oracle investigation, not the product architecture.
The current release boundary and remaining work are in `ROADMAP.md`. Its
numerical and AdaIN findings remain useful comparison evidence; its QNN
passes, libraries, and contexts are not production dependencies.

All findings below were verified on the S23 (SM8550, Hexagon V73) with QAIRT
2.46.0.260424, by per-layer probes compared against PyTorch on the device.

## Static capacity with masked normalization

Kokoro's `AdaIN1d` uses `InstanceNorm1d`, which normalizes over the whole time
axis. Sliding windows therefore change the statistics: 64-frame windows with a
12-frame overlap (the Piper/Melo pattern) reached only 5 dB SNR. Instead, one
fixed-capacity window per phrase is used, with statistics computed over valid
frames only (a length mask). Error against the full-length model: 24.2 dB SNR,
0.62 dB log-mel. Phrases are split at natural boundaries by the front end.

## Harmonic source on the host (for now)

`SineGen` uses `rand`/`randn` and a whole-sequence phase `cumsum`. It is
computed on the host and passed to the generator as an input, so the HTP graph
has no random ops.

## QNN passes

| Pass | Reason |
| --- | --- |
| `Pow(x,2)` → `Mul(x,x)` | `Pow(x,2)` is wrong on HTP V73 (variance −10 dB; `Mul` 61 dB) |
| Depthwise `ConvTranspose1d` → polyphase; `Resize` → expand/reshape | the upsampling `decode` block broke on HTP (3.7 dB → 58.5 dB after rewrite) |
| fp16-safe statistics (scale by per-channel max before squaring) | fp16 overflow of the variance sum on HTP |
| Time lengths padded to a multiple of 8 (masked) | length 19,201 fails finalize; 19,208 compiles |
| Stage-resolution masks as graph inputs | removes `Resize` fallbacks from traced masks |
| Per-voice gamma/beta table (`gb`) instead of `fc(style)` | removes 48 `Gemm` per call; exact |
| ORT basic optimization | folds shape plumbing; 3,098 → 1,674 nodes, bit-exact |

## Runtime

- Contexts are loaded from a memory-mapped file with `contextCreateFromBinary`
  and `graphRetrieve` (`src/runspace/Qnn.Context.psm1`). Tensor IDs and shapes
  come from the binary itself (`tools/Read-QnnContextInfo.ps1`).
- The HTP performance vote (`QnnHtpPerfInfrastructure`, DCVS v3 burst) cut the
  generator from 4.69 s to 1.90 s. 8 MB VTCM cut it further to 1.57 s.
- Host overhead per call is about 1.5 ms; HTP reports no wait time, so the
  remaining time is inside the graph.

## Android host

- The APK must declare `<uses-native-library android:name="libcdsprpc.so">`.
- QNN libraries are preloaded by full path from app storage, with
  `ADSP_LIBRARY_PATH` set to the library directory plus the platform defaults
  (`/vendor/lib/rfsa/adsp;/vendor/dsp/cdsp;/dsp`).

## Open

- w8a16 (int8 weights, int16 activations) does not finalize yet, including a
  conv-only variant under test.
- 16 generator convs are dilated (3 and 5). Rewriting them as dilation-1 convs
  over interleaved phases is exact and keeps per-channel int8 legal on HTP.
- Per-op profiling is refused (`QNN_GRAPH_ERROR_SET_PROFILE`) for these
  contexts; sub-graph timing is used instead.
- Residual dropout is not a speed knob for this model: skipping one of 18
  generator resblock branches costs about 10 dB log-mel.
