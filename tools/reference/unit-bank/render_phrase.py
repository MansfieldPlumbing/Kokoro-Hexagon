"""Phrase-prosody transplant on the 1,000-sentence bank selection. Sampled asr and durations fixed; F0/N vary:
A per-unit (baseline); B phrase donor F0 on unit voicing; B2 superposition F0 (unit residual + donor trend);
C B + donor N; C2 B2 + superposition N. Donor chosen by target-visible features (phrase-donor.ps1)."""
import json, pathlib, sys
import numpy as np
SCR = pathlib.Path(sys.argv[1]); sys.argv = [sys.argv[0], 'none', str(SCR)]
src = open(SCR / 'bank.py', encoding='utf-8').read()
exec(compile(src.split("if MODE == 'capture':")[0], 'bank.py', 'exec'))
exec(compile(src[src.index('# ---------- metrics / pictures'):src.index("if MODE == 'render':")], 'bank.py', 'exec'))
BANK = REPO / 'build' / 'unit-bank'
z = {k: v for k, v in np.load(BANK / 'chunk-0000.npz').items()}
sel = json.loads((SCR / 'big-selections.json').read_text(encoding='utf-8-sig'))['1000']
donors = json.loads((SCR / 'phrase-donors.json').read_text(encoding='utf-8-sig'))
held = json.loads((SCR / 'heldout.json').read_text(encoding='utf-8-sig'))
def sent_tensors(s):
    a, b = int(z['tok_off'][s]), int(z['tok_off'][s + 1]); fa, fb = int(z['frm_off'][s]), int(z['frm_off'][s + 1])
    return z['dur'][a:b].astype(int), z['f0'][2 * fa:2 * fb].astype(np.float64), z['n'][2 * fa:2 * fb].astype(np.float64)
def unit(s, i):
    a = int(z['tok_off'][s]) + i; f = int(z['frm_off'][s]) + int(z['dur'][int(z['tok_off'][s]):a].sum()); d = int(z['dur'][a])
    return z['t_en'][:, a].astype(np.float32) * z['scale'], d, z['f0'][2 * f:2 * (f + d)].astype(np.float64), z['n'][2 * f:2 * (f + d)].astype(np.float64)
def smooth(x, w=21):
    k = np.ones(w) / w; p = np.pad(x, w // 2, mode='edge'); return np.convolve(p, k, 'valid')
def logf0_trend(f0):
    v = f0 > 10; lf = np.log(np.maximum(f0, 1)); idx = np.arange(len(f0))
    filled = np.interp(idx, idx[v], lf[v]) if v.any() else np.full(len(f0), np.log(180.0))
    return smooth(filled), v, lf
def warp(x, src_a, src_b, n_tgt, tgt_a, tgt_b):
    """Map donor speech region [src_a, src_b) onto target speech region [tgt_a, tgt_b) by normalized time."""
    out = np.empty(n_tgt); pos = np.arange(n_tgt)
    t = np.clip((pos - tgt_a) / max(1, tgt_b - tgt_a), 0, 1)
    out[:] = np.interp(src_a + t * (src_b - src_a - 1), np.arange(len(x)), x); return out
rows = []
for k, h in enumerate(held):
    ph = h['phonemes']; ref_s = pack[len(ph) - 1]; cap = stock(ph)
    ref = decode(cap['t_en'], cap['dur'], cap['F0'], cap['N'], ref_s)
    us = [unit(p['s'], p['i']) for p in sel['picks'][k]['path']]
    te = np.stack([u[0] for u in us], 1); dur = np.array([u[1] for u in us]); F0 = np.concatenate([u[2] for u in us]); N = np.concatenate([u[3] for u in us])
    tgt_a, tgt_b = 2 * dur[0], 2 * (dur.sum() - dur[-1])
    ds = donors[k]['donors'][0]['s']; ddur, dF0, dN = sent_tensors(ds); src_a, src_b = 2 * ddur[0], 2 * (ddur.sum() - ddur[-1])
    trend_d, _, _ = logf0_trend(dF0); trend_u, vu, lfu = logf0_trend(F0)
    wtrend = warp(trend_d, src_a, src_b, len(F0), tgt_a, tgt_b)
    F0_B = np.where(vu, np.exp(wtrend), F0)
    F0_B2 = np.where(vu, np.exp(lfu - trend_u + wtrend), F0)
    N_C = warp(dN, src_a, src_b, len(N), tgt_a, tgt_b)
    N_C2 = N - smooth(N) + warp(smooth(dN), src_a, src_b, len(N), tgt_a, tgt_b)
    row = {'text': h['text'], 'donor': ds}
    for tag, F, Nx in (('A', F0, N), ('B', F0_B, N), ('B2', F0_B2, N), ('C', F0_B, N_C), ('C2', F0_B2, N_C2)):
        a = decode(te, dur, F, Nx, ref_s); row[tag] = round(dtw_dist(ref, a), 2)
        write_wav(f'../unit-bank/eval/h{k}-phrase-{tag}', a)
    rows.append(row); print(json.dumps(row, ensure_ascii=False), flush=True)
print('mean', {t: round(float(np.mean([r[t] for r in rows])), 2) for t in ('A', 'B', 'B2', 'C', 'C2')})
(BANK / 'eval' / 'phrase-results.json').write_text(json.dumps(rows, indent=1, ensure_ascii=False), encoding='utf-8')
