"""N driven by the phonemes: mean 8-point N shape per (left, phone, right) from bank sentences 0-9999, backoff to
(phone, right), (phone); stretched to each token's duration. Compared with sampled-unit N on stock durations."""
import json, pathlib, sys
import numpy as np
SCR = pathlib.Path(sys.argv[1])
exec(compile(open(SCR / 'n_diag.py', encoding='utf-8').read().split('M = {k: []')[0], 'n_diag.py', 'exec'))
order = json.loads((BANK / 'order.json').read_text(encoding='utf-8'))
P = 8
acc = {}
def add(k, v):
    if k in acc: acc[k][0] += v; acc[k][1] += 1
    else: acc[k] = [v.copy(), 1]
for c in range(10):
    z = chunk(c)
    for l in range(len(z['tok_off']) - 1):
        s = c * 1000 + l; toks = ['<', *order[s]['phonemes'], '>']
        a = int(z['tok_off'][l]); f = int(z['frm_off'][l])
        for i, sym in enumerate(toks):
            d = int(z['dur'][a + i]); n = z['n'][2 * f:2 * (f + d)].astype(np.float64); f += d
            shape = np.interp(np.linspace(0, len(n) - 1, P), np.arange(len(n)), n)
            L = toks[i - 1] if i else '#'; R = toks[i + 1] if i + 1 < len(toks) else '#'
            add(('3', L, sym, R), shape); add(('2', sym, R), shape); add(('1', sym), shape)
def lookup(L, sym, R, minc=5):
    for k in (('3', L, sym, R), ('2', sym, R), ('1', sym)):
        if k in acc and acc[k][1] >= minc: return acc[k][0] / acc[k][1]
    return acc[('1', sym)][0] / acc[('1', sym)][1]
print('contexts', sum(1 for k in acc if k[0] == '3'), 'units', sum(v[1] for k, v in acc.items() if k[0] == '1'))
res = {k: [] for k in ('F0s Nu', 'F0s Nphone', 'F0u Nu', 'F0u Nphone')}
for k, h in enumerate(held):
    ph = h['phonemes']; ref_s = pack[len(ph) - 1]; cap = stock(ph); sd = cap['dur']
    ref = decode(cap['t_en'], sd, cap['F0'], cap['N'], ref_s)
    picks = sel['picks'][k]['path']; us = [unit(p['s'], p['i']) for p in picks]
    te = np.stack([u[0] for u in us], 1)
    uF = np.concatenate([fit(u[2], d) for u, d in zip(us, sd)]).astype(np.float32); uN = np.concatenate([fit(u[3], d) for u, d in zip(us, sd)]).astype(np.float32)
    toks = ['<', *ph, '>']
    pN = np.concatenate([np.interp(np.linspace(0, P - 1, 2 * d), np.arange(P), lookup(toks[i - 1] if i else '#', toks[i], toks[i + 1] if i + 1 < len(toks) else '#')) for i, d in enumerate(sd)]).astype(np.float32)
    for tag, F, N in (('F0s Nu', cap['F0'], uN), ('F0s Nphone', cap['F0'], pN), ('F0u Nu', uF, uN), ('F0u Nphone', uF, pN)):
        res[tag].append(dtw_dist(ref, decode(te, sd, F, N, ref_s)))
    print(k, {t: round(v[-1], 2) for t, v in res.items()}, '|N err| unit/phone', round(float(np.abs(uN - cap['N']).mean()), 3), round(float(np.abs(pN - cap['N']).mean()), 3), flush=True)
print('mean', {t: round(float(np.mean(v)), 2) for t, v in res.items()})
