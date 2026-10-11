"""N diagnostics on the full-bank selection (nine held-out sentences, stock durations, sampled t_en):
F0 x N substitution matrix; stock N vs stock output log-energy; sampled-N error at non-genuine joins vs inside donor
runs; N smoothed across non-genuine joins."""
import json, pathlib, sys
import numpy as np
SCR = pathlib.Path(sys.argv[1]); sys.argv = [sys.argv[0], 'none', str(SCR)]
src = open(SCR / 'bank.py', encoding='utf-8').read()
exec(compile(src.split("if MODE == 'capture':")[0], 'bank.py', 'exec'))
exec(compile(src[src.index('# ---------- metrics / pictures'):src.index("if MODE == 'render':")], 'bank.py', 'exec'))
BANK = REPO / 'build' / 'unit-bank'
sel = json.loads((SCR / 'big-selections.json').read_text(encoding='utf-8-sig'))
key = max(sel, key=lambda k: sel[k]['sentences']); sel = sel[key]
held = json.loads((SCR / 'heldout.json').read_text(encoding='utf-8-sig'))
cache = {}
def chunk(c):
    if c not in cache: z = np.load(BANK / f'chunk-{c:04d}.npz'); cache[c] = {k: z[k] for k in z.files}
    return cache[c]
def unit(s, i):
    z = chunk(s // 1000); l = s % 1000; t = int(z['tok_off'][l]) + i
    f = int(z['frm_off'][l]) + int(z['dur'][int(z['tok_off'][l]):t].sum()); d = int(z['dur'][t])
    return z['t_en'][:, t].astype(np.float32) * z['scale'], d, z['f0'][2 * f:2 * (f + d)].astype(np.float32), z['n'][2 * f:2 * (f + d)].astype(np.float32)
def fit(v, d): return np.interp(np.linspace(0, len(v) - 1, 2 * d), np.arange(len(v)), v)
M = {k: [] for k in ('F0s Ns', 'F0u Ns', 'F0s Nu', 'F0u Nu', 'F0s Nu-smooth', 'F0u Nu-smooth')}
corr, join_err, run_err = [], [], []
for k, h in enumerate(held):
    ph = h['phonemes']; ref_s = pack[len(ph) - 1]; cap = stock(ph); sd = cap['dur']
    ref = decode(cap['t_en'], sd, cap['F0'], cap['N'], ref_s)
    picks = sel['picks'][k]['path']; us = [unit(p['s'], p['i']) for p in picks]
    te = np.stack([u[0] for u in us], 1)
    uF = np.concatenate([fit(u[2], d) for u, d in zip(us, sd)]); uN = np.concatenate([fit(u[3], d) for u, d in zip(us, sd)])
    # joins: boundary half-frame index before token t where picks t-1, t are not adjacent in one donor
    bounds = 2 * np.cumsum(sd)[:-1]
    genuine = [picks[t]['s'] == picks[t - 1]['s'] and picks[t]['i'] == picks[t - 1]['i'] + 1 for t in range(1, len(picks))]
    err = np.abs(uN - cap['N']); near = np.zeros(len(err), bool)
    for b, g in zip(bounds, genuine):
        if not g: near[max(0, b - 2):b + 2] = True
    join_err.append(err[near].mean() if near.any() else np.nan); run_err.append(err[~near].mean())
    Ns = uN.copy()
    for b, g in zip(bounds, genuine):
        if not g and 2 <= b < len(Ns) - 2:
            a, c = Ns[b - 3] if b >= 3 else Ns[0], Ns[b + 2]
            Ns[b - 2:b + 2] = np.linspace(a, c, 6)[1:5]
    # stock N vs stock output log-energy at the N rate (300 samples per half-frame)
    hop = 300; e = np.array([np.log(np.mean(ref[i * hop:(i + 1) * hop] ** 2) + 1e-9) for i in range(len(cap['N']))])
    corr.append(np.corrcoef(cap['N'], e)[0, 1])
    for tag, F, Nx in (('F0s Ns', cap['F0'], cap['N']), ('F0u Ns', uF, cap['N']), ('F0s Nu', cap['F0'], uN), ('F0u Nu', uF, uN),
                       ('F0s Nu-smooth', cap['F0'], Ns), ('F0u Nu-smooth', uF, Ns)):
        M[tag].append(dtw_dist(ref, decode(te, sd, F, Nx, ref_s)))
    print(k, {t: round(v[-1], 2) for t, v in M.items()}, 'corr', round(corr[-1], 3), 'Nerr join/run', round(join_err[-1], 2), round(run_err[-1], 2), flush=True)
print('bank', key, 'mean', {t: round(float(np.mean(v)), 2) for t, v in M.items()})
print('corr(stock N, stock log-energy) mean', round(float(np.mean(corr)), 3), 'min', round(float(np.min(corr)), 3))
print('|N sampled - N stock| near non-genuine joins', round(float(np.nanmean(join_err)), 3), 'elsewhere', round(float(np.mean(run_err)), 3))
