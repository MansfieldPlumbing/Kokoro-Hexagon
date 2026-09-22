# Third-party notices

The code in this repository is licensed under Apache-2.0 (see `LICENSE` and `NOTICE`). It depends on or
produces artifacts from the following, which keep their own licenses:

| Component | License | How it is used |
| --- | --- | --- |
| Kokoro-82M weights and voices (hexgrad) | Apache-2.0 | Input to the export pipeline. Compiled contexts and per-voice tables derived from the weights remain subject to Apache-2.0 and carry its notice. |
| Kokoro source (hexgrad/kokoro 0.9.4) | Apache-2.0 | Model definitions used at export time; not redistributed here. |
| Misaki lexicons | Apache-2.0 | Planned front-end data; pinned by hash. |
| ONNX Runtime, onnxruntime-qnn | MIT | Host-side export and compile tooling; not redistributed here. |
| Qualcomm QAIRT / QNN runtime | Qualcomm AI Stack License | Never committed or redistributed standalone. Obtain from the QAIRT SDK; may be distributed only as object code incorporated into an application. |
| Hexagon SDK, toolchain, HexKL | Qualcomm license terms | Host-side build tools for custom kernels; not redistributed here. |
