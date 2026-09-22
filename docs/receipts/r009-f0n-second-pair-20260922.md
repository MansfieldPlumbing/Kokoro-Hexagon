# R009 F0/N second pair: Resize in the shortcut

Device: SM8550 / Hexagon V73. QAIRT 2.46.0.260424. Graph built through the QNN C API
from PowerShell on device; nothing compiled.

## Result

| build | MaxAbs | Rmse | ops |
|---|---:|---:|---:|
| polyphase pool + `Resize` shortcut (prior) | 5.74660015106201 | — | 82 |
| polyphase pool + Reshape/Concat/Reshape shortcut | **0.0269908905029297** | 0.00240280029354746 | 84 |

`ValidateRc=0 FinalizeRc=0 ExecuteRc=0`, no non-zero add codes, context 3,338,240 bytes.
Oracle full scale 29.8425, so the residual is 0.09% of scale; max relative error on
values above 1.0 is 0.002442. 45 of 66,560 values exceed the stage's absolute 0.02
tolerance, split 22/23 even/odd in time and with nothing at t=0 or t=129 — no parity
bias, no edge concentration.

## Cause

Upstream `kokoro` (`dfb907a`, `kokoro/istftnet.py`) builds `AdainResBlk1d` with two
upsample paths:

- residual: `self.pool = weight_norm(nn.ConvTranspose1d(dim_in, dim_in, kernel_size=3,
  stride=2, groups=dim_in, padding=1, output_padding=1))` — depthwise ConvTranspose
- shortcut: `self.upsample = UpSample1d(upsample)` — `F.interpolate`, lowering to `Resize`

The earlier polyphase work replaced the depthwise ConvTranspose and left `Resize` in the
shortcut. Both are miscomputed on HTP V73, so `out = residual + shortcut` was half wrong.
Op census of the two prior modules:

- `Kokoro.F0NSecondPairR009.psm1`: `TransposeConv2d`, `Resize`
- `Kokoro.F0NSecondPairPolyphaseR009.psm1`: `Resize`

## Change

Nearest-neighbour x2 along the time axis, built from ops that are exact:

```powershell
[void](& $reshape "$branch.shortcut.lift"      "$branch.ShortcutFMajor65"   "$branch.ShortcutLifted"     @(1,65,1,512))
[void](& $concat  "$branch.shortcut.duplicate" @("$branch.ShortcutLifted","$branch.ShortcutLifted") "$branch.ShortcutDuplicated" @(1,65,2,512) 2)
[void](& $reshape "$branch.shortcut.expand"    "$branch.ShortcutDuplicated" "$branch.ShortcutFourD"      @(1,1,130,512))
```

Reshape to [1,65,2,512] then flatten row-major gives out[2t] = out[2t+1] = x[t], which is
exactly nearest-neighbour x2.

## Open

The stage still reports `Passed=False` because its gate is an absolute 0.02 on a tensor
spanning +/-29.8. That gate was calibrated for a 58-op stage; it should be relative and
sized to the fp16 floor (see fp16-null-result-20260922.md). The gate has not been changed.
