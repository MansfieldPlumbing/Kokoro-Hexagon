# Third-party notices

Repository code is Apache-2.0; see `LICENSE` and `NOTICE`. A released APK must
carry notices for the exact components it contains.

| Component | License | Role |
| --- | --- | --- |
| Kokoro-82M source, weights and voices (hexgrad) | Apache-2.0 | Pinned stock model. Emitted tensor and voice resources are derived from the weights and are not committed. |
| Pwsh Android host (MansfieldPlumbing/Pwsh) | See `NOTICE` | Base APK and build functions, pinned by revision in `lib/manifest.json`. |
| PSLowering (MansfieldPlumbing) | Pinned by commit in `lib/manifest.json` | Lowers the encoder and numeric kernels to IL at build time. |
| Hexagon SDK toolchain (Qualcomm) | Qualcomm terms | Optional independent assembly check of emitted instructions during development. Not a build or runtime dependency. |
