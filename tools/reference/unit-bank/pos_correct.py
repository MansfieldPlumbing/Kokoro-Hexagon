"""Position correction for sampled N and log F0: learn mean per-token N and voiced log F0 against relative position in
the sentence from bank chunks 0-9 (10,000 sentences, none held out), then shift each selected unit by
curve(target position) - curve(donor position). Uses no target stock tensors except for scoring."""
import json, pathlib, sys
import numpy as np
SCR = pathlib.Path(sys.argv[1])
exec(compile(open(SCR / 'n_diag.py', encoding='utf-8').read().split('M = {k: []')[0], 'n_diag.py', 'exec'))
B = 20
sumN = np.zeros(B); sumF = np.zeros(B); cN = np.zeros(B); cF = np.zeros(B)
for c in range(10):
    z = chunk(c)
    for l in range(len(z['tok_off']) - 1):
        a, b = int(z['tok_off'][l]), int(z['tok_off'][l + 1]); T = b - a; f = int(z['frm_off'][l])
        for i in range(1, T - 1):
            d = int(z['dur'][a + i]); n = z['n'][2 * f:2 * (f + d)].astype(np.float64); fz = z['f0'][2 * f:2 * (f + d)].astype(np.float64); f += d
            p = min(B - 1, int(B * i / T)); sumN[p] += n.mean(); cN[p] += 1
            v = fz > 10
            if v.any(): sumF[p] += np.log(fz[v]).mean(); cF[p] += 1
        f = int(z['frm_off'][l])
gN = sumN / np.maximum(cN, 1); gF = sumF / np.maximum(cF, 1)
print('N curve', np.round(gN, 2).tolist()); print('logF0 curve (Hz)', np.round(np.exp(gF), 0).tolist())
def tokens_in(s): z = chunk(s // 1000); l = s % 1000; return int(z['tok_off'][l + 1]) - int(z['tok_off'][l])
res = {k: [] for k in ('F0u Nu', 'F0u Nu-pos', 'F0u-pos Nu', 'F0u-pos Nu-pos', 'full-dur pos')}
for k, h in enumerate(held):
    ph = h['phonemes']; ref_s = pack[len(ph) - 1]; cap = stock(ph); sd = cap['dur']
    ref = decode(cap['t_en'], sd, cap['F0'], cap['N'], ref_s)
    picks = sel['picks'][k]['path']; us = [unit(p['s'], p['i']) for p in picks]; T = len(picks)
    te = np.stack([u[0] for u in us], 1)
    shN, shF = [], []
    for t, p in enumerate(picks):
        pt = min(B - 1, int(B * t / T)); pd = min(B - 1, int(B * p['i'] / tokens_in(p['s'])))
        shN.append(gN[pt] - gN[pd]); shF.append(gF[pt] - gF[pd])
    def build(dur_of, fN, fF):
        F = np.concatenate([fit(u[2], d) * (np.exp(shF[t]) if fF else 1.0) for t, (u, d) in enumerate(zip(us, dur_of))])
        N = np.concatenate([fit(u[3], d) + (shN[t] if fN else 0.0) for t, (u, d) in enumerate(zip(us, dur_of))])
        return F.astype(np.float32), N.astype(np.float32)
    for tag, fN, fF in (('F0u Nu', 0, 0), ('F0u Nu-pos', 1, 0), ('F0u-pos Nu', 0, 1), ('F0u-pos Nu-pos', 1, 1)):
        F, N = build(sd, fN, fF); res[tag].append(dtw_dist(ref, decode(te, sd, F, N, ref_s)))
    ud = np.array([u[1] for u in us]); F, N = build(ud, 1, 1)
    a = decode(te, ud, F, N, ref_s); res['full-dur pos'].append(dtw_dist(ref, a)); write_wav(f'../unit-bank/eval/h{k}-full-pos', a)
    print(k, {t: round(v[-1], 2) for t, v in res.items()}, flush=True)
print('mean', {t: round(float(np.mean(v)), 2) for t, v in res.items()})
