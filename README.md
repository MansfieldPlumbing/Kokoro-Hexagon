# Kokoro-QNN

Kokoro-82M speech synthesis on Qualcomm Hexagon HTP, driven through the QNN C API
from PowerShell. No ONNX Runtime on the device.

## Status

First light on 2026-09-22: a Samsung Galaxy S23 (SM8550, Hexagon V73) spoke a
phrase through its speaker. Kokoro's whole decoder ran on HTP, iSTFT included,
from the AndroidSMA runspace. See [docs/FIRST-LIGHT.md](docs/FIRST-LIGHT.md).

| Stage | Where it runs |
| --- | --- |
| Text → phonemes | host CPU (Misaki) |
| ALBERT, text encoder, duration/F0/N predictor | host CPU (PyTorch) |
| Harmonic source (`SineGen`) + forward STFT | host CPU (PyTorch) |
| Decoder front (`encode`, `decode`, `F0/N_conv`) | **HTP** |
| Generator (upsamplers, resblocks, `conv_post`) + iSTFT | **HTP** |
| Playback | Android `AudioTrack` from PowerShell |

Measured on the S23 (fp16, burst vote, 8 MB VTCM, 160-frame capacity, one
phrase of 3.27 s): front 32 ms, generator + iSTFT 1.57 s, audio SNR 24.0 dB
against the full-length PyTorch reference (the fp32 CPU run of the same design
scores 24.2 dB).

Not yet done, stated plainly:

- The front end and harmonic source still run on the host.
- The generator is not yet real-time. Integer (w8a16) compilation does not
  finalize yet; the fp16 path is the one that runs.
- No streaming scheduler, energy measurement, or multi-SoC builds yet.

## Layout

```
lib/manifest.json   pinned inputs (SHA-256): weights, Kokoro source, host compiler, device runtime
lib/qairt-2.46/     QAIRT 2.46 ABI reference data (constants, enums, layouts, functions)
src/export/         one-time Python: static decoder export, QNN passes, gate, compile
src/runspace/       device-side PowerShell: QNN ABI, native, graph, context, Speak runner
tools/              host PowerShell: context metadata reader, device job and speak drivers
docs/               design, HTP findings, receipts
```

Build output is never written into the repository. Compiled contexts and staged
device jobs go to `..\Build\Kokoro-QNN (next to the repository)`.

## Pipeline

1. `src/export/split_export.py` — export the decoder at a fixed capacity with
   length masks (front and generator graphs).
2. `src/export/gen_stages.py` — generator variants (aligned, iSTFT in graph,
   per-voice gamma/beta table).
3. `src/export/pow2_to_mul.py`, then ORT basic optimization — QNN passes.
4. `src/export/qnn_gate.py` — static shapes and device-proven op allowlist.
5. `src/export/compile_ctx.py` — V73 context binary via onnxruntime-qnn 2.2.0
   (bundles QAIRT 2.46.0.260424, matching the device runtime).
6. `tools/Invoke-Speak.ps1` — stage both contexts and a phrase, run on the
   device, play, and return the receipt.

## Configuration

Host tools read these environment variables (no machine-specific defaults):

| Variable | Used by | Meaning |
| --- | --- | --- |
| `KOKORO_MODEL_DIR` | `src/export` | directory with `kokoro-v1_0.pth`, `config.json`, `voices/` |
| `KOKORO_QNN_SYSTEM_LIB` | `tools` | `QnnSystem` library from the same QAIRT build as the compiler |
| `KOKORO_QNN_SERIAL` | `tools` | adb serial of the target device |
| `KOKORO_QNN_ADB` | `tools` | adb executable (default: `adb` on `PATH`) |

## Licensing

This repository is Apache-2.0 (see `LICENSE` and `NOTICE`). Kokoro-82M weights and source are Apache-2.0. Qualcomm's QNN runtime libraries
are proprietary and are never committed or redistributed standalone; they are
pinned by hash in `lib/manifest.json` and obtained from the QAIRT SDK.
