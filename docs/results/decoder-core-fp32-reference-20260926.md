# Decoder prelude and core reference, 2026-09-26

The bounded PowerShell FP32 decoder reference now carries aligned text
features and double-rate F0/N curves through the stock input preparation,
encode block, three same-rate AdaIN decode blocks, and final AdaIN upsample
block. It returns 512-channel generator features at twice the duration frame
rate. It does not yet run Kokoro's harmonic source, generator, iSTFT, or PCM.

Source identity: Kokoro `dfb907a02bba8152ca444717ca5d78747ccb4bec`,
`kokoro/istftnet.py` (`Decoder.forward`, `AdainResBlk1d`, `UpSample1d`).
The checkpoint identity and digest are enforced by the gates.

Executable gates:

- `pwsh -NoProfile -File tools/Test-KokoroDecoderPrelude.ps1
  -CheckpointPath <pinned checkpoint>`: analytic stride-two and channel
  layout checks plus stock-weight shape/finite check — pass.
- `pwsh -NoProfile -File tools/Test-KokoroAdaInResBlock1d.ps1
  -CheckpointPath <pinned checkpoint>`: analytic learned shortcut without
  upsample plus stock decoder encode shape/finite check — pass.
- `pwsh -NoProfile -File tools/Test-KokoroF0NAdaInResBlock.ps1
  -CheckpointPath <pinned checkpoint>`: existing F0/N regression after
  extracting the shared AdaIN operation — pass.
- `pwsh -NoProfile -File tools/Test-KokoroDecoderCore.ps1
  -CheckpointPath <pinned checkpoint>`: stock-weight execution across all
  decoder core blocks, output shape and finite values — pass.

The first full-core run exposed a reference-only channel bound of 1,024 in
the depthwise transposed convolution. The stock final decode block requires
1,090 input channels; the bound was raised to 2,048, retaining the existing
operation-count bound, and the full-core gate then passed. This was a bound
correction, not a change to model math.

These checks establish topology, tensor compatibility, basic analytic
semantics, and finite short-input execution. They do not establish an
independent decoder numerical differential, normal utterance throughput,
waveform synthesis, audible speech, or device performance. No external model
runtime was used in the gate.
