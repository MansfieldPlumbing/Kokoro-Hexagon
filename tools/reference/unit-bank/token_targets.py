"""Per-token acoustic targets from the captured stock tensors (no renders): mean N, mean voiced log F0 (NaN when
unvoiced), voiced fraction, duration. One row per input token (BOS and EOS included), all 43,679 sentences."""
import pathlib
import numpy as np
BANK = pathlib.Path(r'C:\Dev\Kokoro-Hexagon\build\unit-bank')
S, T, NM, LF, VF, DU = [], [], [], [], [], []
for c in range(44):
    z = np.load(BANK / f'chunk-{c:04d}.npz'); to, fo, dur, f0, n = z['tok_off'], z['frm_off'], z['dur'].astype(np.int64), z['f0'].astype(np.float32), z['n'].astype(np.float32)
    for l in range(len(to) - 1):
        a, b = int(to[l]), int(to[l + 1]); f = 2 * int(fo[l])
        for i in range(b - a):
            h = 2 * int(dur[a + i]); fz = f0[f:f + h]; v = fz > 10
            S.append(c * 1000 + l); T.append(i); NM.append(n[f:f + h].mean()); VF.append(v.mean())
            LF.append(np.log(fz[v]).mean() if v.any() else np.nan); DU.append(dur[a + i]); f += h
np.savez(BANK / 'token-targets.npz', sent=np.array(S, np.int32), tok=np.array(T, np.int32), nmean=np.array(NM, np.float32),
         lf0=np.array(LF, np.float32), vfrac=np.array(VF, np.float32), dur=np.array(DU, np.int32))
print('rows', len(S))
