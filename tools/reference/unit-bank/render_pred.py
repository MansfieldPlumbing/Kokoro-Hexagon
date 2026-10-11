"""Render the nine held-out sentences with predicted per-token N and log F0 (Measure-ProsodyFeatures.ps1 levels) on
stock durations and on predicted durations; sampled t_en; N detail = phoneme-mean 8-point shape shifted to the
predicted token mean; F0 = predicted token level on the selected units' voicing."""
import json, pathlib, sys
import numpy as np
SCR = pathlib.Path(sys.argv[1])
exec(compile(open(SCR / 'contour_ceiling.py', encoding='utf-8').read().split("rel = 1 - np.exp")[0], 'contour_ceiling.py', 'exec'))
pred = json.loads((BANK / 'prosody-predictions.json').read_text(encoding='utf-8-sig'))
names = ['phone', '+L1R1', '+R2', '+stress', '+wordclass', '+posInWord', '+punct', '+group', '+sentpos']
res = {}
for k, h in enumerate(held):
    pk = pred[k]
    if not pk['aligned']: print(k, 'unaligned'); continue
    ph = h['phonemes']; ref_s = pack[len(ph) - 1]; cap = stock(ph); sd = cap['dur']
    ref = decode(cap['t_en'], sd, cap['F0'], cap['N'], ref_s)
    picks = sel['picks'][k]['path']; us = [unit(p['s'], p['i']) for p in picks]; te = np.stack([u[0] for u in us], 1)
    toks = ['<', *ph, '>']; ctx = [(toks[i - 1] if i else '#', toks[i], toks[i + 1] if i + 1 < len(toks) else '#') for i in range(len(toks))]
    shapes = [look(accN, *c, accN[('1', c[1])][0] / accN[('1', c[1])][1]) for c in ctx]
    for lv in (0, 2, 8):
        P_ = np.array(pk['levels'][lv])
        for dmode in ('stock', 'pred'):
            dur = sd if dmode == 'stock' else np.maximum(1, np.round(P_[:, 2])).astype(int)
            uF = np.concatenate([fit(u[2], d) for u, d in zip(us, dur)]); voiced = uF > 10
            N = np.concatenate([np.interp(np.linspace(0, P - 1, 2 * d), np.arange(P), shp) - shp.mean() + P_[i, 0] for i, (shp, d) in enumerate(zip(shapes, dur))])
            LF = np.concatenate([np.full(2 * d, P_[i, 1]) for i, d in enumerate(dur)])
            F = np.where(voiced, np.exp(LF), uF)
            a = decode(te, dur, F.astype(np.float32), N.astype(np.float32), ref_s)
            res.setdefault(f'{names[lv]}/{dmode}-dur', []).append(dtw_dist(ref, a))
            if lv == 8 and dmode == 'pred': write_wav(f'../unit-bank/eval/h{k}-predicted-all', a)
    print(k, flush=True)
for key, v in res.items(): print(f'{key:24s} {np.mean(v):.2f}')
