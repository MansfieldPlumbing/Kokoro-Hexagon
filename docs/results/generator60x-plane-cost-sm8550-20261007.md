# Cost of byte-plane precision work in the resident 60x stage, SM8550, 2026-10-07

Local uncommitted work on `7363334`. Emitter `src/emit/Kokoro.Generator60xResidentRun.ps1
-CostProbePasses N` (measurement only; N = 0 is the unchanged stage). Harness
`tools/Invoke-ResBlockRunProbe.ps1 -Graph Generator60x`, fixture
`build/generator60x-run-fixture-20261006`, 7,801 frames (1.625 s of audio), 3 runs each, one session.

## What the probe adds

Per batch, after the real conv: a second fused AdaIN+Snake pass into a second window
(`WindowLow`, same 4 MiB page), N extra HMX passes of the same conv with the two-plane store
(`Kokoro.HmxConv.ps1 -OutputPlanes`, `docs/results/hmx-two-plane-output-sim-20261007.md`) into
scratch tiles, and an HVX merge loop (high & 0xff00ff00 | low >> 8) into a scratch tile. The real
output path is untouched, so the output must equal the frozen tensor.

## Result

| N | Skel SHA-256 | VTCM granted | Output | Region ticks (runs) | Median |
|---:|---|---:|---|---|---:|
| 0 | `11F85FEE…` (same as the 86.3 ms receipt) | 4,718,592 | `1D23542E…`, 0/999,424 lanes, 0 coefficient bytes | 1,647,920 / 1,652,143 / 1,656,000 | **86.05 ms** |
| 1 | `B3979F7B…` | 5,242,880 | same, 3/3 | 3,066,688 / 3,080,527 / 3,075,953 | **160.21 ms** |
| 2 | `8A6E0DD4…` | 5,242,880 | same, 3/3 | 3,106,659 / 3,112,578 / 3,119,974 | **162.11 ms** |

All three skels match SDK 6.4.0.2 assembly byte for byte (`Test-HexagonEmission.ps1`).

- One more HMX pass over the whole stage (16.1 G MAC) costs **1.9 ms** (N = 2 vs 1).
  The frozen worker's profile attributed 2.03 ms to raw HMX arithmetic
  (`generator60x-profile-breakdown-sm8550-20261006.md`).
- The remaining +72 ms of N = 1 is HVX: a second full fused AdaIN+Snake pass and the merge loop.
  The probe recomputes the whole fused body to stand in for producing a low plane; a fused body
  that emits both planes from one AdaIN+Snake evaluation would not repeat that work. That cost is
  not measured yet.

Device receipts: `build/generator60x-costprobe{0,1,2}-emission-20261007/KokoroGenerator60xResidentRun/device-receipt-SM8550-*.txt`;
captured outputs `build/generator60x-costprobe{0,1,2}-SM8550-output-20261007.bin`.

## Not covered

SM8635: the probe needs 5.24 MB of VTCM and the unchanged stage 4.65 MB; SM8635 grants 4 MiB, so
both need the tiled path first. Two-plane arithmetic correctness inside the stage (this probe keeps
the frozen arithmetic). Energy.

## Phase-turns body in the stage (timing only)

`-CostProbePasses 1 -CostProbeTurnsBody`: the old fused body is replaced by
`Kokoro.AdaInSnakeTurns.ps1` (both conv-input planes from one call, `docs/results/snake-turns-reference-20261007.md`),
plus one extra HMX pass with two-plane stores and the HVX merge. Its per-channel constants are
stand-ins (the stage's coefficient records), so the output is not the stock tensor (`Passed=False`);
HVX and HMX timing here has no data-dependent branches. Skel `6703D881…`, SDK bytes match; the
unchanged stage still emits `11F85FEE…`.

| Variant (SM8550, same fixture and session) | Region ticks (runs) | Median |
|---|---|---:|
| Unchanged stage (above) | 1,647,920 / 1,652,143 / 1,656,000 | 86.05 ms |
| Phase-turns body + 1 extra HMX pass + two-plane stores + merge | 1,103,156 / 1,116,103 / 1,111,759 | **57.90 ms** |

Not included: 16-bit moments, residual and mean passes, and extra weight-plane passes (1.9 ms per
stage-wide HMX pass, above). Unpacked: one instruction per packet, one HVX thread.
Receipt: `build/generator60x-costprobe1turns-emission-20261007/KokoroGenerator60xResidentRun/device-receipt-SM8550-b3efde90….txt`.
