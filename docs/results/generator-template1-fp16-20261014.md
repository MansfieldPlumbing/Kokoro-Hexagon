# Generator template 1: FP16 crouton handoff, 2026-10-14

This is a single-layer diagnostic on SM8550, not a whole-generator result. The
unbundled emitted library SHA256 is
`7A08FA33F12B5A59F10FFB42128A91E0A6281E58027F97C20EF90FEB7E4A6BB6`.
The SDK assembler matched all 6,512 emitted code bytes before that same library
was run on the phone. Requested VTCM was 2,359,296 bytes.

## Reproduction

From `Kokoro-Hexagon-generator-templates`, branch `generator-templates`:

```powershell
& Pwsh-Development\tools\board.ps1 Lock -Agent Codex -Reason 'Complete template-1 block gate'
try {
    & .\Invoke-KokoroDevelopment.ps1 Run -Case generator-template1 -Soc SM8550 -Runs 5 -Parameters @{Tiles=60} -OutputDirectory (Join-Path $PWD 'build\generator-templates\layer-block32-gate')
} finally {
    & Pwsh-Development\tools\board.ps1 Unlock -Agent Codex
}
& .\Invoke-KokoroDevelopment.ps1 Verify
```

Choose a fresh output directory when repeating the run. The tested convolution
is `generator.resblocks.3.convs1.0`, 128 input/output channels, three real taps,
dilation one, and 1,920 output positions. Its next affine/Snake operand is
produced by the register epilogue and consumed directly by an FP16 identity
convolution. No layout conversion occurs between those two operations.

## Gate

| Output | SNR, dB | Maximum absolute error |
|---|---:|---:|
| Convolution vs offline float reference | 69.5206487981 | 0.00360202789306641 |
| Activated operand vs offline float reference | 35.1034107048046 | 0.377185344696045 |
| Identity consumer vs activated operand | infinity | 0 |
| Diagnostic continuation PCM vs reference continuation | 64.4869672298825 | 0.000508487224578857 |
| Diagnostic continuation PCM vs captured stock | 64.4887685884958 | 0.000508397817611694 |

The convolution/operand comparisons use identical preserved inputs and weights,
with FP16 HMX and the prescribed interpolated register lookup on the candidate
side, and float32 convolution/exact Snake on the reference side. Normalization
levels are supplied from this diagnostic's offline reference; deployment
constants and whole-generator scheduling are not admitted by this test.

Both continuation renders use the same verified offline implementation and the
same remaining tensors and conditions. Only the first 1,920 positions of the
tested operand differ. Comparison with captured stock additionally differs in
that the tested branch and tail are recomputed by the offline implementation.
The other two parallel branches use captured stock tensors. The listening pair
therefore isolates this layer's contribution; it is not device-rendered PCM.

HMX convolution timing from the first run's two system-clock reads was
0.0269270833333333 ms for 94,371,840 MACs: 3.50471823597679 TMAC/s. This excludes
DMA and the HVX epilogue, and is not the median of the five complete warm jobs.
No bundled speed or whole-generator speed is established.

Evidence directory:
`build\generator-templates\layer-block32-gate`. It contains `gate.clixml`,
`loudness.clixml`, float reference/candidate outputs, `stock.wav`,
`candidate-continuation.wav`, and `stock-then-template1.wav`. WAVs are mono
24 kHz PCM16; the pair places stock first, 0.6 seconds of silence, then candidate.

## Source identities and limits

- Exact offline reference: branch `v15-front-end`, commit `68bdb38`; source
  `tools/Invoke-KokoroPrecomputedDecoder.ps1`, SHA256
  `8DAD8231FDCBF80C024E2C9C0A4D53FC7CE0E02D3415ABBE2FE73A1AB8E07257`;
  admitted assembly SHA256
  `446FD867E60D8D21F267D9B372A6736D357E84DEF7B680609E8386CBE22D1F8D`.
- `Kokoro_Generator_Register_Datapath.md`, section 6b: "Dilated resblock convs
  execute real taps only; dilation is an address shift"; the existing address
  schedule is reused.
- The same document, section 4: "HMX computes the tile into VTCM (the required
  handoff)". Native consumption is established here by the identity consumer's
  zero maximum error on the same device artifact.
- FP16 named instruction precedent is preserved in
  `hmx-named-encoders-reference-20260923.md` and
  `hmx-w4a8-direct-readback-20260924.md`.
- The existing MeasureAudio module is read from its separate worktree and its
  Git blob checked against commit `93a6d82`; it is not modified.

Residual/fanout paths, other kernel/dilation combinations, polyphase upsampling,
resblock means, source/tail, cross-block histories, all 53 layers, and bundled
execution remain unverified by this receipt. No frozen capture was modified.
