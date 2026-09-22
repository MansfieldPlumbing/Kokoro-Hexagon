# Kokoro-QNN repository contract

Keep this repository narrow and evidence-led. The rules in the workspace `AGENTS.md`
apply.

- `lib/` holds pinned inputs and reference data only. Every external input is
  listed in `lib/manifest.json` with its SHA-256.
- `src/export/` is one-time host tooling. Python may export, verify and compile;
  it never runs on the device.
- `src/runspace/` is device code: PowerShell over the QNN C API, cmdlet-free
  (the Android host has no cmdlet modules).
- Nothing generated is committed: no ONNX, context binaries, WAVs, logs or
  Qualcomm libraries. Build output goes to `..\Build\Kokoro-QNN (next to the repository)`.
- Device identifiers are not written into the repository; pass them through
  `KOKORO_QNN_SERIAL`.

## Evidence rules

- Every graph that reaches the device passes `src/export/qnn_gate.py`.
- Every QNN pass is checked for exactness against the previous graph in fp32.
- A capability is claimed only with a device receipt. A block is correct on HTP
  only after a per-layer probe matches the PyTorch reference on the device.
- A phrase has vocalized only when valid PCM played through the phone speaker.
