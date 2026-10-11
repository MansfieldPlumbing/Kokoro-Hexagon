"""Render held-out targets: stock (evaluation only) and the PowerShell selections per bank size through the unchanged
stock decoder; log-mel DTW distance to stock; WAVs and one spectrogram PNG per target."""
import json, pathlib, sys, time
import numpy as np
sys.argv = [sys.argv[0], 'none', sys.argv[1]]
SCR = pathlib.Path(sys.argv[2])
exec(compile(open(SCR / 'bank.py', encoding='utf-8').read().split("if MODE == 'capture':")[0], 'bank.py', 'exec'))
src = open(SCR / 'bank.py', encoding='utf-8').read()
exec(compile(src[src.index('# ---------- metrics / pictures'):src.index("if MODE == 'render':")], 'bank.py', 'exec'))
BANK = REPO / 'build' / 'unit-bank'; OUT2 = BANK / 'eval'; OUT2.mkdir(exist_ok=True)
sel = json.loads((SCR / 'big-selections.json').read_text(encoding='utf-8-sig'))
cache = {}
def chunk(c):
    if c not in cache: z = np.load(BANK / f'chunk-{c:04d}.npz'); cache[c] = {k: z[k] for k in z.files}
    return cache[c]
def unit(s, i):
    z = chunk(s // 1000); l = s % 1000; t = int(z['tok_off'][l]) + i
    f = int(z['frm_off'][l]) + int(z['dur'][z['tok_off'][l]:t].sum()); d = int(z['dur'][t])
    return z['t_en'][:, t].astype(np.float32) * z['scale'], d, z['f0'][2 * f:2 * (f + d)].astype(np.float32), z['n'][2 * f:2 * (f + d)].astype(np.float32)
held = json.loads((SCR / 'heldout.json').read_text(encoding='utf-8-sig'))
table = {}
for k, h in enumerate(held):
    ph = h['phonemes']; ref_s = pack[len(ph) - 1]; cap = stock(ph)
    globals()['SEED'] = 17; ref = decode(cap['t_en'], cap['dur'], cap['F0'], cap['N'], ref_s)
    globals()['SEED'] = 18; alt = decode(cap['t_en'], cap['dur'], cap['F0'], cap['N'], ref_s); globals()['SEED'] = 17
    write_wav(f'../unit-bank/eval/h{k}-stock', ref); pics = [logmel(ref)]
    row = {'text': h['text'], 'floor': round(dtw_dist(ref, alt), 2)}
    for size, r in sel.items():
        picks = r['picks'][k]['path']; us = [unit(p['s'], p['i']) for p in picks]
        t0 = time.perf_counter()
        te = np.stack([u[0] for u in us], 1); dur = np.array([u[1] for u in us]); F0 = np.concatenate([u[2] for u in us]); N = np.concatenate([u[3] for u in us])
        asm = time.perf_counter() - t0
        a = decode(te, dur, F0, N, ref_s); write_wav(f'../unit-bank/eval/h{k}-bank{r["sentences"]}', a); pics.append(logmel(a))
        row[str(r['sentences'])] = round(dtw_dist(ref, a), 2); row['asm_ms'] = round(asm * 1000, 2)
        # Evaluation-only decomposition on stock durations: which selected tensor carries the distance?
        def fit(v, d): return np.interp(np.linspace(0, len(v) - 1, 2 * d), np.arange(len(v)), v)
        sd = cap['dur']; uF = np.concatenate([fit(u[2], d) for u, d in zip(us, sd)]); uN = np.concatenate([fit(u[3], d) for u, d in zip(us, sd)])
        for tag, F, Nx in (('t_en', cap['F0'], cap['N']), ('t_en+N', cap['F0'], uN), ('t_en+N+F0', uF, uN)):
            row[f'{r["sentences"]}:{tag}'] = round(dtw_dist(ref, decode(te, sd, F, Nx, ref_s)), 2)
    write_png(OUT2 / f'h{k}-spectrograms.png', pics)
    table[k] = row; print(json.dumps(row, ensure_ascii=False), flush=True)
(OUT2 / 'results.json').write_text(json.dumps(table, indent=1, ensure_ascii=False), encoding='utf-8')
cols = [str(r['sentences']) for r in sel.values()]
print('mean', {c: round(float(np.mean([t[c] for t in table.values()])), 2) for c in ['floor', *cols]})
