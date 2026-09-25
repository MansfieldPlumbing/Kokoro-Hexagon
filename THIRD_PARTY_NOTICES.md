# Third-party notices

Repository code is Apache-2.0; see `LICENSE` and `NOTICE`. A released APK and
model DLL must carry notices for the exact components they actually contain.
Reference-only tools and historical receipts do not become product dependencies.

| Component | License | Current role |
| --- | --- | --- |
| Kokoro-82M source, weights, and voices (hexgrad) | Apache-2.0 | Pinned stock model source; emitted tensor and voice resources are derived from the weights. |
| Misaki and the pinned `MisakiSharp` port | Apache-2.0 per pinned source | Pronunciation and differential-test oracles. Not packaged in the current model DLL or APK. |
| ONNX Runtime and onnxruntime-qnn | MIT | Historical host export/compiler comparison only; not a production build or runtime dependency. |
| Qualcomm QAIRT/QNN libraries and SDK | Qualcomm terms | Historical oracle/device experiments only. Libraries and generated contexts are not committed or part of the intended release. |
| Hexagon SDK/toolchain | Qualcomm terms | Independent assembly and device verification during development; not a production build or runtime dependency. |

The production path is PowerShell/SMA lowering to managed IL and directly
emitted DSP code. Review the final SBOM and release package rather than
assuming that every historical tool listed here is shipped.
