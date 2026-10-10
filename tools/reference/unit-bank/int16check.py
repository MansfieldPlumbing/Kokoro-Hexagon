"""int16 t_en in the bank against float: tensor SNR, and decoder output with int16 vs float t_en (same F0/N/dur)."""
import json, pathlib, sys
import numpy as np
SCR = pathlib.Path(sys.argv[1]); sys.argv = [sys.argv[0], 'none', str(SCR)]
src = open(SCR / 'bank.py', encoding='utf-8').read()
exec(compile(src.split("if MODE == 'capture':")[0], 'bank.py', 'exec'))
exec(compile(src[src.index('# ---------- metrics / pictures'):src.index("if MODE == 'render':")], 'bank.py', 'exec'))
BANK = REPO / 'build' / 'unit-bank'; order = json.loads((BANK / 'order.json').read_text(encoding='utf-8'))
z = np.load(BANK / 'chunk-0000.npz')
for s in range(3):
    ph = order[s]['phonemes']; cap = stock(ph); a, b = int(z['tok_off'][s]), int(z['tok_off'][s + 1])
    q = z['t_en'][:, a:b].astype(np.float32) * z['scale'][:, None]
    tsnr = 10 * np.log10((cap['t_en'] ** 2).sum() / ((cap['t_en'] - q) ** 2).sum())
    ref_s = pack[len(ph) - 1]
    x = decode(cap['t_en'], cap['dur'], cap['F0'], cap['N'], ref_s); y = decode(q, cap['dur'], cap['F0'], cap['N'], ref_s)
    same_dur = np.array_equal(cap['dur'], z['dur'][a:b])
    print(f'sentence {s}: tokens {b - a}, t_en int16 SNR {tsnr:.1f} dB, PCM SNR float vs int16 {snr(x, y) if "snr" in dir() else 0:.1f}, '
          f'mel {dtw_dist(x, y):.3f}, durations reproduce {same_dur}')
