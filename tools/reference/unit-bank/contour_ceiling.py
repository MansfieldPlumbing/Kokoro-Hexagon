"""Ceiling check (evaluation only): how much of stock's sentence-level contour is needed? Base = phoneme-mean N and
log F0 (bank sentences 0-9999, triphone with backoff) on the selected units' voicing; add stock's residual back in
compressed forms: exact, per-token mean, per-word mean, peak-hold high/low envelope midpoint (instant attack, 120 ms
release), 200 ms moving average. Stock durations, sampled t_en."""
import json, pathlib, sys
import numpy as np
SCR = pathlib.Path(sys.argv[1])
exec(compile(open(SCR / 'n_diag.py', encoding='utf-8').read().split('M = {k: []')[0], 'n_diag.py', 'exec'))
order = json.loads((BANK / 'order.json').read_text(encoding='utf-8'))
P = 8; accN = {}; accF = {}
def add(acc, k, v):
    if k in acc: acc[k][0] += v; acc[k][1] += 1
    else: acc[k] = [np.array(v, dtype=np.float64), 1]
for c in range(10):
    z = chunk(c)
    for l in range(len(z['tok_off']) - 1):
        s = c * 1000 + l; toks = ['<', *order[s]['phonemes'], '>']; a = int(z['tok_off'][l]); f = int(z['frm_off'][l])
        for i, sym in enumerate(toks):
            d = int(z['dur'][a + i]); n = z['n'][2 * f:2 * (f + d)].astype(np.float64); fz = z['f0'][2 * f:2 * (f + d)].astype(np.float64); f += d
            L = toks[i - 1] if i else '#'; R = toks[i + 1] if i + 1 < len(toks) else '#'
            shape = np.interp(np.linspace(0, len(n) - 1, P), np.arange(len(n)), n)
            for k in (('3', L, sym, R), ('2', sym, R), ('1', sym)): add(accN, k, shape)
            v = fz > 10
            if v.any():
                for k in (('3', L, sym, R), ('2', sym, R), ('1', sym)): add(accF, k, [np.log(fz[v]).mean()])
def look(acc, L, sym, R, default):
    for k in (('3', L, sym, R), ('2', sym, R), ('1', sym)):
        if k in acc and acc[k][1] >= 5: return acc[k][0] / acc[k][1]
    return default
gF = np.mean([v[0][0] / v[1] for k, v in accF.items() if k[0] == '1'])
def peak_hold(x, rel):
    up = np.empty_like(x); lo = np.empty_like(x); u = x[0]; w = x[0]
    for i, v in enumerate(x):
        u = v if v > u else u + (v - u) * rel; w = v if v < w else w + (v - w) * rel; up[i] = u; lo[i] = w
    return (up + lo) / 2
def smooth(x, n):
    k = np.ones(n) / n; return np.convolve(np.pad(x, n // 2, mode='edge'), k, 'valid')[:len(x)]
rel = 1 - np.exp(-12.5 / 120.0)  # per half-frame (12.5 ms), 120 ms release
forms = ('none', 'exact', 'token', 'word', 'peakhold', 'avg200')
res = {f'{q}:{form}': [] for q in ('N', 'F0', 'both') for form in forms}
for k, h in enumerate(held):
    ph = h['phonemes']; ref_s = pack[len(ph) - 1]; cap = stock(ph); sd = cap['dur']
    ref = decode(cap['t_en'], sd, cap['F0'], cap['N'], ref_s)
    picks = sel['picks'][k]['path']; us = [unit(p['s'], p['i']) for p in picks]; te = np.stack([u[0] for u in us], 1)
    uF = np.concatenate([fit(u[2], d) for u, d in zip(us, sd)]); voiced = uF > 10
    toks = ['<', *ph, '>']; ctx = [(toks[i - 1] if i else '#', toks[i], toks[i + 1] if i + 1 < len(toks) else '#') for i in range(len(toks))]
    baseN = np.concatenate([np.interp(np.linspace(0, P - 1, 2 * d), np.arange(P), look(accN, *c, accN[('1', c[1])][0] / accN[('1', c[1])][1])) for c, d in zip(ctx, sd)])
    baseLF = np.concatenate([np.full(2 * d, look(accF, *c, np.array([gF]))[0]) for c, d in zip(ctx, sd)])
    tokid = np.repeat(np.arange(len(sd)), 2 * sd)
    wid = np.cumsum([1 if t in (' ', '<', '>') or t in '.,!?;' else 0 for t in toks]); wordid = np.repeat(wid, 2 * sd)
    sF = cap['F0']; sv = sF > 10; lfs = np.log(np.maximum(sF, 1))
    rN = cap['N'] - baseN
    rF = np.where(sv, lfs - baseLF, 0.0); idx = np.arange(len(rF)); rF = np.interp(idx, idx[sv], rF[sv]) if sv.any() else rF
    def compress(r, form):
        if form == 'none': return np.zeros_like(r)
        if form == 'exact': return r
        if form == 'token': return np.array([r[tokid == t].mean() for t in tokid])
        if form == 'word': return np.array([r[wordid == w].mean() for w in wordid])
        if form == 'peakhold': return peak_hold(r, rel)
        return smooth(r, 16)
    for form in forms:
        cN = baseN + compress(rN, form); cF = np.where(voiced, np.exp(baseLF + compress(rF, form)), uF)
        for q, F, N in (('N', cap['F0'], cN), ('F0', cF, cap['N']), ('both', cF, cN)):
            res[f'{q}:{form}'].append(dtw_dist(ref, decode(te, sd, F.astype(np.float32), N.astype(np.float32), ref_s)))
    print(k, flush=True)
for q in ('N', 'F0', 'both'):
    print(q, {form: round(float(np.mean(res[f'{q}:{form}'])), 2) for form in forms})
