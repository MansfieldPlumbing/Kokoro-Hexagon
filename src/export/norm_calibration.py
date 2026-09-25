"""Host experiment: predict whole-phrase generator AdaIN statistics before the first generator sample.

Usage: KOKORO_MODEL_DIR=<dir with kokoro-v1_0.pth, config.json, voices/> \\
       python -u norm_calibration.py <outdir> [--wav] [--per-bucket N] [--seed S]
       python norm_calibration.py <outdir> --summarize      # markdown tables from <outdir>/results.json

The decoder front (encode, decode) keeps its exact whole-phrase statistics. Every generator
AdaIN1d (noise_res and resblocks, 48 norms) is given supplied per-channel (mean, log std):
exact reference values (exactness check), or the prediction of one of four predictors fitted
on the train split only:
  fixed    pooled per-voice moments (causal_norm.py 'fixed', refit on train)
  mixture  per-channel speech and silence moments, mixed by the phrase's silence fraction
  ridge    ridge regression from scalar features known before the first generator sample
  ridge+pca  the same plus a PCA of the decoder-front output's per-channel mean and log std
Regularization (and PCA width) is chosen by 5-fold cross-validation inside train. The model,
SineGen sharing, statistics code path and metrics come from causal_norm.py. Phonemes come
from Misaki (Kokoro's G2P); the corpus is built from bench/ and the repository prose.
CPU only. Writes candidates.json, results.json, summary.md, phrase_stats.npz and
coefficients.npz (and, with --wav, holdout WAVs) to <outdir>; none of it belongs in the repository.
"""
import sys, json, pathlib, os, argparse, time, platform, hashlib, re, random, math

REPO = pathlib.Path(__file__).resolve().parents[2]
BUCKETS = (('<1 s', 0.0, 1.0), ('1-2.5 s', 1.0, 2.5), ('2.5-5 s', 2.5, 5.0), ('>5 s', 5.0, 1e9))
MIN_S, MAX_S = 0.3, 10.0
SHORT = ['Hello.', 'Yes.', 'Okay, thanks.', 'No.', 'Okay.', 'Thanks.', 'Hi.', 'Sure.', 'Right.', 'Got it.',
         'Thank you.', 'Yes, please.', 'Good morning.', 'Wait.', 'Hello?', 'Sorry?', 'Of course.', 'Not yet.']
PROSE = ['README.md', 'BRIEF.md', 'docs/DESIGN.md', 'docs/APPLIANCE.md', 'docs/FIRST-LIGHT.md', 'docs/SMA-SPEECH.md',
         'docs/MODEL-ASSEMBLY.md', 'docs/WINDOWS-COMPUTE-NODE.md']
PREDICTORS = ('fixed', 'mixture', 'ridge', 'ridge+pca')
SIL_IDS = set(range(16))                                        # boundary pad (0) and punctuation ; : , . ! ? — … " ( ) “ ” (not space, 16)
FEATURES = ('frames', 'log_frames', 'silence_frac', 'voiced_frac', 'logf0_mean', 'logf0_std', 'n_mean', 'n_std')

ap = argparse.ArgumentParser()
ap.add_argument('out'); ap.add_argument('--wav', action='store_true'); ap.add_argument('--summarize', action='store_true')
ap.add_argument('--per-bucket', type=int, default=110, help='phrases drawn per length bucket (all, if fewer)')
ap.add_argument('--seed', type=int, default=20260925)
A = ap.parse_args()
OUT = pathlib.Path(A.out); OUT.mkdir(parents=True, exist_ok=True)
bucket_of = lambda s: next(b for b, lo, hi in BUCKETS if lo <= s < hi)

# ---- summary (no model needed) ----------------------------------------------------------------
def summarize(R):
    L = []; w = L.append; H = [p for p in R['phrases'] if p['split'] == 'holdout']
    mean = lambda xs: sum(xs) / len(xs) if xs else float('nan')
    mx = lambda xs: max(xs) if xs else float('nan'); mn = lambda xs: min(xs) if xs else float('nan')
    w('### Corpus and split\n\n| bucket | train | holdout | seconds (min-max) | sources |\n| --- | ---: | ---: | --- | --- |')
    for b, _, _ in BUCKETS:
        P = [p for p in R['phrases'] if p['bucket'] == b]
        src = {}
        for p in P: src[p['source'].split('/')[0]] = src.get(p['source'].split('/')[0], 0) + 1
        w(f"| {b} | {sum(p['split'] == 'train' for p in P)} | {sum(p['split'] == 'holdout' for p in P)} | "
          f"{mn([p['seconds'] for p in P]):.2f}-{mx([p['seconds'] for p in P]):.2f} | "
          + ', '.join(f'{k} {v}' for k, v in sorted(src.items())) + ' |')
    w(f"| all | {sum(p['split'] == 'train' for p in R['phrases'])} | {len(H)} | "
      f"{min(p['seconds'] for p in R['phrases']):.2f}-{max(p['seconds'] for p in R['phrases']):.2f} | |")
    ex = [p['runs']['exact']['snr_db'] for p in H]; ex16 = [p['runs']['exact-fp16']['snr_db'] for p in H]
    w(f"\n### Exactness check (holdout, exact reference statistics through the supplied-statistics path)\n\n"
      f"| payload | min waveform SNR dB | mean waveform SNR dB | max log-mel dB |\n| --- | ---: | ---: | ---: |\n"
      f"| fp32 (mean, log std) | {min(ex):.1f} | {mean(ex):.1f} | {max(p['runs']['exact']['logmel_db'] for p in H):.4f} |\n"
      f"| fp16 (mean, log std) | {min(ex16):.1f} | {mean(ex16):.1f} | {max(p['runs']['exact-fp16']['logmel_db'] for p in H):.4f} |\n\n"
      f"Gate for the check: >= 100 dB. Result: {'PASS' if min(ex) >= 100 else 'FAIL'}.")
    runs = ['reseed'] + list(PREDICTORS)
    w('\n### End to end on the holdout: log-mel distance dB, mean / worst\n')
    w('| run | ' + ' | '.join(b for b, _, _ in BUCKETS) + ' | overall | gate |'); w('| --- |' + ' ---: |' * (len(BUCKETS) + 1) + ' --- |')
    for k in runs:
        cells = []; bm = []
        for b, _, _ in BUCKETS:
            v = [p['runs'][k]['logmel_db'] for p in H if p['bucket'] == b]; bm.append(mean(v)); cells.append(f'{mean(v):.2f} / {mx(v):.2f}')
        v = [p['runs'][k]['logmel_db'] for p in H]
        bm = [x for x in bm if x == x]; gate = '' if k == 'reseed' else ('PASS' if mean(v) <= 1.0 and max(bm) <= 1.5 else 'FAIL')
        w(f'| {k} | ' + ' | '.join(cells) + f' | {mean(v):.2f} / {max(v):.2f} | {gate} |')
    w('\n### End to end on the holdout: waveform SNR dB, mean / worst\n')
    w('| run | ' + ' | '.join(b for b, _, _ in BUCKETS) + ' | overall |'); w('| --- |' + ' ---: |' * (len(BUCKETS) + 1))
    for k in runs:
        cells = []
        for b, _, _ in BUCKETS:
            v = [p['runs'][k]['snr_db'] for p in H if p['bucket'] == b]; cells.append(f'{mean(v):.1f} / {mn(v):.1f}')
        v = [p['runs'][k]['snr_db'] for p in H]
        w(f'| {k} | ' + ' | '.join(cells) + f' | {mean(v):.1f} / {min(v):.1f} |')
    F = R['fit']
    w('\n### Hyperparameters (5-fold CV inside train; loss = mean over targets of MSE / target variance)\n')
    w('| predictor | choice | CV loss | train-mean baseline CV loss |\n| --- | --- | ---: | ---: |')
    for k in ('ridge', 'ridge+pca'):
        c = F[k]; w(f"| {k} | alpha={c['alpha']:g}" + (f", PCA k={c['k']}" if 'k' in c else '') + f" | {c['cv_loss']:.3f} | {F['cv_baseline']:.3f} |")
    w('\n### Per-layer prediction error on the holdout (mean over phrases and channels)\n')
    w('|mean error| / reference std, then |log-std error| (natural log). Reference statistics are those of the '
      'reference run; the error is measured before any propagation.\n')
    w('| layer | ch | ' + ' | '.join(f'{k} mean' for k in PREDICTORS) + ' | ' + ' | '.join(f'{k} logstd' for k in PREDICTORS) + ' |')
    w('| --- | ---: |' + ' ---: |' * (2 * len(PREDICTORS)))
    E = R['layer_error']
    for n in R['gen_layers']:
        w(f"| {n.replace('generator.', '')} | {R['channels'][n]} | " + ' | '.join(f"{E[k][n]['mean']:.3f}" for k in PREDICTORS) + ' | '
          + ' | '.join(f"{E[k][n]['logstd']:.3f}" for k in PREDICTORS) + ' |')
    for g, lab in (('noise', 'noise_res'), ('gen0', 'stage 1'), ('gen1', 'stage 2')):
        ns = [n for n in R['gen_layers'] if R['group'][n] == g]
        w(f'| **{lab} mean** | | ' + ' | '.join(f"{mean([E[k][n]['mean'] for n in ns]):.3f}" for k in PREDICTORS) + ' | '
          + ' | '.join(f"{mean([E[k][n]['logstd'] for n in ns]):.3f}" for k in PREDICTORS) + ' |')
    best = R['best']
    w(f'\n### Attribution for {best}: predicted statistics in one stage, exact elsewhere (holdout)\n')
    w('| stage predicted | log-mel dB mean / worst | waveform SNR dB mean / worst | ' + ' | '.join(f'{b} log-mel mean' for b, _, _ in BUCKETS) + ' |')
    w('| --- | ---: | ---: |' + ' ---: |' * len(BUCKETS))
    for g, lab in (('gen0', 'stage 1 (resblocks 0-2, 800 Hz)'), ('gen1', 'stage 2 (resblocks 3-5, 4800 Hz)'), ('noise', 'noise_res (both stages)')):
        k = f'only-{g}/{best}'; v = [p['runs'][k]['logmel_db'] for p in H]; s = [p['runs'][k]['snr_db'] for p in H]
        w(f'| {lab} | {mean(v):.2f} / {max(v):.2f} | {mean(s):.1f} / {min(s):.1f} | '
          + ' | '.join(f"{mean([p['runs'][k]['logmel_db'] for p in H if p['bucket'] == b]):.2f}" for b, _, _ in BUCKETS) + ' |')
    k = best; v = [p['runs'][k]['logmel_db'] for p in H]
    w(f'| all generator norms | {mean(v):.2f} / {max(v):.2f} | {mean([p["runs"][k]["snr_db"] for p in H]):.1f} / '
      f'{min(p["runs"][k]["snr_db"] for p in H):.1f} | '
      + ' | '.join(f"{mean([p['runs'][k]['logmel_db'] for p in H if p['bucket'] == b]):.2f}" for b, _, _ in BUCKETS) + ' |')
    S = R['sizes']
    w(f"\n### Sizes\n\nStatistics payload per phrase: {S['channels']} generator channels x 2 values (mean, log std) = "
      f"{S['payload_fp32']} bytes fp32, {S['payload_fp16']} bytes fp16.\n")
    w('| predictor | coefficients | bytes fp32 |\n| --- | ---: | ---: |')
    for k in PREDICTORS: w(f"| {k} | {S['coef'][k]} | {4 * S['coef'][k]} |")
    t = R['timing']
    w(f"\nRuntime: {t['wall_s']:.0f} s total; {t['decoder_runs']} decoder runs at {t['s_per_run']:.2f} s each on average "
      f"({t['s_per_audio_s']:.3f} s per second of audio); fitting {t['fit_s']:.1f} s.")
    w('\n### Holdout phrases, log-mel dB per run\n')
    w('| id | bucket | s | frames | silence | ' + ' | '.join(runs) + ' | phonemes |'); w('| --- | --- | ---: | ---: | ---: |' + ' ---: |' * len(runs) + ' --- |')
    for p in sorted(H, key=lambda p: p['seconds']):
        w(f"| {p['id']} | {p['bucket']} | {p['seconds']:.2f} | {p['frames']} | {p['features']['silence_frac']:.2f} | "
          + ' | '.join(f"{p['runs'][k]['logmel_db']:.2f}" for k in runs) + f" | `{p['phonemes']}` |")
    w('\n<details><summary>Full corpus (id, split, seconds, frames, tokens, source, text, phonemes)</summary>\n')
    w('| id | split | s | frames | tokens | source | text | phonemes |\n| --- | --- | ---: | ---: | ---: | --- | --- | --- |')
    for p in sorted(R['phrases'], key=lambda p: p['seconds']):
        w(f"| {p['id']} | {p['split']} | {p['seconds']:.2f} | {p['frames']} | {p['tokens']} | {p['source']} | "
          f"{p['text'].replace('|', '/')} | `{p['phonemes']}` |")
    w('\n</details>')
    return '\n'.join(L)
if A.summarize:
    print(summarize(json.loads((OUT / 'results.json').read_text(encoding='utf-8')))); sys.exit(0)

# ---- corpus candidates: text units from the repository, phonemized by Misaki ---------------------
def sentences(t):
    return [s.strip() for s in re.split(r'(?<=[.!?])\s+', t.strip()) if s.strip()]
def clean(t):                                                  # plain spoken prose only
    return bool(re.fullmatch(r"[A-Za-z0-9 ,.;:!?'’\-—()]+", t)) and re.search(r'[A-Za-z]', t) and len(t.split()) <= 45
def text_units():
    U = [('short', t) for t in SHORT]
    lf = json.loads((REPO / 'bench' / 'long-form.json').read_text(encoding='utf-8'))
    for case in lf['cases']:
        S = []
        for seg in case['segments']: S += sentences(seg['text']) if 'text' in seg else seg['lines']
        src = f"bench/long-form/{case['id']}"
        U += [(src, s) for s in S]
        U += [(src, c) for s in S for c in re.split(r'(?<=[,;:])\s+', s) if c != s]
        U += [(src, ' '.join(S[i:i + n])) for n in (2, 3, 4, 5, 6) for i in range(len(S) - n + 1)]
    for f in PROSE:
        text = (REPO / f).read_text(encoding='utf-8'); paras = []; cur = []
        for line in text.splitlines():
            s = line.strip()
            if s.startswith('#'):
                U.append((f'prose/{f}', s.lstrip('#').strip())); s = ''
            if not s or s.startswith(('|', '```', '>', '<')):
                if cur: paras.append(' '.join(cur)); cur = []
                continue
            cur.append(re.sub(r'^([-*]|\d+\.)\s+', '', s))
        if cur: paras.append(' '.join(cur))
        for p in paras:
            S = sentences(p); U += [(f'prose/{f}', s) for s in S]
            U += [(f'prose/{f}', ' '.join(S[i:i + 2])) for i in range(len(S) - 1)]
    seen = set(); out = []
    for src, t in U:
        t = re.sub(r'\s+', ' ', t).strip()
        if t and t not in seen and clean(t): seen.add(t); out.append((src, t))
    return out

CAND = OUT / 'candidates.json'
if not CAND.exists():
    from misaki import en, espeak                              # real G2P; causal_norm stubs misaki afterwards
    g2p = en.G2P(trf=False, british=False, fallback=espeak.EspeakFallback(british=False), unk='')
    cands = [{'source': src, 'text': t, 'phonemes': g2p(t)[0]} for src, t in text_units()]
    for e in json.loads((REPO / 'bench' / 'phrases.json').read_text(encoding='utf-8')):     # verbatim phonemes
        cands.append({'source': 'bench/phrases', 'text': e['id'], 'phonemes': e['phonemes']})
    for e in json.loads((REPO / 'bench' / 'corpus.json').read_text(encoding='utf-8')):
        cands.append({'source': 'bench/corpus', 'text': e['text'], 'phonemes': e['phonemes']})
    for e in json.loads((REPO / 'bench' / 'paralinguistic.json').read_text(encoding='utf-8')):
        cands.append({'source': 'bench/paralinguistic', 'text': e['id'], 'phonemes': e['phonemes']})
    import misaki
    CAND.write_text(json.dumps({'misaki': misaki.__version__, 'candidates': cands}, ensure_ascii=False, indent=0), encoding='utf-8')
CANDS = json.loads(CAND.read_text(encoding='utf-8'))

# ---- model, statistics code path and metrics: shared with causal_norm.py -------------------------
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import numpy as np, torch
import causal_norm as cn
from importlib.metadata import version
cn.load(os.environ['KOKORO_MODEL_DIR'])
km, dec, gen, ST = cn.km, cn.dec, cn.gen, cn.ST
GEN = [n for n in cn.NAMES.values() if n in cn.SCOPES['gen']]
t_start = time.time(); RUN_S = [0.0, 0, 0.0]            # decoder seconds, runs, audio seconds

def token_ids(ph): return [0] + [cn.cfg['vocab'][c] for c in ph if c in cn.cfg['vocab']] + [0]
def frames(ids):                                               # duration predictor only (forward_with_tokens, first half)
    x = torch.tensor([ids]); n = torch.tensor([x.shape[-1]]); mask = torch.zeros_like(x, dtype=torch.bool)
    with torch.no_grad():
        s = cn.pack[len(ids) - 2][:, 128:]
        d_en = km.bert_encoder(km.bert(x, attention_mask=(~mask).int())).transpose(-1, -2)
        d = km.predictor.text_encoder(d_en, s, n, mask); h, _ = km.predictor.lstm(d)
        dur = torch.round(torch.sigmoid(km.predictor.duration_proj(h)).sum(-1)).clamp(min=1).long()
    return int(dur.sum())
def run(*a, **k):
    t = time.time(); r = cn.run(*a, **k); RUN_S[0] += time.time() - t; RUN_S[1] += 1; RUN_S[2] += a[0]['asr'].shape[-1] / cn.FPS; return r

# ---- corpus selection: stratified by predicted length, fixed seed ---------------------------------
rng = random.Random(A.seed); pool = {b: [] for b, _, _ in BUCKETS}; seen = set()
for c in CANDS['candidates']:
    ids = token_ids(c['phonemes'])
    if c['phonemes'] in seen or len(ids) > 512 or len(ids) < 3: continue
    seen.add(c['phonemes']); T = frames(ids); sec = T / cn.FPS
    if MIN_S <= sec <= MAX_S: pool[bucket_of(sec)].append(dict(c, frames=T, seconds=sec, tokens=len(ids)))
print('candidates per bucket:', {b: len(v) for b, v in pool.items()}, f'[{time.time() - t_start:.0f} s]', flush=True)
MUST = {'short', 'bench/corpus', 'bench/phrases', 'bench/paralinguistic'}
FORCE_HOLDOUT = {'Hello.', 'Yes.', 'Okay, thanks.', 'breath-h'}          # named short utterances; the only sub-1 s item
PH = []
for b, _, _ in BUCKETS:
    must = [c for c in pool[b] if c['source'] in MUST]; rest = [c for c in pool[b] if c['source'] not in MUST]
    take = must + rng.sample(rest, max(0, min(len(rest), A.per_bucket - len(must))))
    forced = {i for i, c in enumerate(take) if c['text'] in FORCE_HOLDOUT}
    free = [i for i in range(len(take)) if i not in forced]
    ho = forced | set(rng.sample(free, max(0, round(0.2 * len(take)) - len(forced))))
    for i, c in enumerate(take): PH.append(dict(c, bucket=b, split='holdout' if i in ho else 'train'))
for i, p in enumerate(PH): p['id'] = f'c{i:03d}'
print(f'corpus: {len(PH)} phrases, holdout {sum(p["split"] == "holdout" for p in PH)}', flush=True)

# ---- pass 1: reference run per phrase; statistics, masked moments, features ----------------------
def features(inp):
    ids = inp['ids']; dur = inp['dur']; T = int(dur.sum())
    sil = torch.tensor([i in SIL_IDS for i in ids]); sil40 = torch.repeat_interleave(sil, dur)
    f0 = inp['F0'].reshape(-1).double(); v = f0 > 10.0                     # SineGen voiced threshold
    lf = torch.log(f0[v]) if v.any() else torch.zeros(1, dtype=torch.float64)
    N = inp['N'].reshape(-1).double()
    return {'frames': T, 'log_frames': math.log(T), 'silence_frac': float(sil40.double().mean()), 'voiced_frac': float(v.double().mean()),
            'logf0_mean': float(lf.mean()), 'logf0_std': float(lf.std(unbiased=False)), 'n_mean': float(N.mean()),
            'n_std': float(N.std(unbiased=False))}, sil40

REF = {}; CH = {}
def reference(p):
    ids = token_ids(p['phonemes']); _, inp = cn.prepare(p['phonemes']); inp['ids'] = ids; T = inp['asr'].shape[-1]; ST['T'] = T
    assert T == p['frames'], (p['id'], T, p['frames'])
    feat, sil40 = features(inp); rec = {'mean': {}, 'var': {}, 'mix': {}}
    def observe(name, x):
        if name not in cn.SCOPES['gen']: return
        xd = x[0].double(); L = xd.shape[-1]; CH[name] = xd.shape[0]
        rec['mean'][name] = xd.mean(-1); rec['var'][name] = xd.var(-1, unbiased=False)
        m = sil40[torch.clamp((torch.arange(L) * T) // L, max=T - 1)].double()
        rec['mix'][name] = torch.stack([(xd * (1 - m)).sum(-1), (xd * xd * (1 - m)).sum(-1), (xd * m).sum(-1), (xd * xd * m).sum(-1)]), \
            (float((1 - m).sum()), float(m.sum()))
    ST['observe'] = observe
    y, _ = run(inp); ST['observe'] = None
    with torch.no_grad():
        fo = cn.front(inp['asr'], inp['F0'], inp['N'], inp['s'])[0].double()
    feat_front = torch.cat([fo.mean(-1), 0.5 * torch.log(fo.var(-1, unbiased=False).clamp_min(1e-20))]).numpy()
    return y, inp, feat, feat_front, rec

stats_mean, stats_logstd, SCAL, FRONT, MIX = [], [], [], [], []
HOLD = {}
for i, p in enumerate(PH):
    t = time.time()
    y, inp, feat, ff, rec = reference(p)
    p['features'] = feat
    stats_mean.append(np.concatenate([rec['mean'][n].numpy() for n in GEN]))
    stats_logstd.append(np.concatenate([0.5 * np.log(np.maximum(rec['var'][n].numpy(), 1e-30)) for n in GEN]))
    SCAL.append([feat[k] for k in FEATURES]); FRONT.append(ff); MIX.append(rec['mix'])
    if p['split'] == 'holdout': HOLD[p['id']] = (y, inp, {n: (rec['mean'][n], rec['var'][n]) for n in GEN})
    print(f"pass1 {i + 1:3d}/{len(PH)} {p['id']} {p['split']:7s} {p['bucket']:8s} T={p['frames']:4d} "
          f"sil={feat['silence_frac']:.2f} {time.time() - t:5.2f} s [{time.time() - t_start:.0f} s]", flush=True)
Ym, Yl, X, Z = np.array(stats_mean), np.array(stats_logstd), np.array(SCAL), np.array(FRONT)
OFF = np.cumsum([0] + [CH[n] for n in GEN]); SL = {n: slice(OFF[i], OFF[i + 1]) for i, n in enumerate(GEN)}
np.savez(OUT / 'phrase_stats.npz', ids=np.array([p['id'] for p in PH]), layers=np.array(GEN), offsets=OFF,
         mean=Ym, logstd=Yl, scalar_features=X, scalar_names=np.array(FEATURES), front_features=Z)

# ---- fit on train only ---------------------------------------------------------------------------
t_fit = time.time()
tr = np.array([p['split'] == 'train' for p in PH]); ho = ~tr
Y = np.concatenate([Ym, Yl], 1); Q = Ym.shape[1]
def pooled(rows_idx):                                # fixed: frame-weighted moments over train (as causal_norm 'fixed')
    s1 = np.zeros(Q); s2 = np.zeros(Q); n = np.zeros(Q)
    for i in rows_idx:
        for name in GEN:
            (m, cnt) = MIX[i][name]; sl = SL[name]; mm = m.numpy()
            s1[sl] += mm[0] + mm[2]; s2[sl] += mm[1] + mm[3]; n[sl] += cnt[0] + cnt[1]
    mu = s1 / n; return mu, 0.5 * np.log(np.maximum(s2 / n - mu * mu, 1e-30))
def mixture_fit(rows_idx):
    S = np.zeros((4, Q)); n = np.zeros((2, Q))
    for i in rows_idx:
        for name in GEN:
            (m, cnt) = MIX[i][name]; sl = SL[name]; S[:, sl] += m.numpy(); n[0, sl] += cnt[0]; n[1, sl] += cnt[1]
    return S[0] / n[0], S[1] / n[0], S[2] / np.maximum(n[1], 1), S[3] / np.maximum(n[1], 1)
def mixture_predict(M, f):
    m1s, m2s, m1q, m2q = M; f = np.asarray(f)[:, None]
    mu = (1 - f) * m1s + f * m1q; sq = (1 - f) * m2s + f * m2q
    return np.concatenate([mu, 0.5 * np.log(np.maximum(sq - mu * mu, 1e-30))], 1)

def ridge_fit(Xtr, Ytr, alpha):
    mx, sx = Xtr.mean(0), Xtr.std(0) + 1e-12; my = Ytr.mean(0); Xs = (Xtr - mx) / sx
    U, s, Vt = np.linalg.svd(Xs, full_matrices=False)
    B = Vt.T @ ((s / (s * s + alpha))[:, None] * (U.T @ (Ytr - my)))
    return {'mx': mx, 'sx': sx, 'my': my, 'B': B}
def ridge_predict(m, Xq): return m['my'] + ((Xq - m['mx']) / m['sx']) @ m['B']
def pca_fit(Ztr, k):
    mz, sz = Ztr.mean(0), Ztr.std(0) + 1e-12; _, _, Vt = np.linalg.svd((Ztr - mz) / sz, full_matrices=False)
    return {'mz': mz, 'sz': sz, 'V': Vt[:k].T}
def pca_apply(m, Zq): return ((Zq - m['mz']) / m['sz']) @ m['V']
def design(idx_fit, idx_q, k):
    if k == 0: return X[idx_fit], X[idx_q], None
    P = pca_fit(Z[idx_fit], k)
    return np.concatenate([X[idx_fit], pca_apply(P, Z[idx_fit])], 1), np.concatenate([X[idx_q], pca_apply(P, Z[idx_q])], 1), P

TR = np.nonzero(tr)[0]; HO = np.nonzero(ho)[0]
fold = np.array([i % 5 for i in range(len(TR))]); np.random.default_rng(A.seed).shuffle(fold)
ALPHAS = [10.0 ** e for e in np.arange(-3, 4.01, 0.5)]; KS = (2, 4, 8, 16, 32)
def cv_loss(k, alpha):
    err = 0.0
    for f in range(5):
        a, b = TR[fold != f], TR[fold == f]; Xa, Xb, _ = design(a, b, k)
        pred = ridge_predict(ridge_fit(Xa, Y[a], alpha), Xb) if alpha is not None else np.repeat(Y[a].mean(0, keepdims=True), len(b), 0)
        err += (((pred - Y[b]) ** 2).mean(0) / (Y[TR].var(0) + 1e-20)).mean() * len(b)
    return err / len(TR)
FIT = {'cv_baseline': cv_loss(0, None)}
for name, grid in (('ridge', [(0, a) for a in ALPHAS]), ('ridge+pca', [(k, a) for k in KS for a in ALPHAS])):
    scores = [(cv_loss(k, a), k, a) for k, a in grid]; l, k, a = min(scores)
    FIT[name] = {'alpha': a, 'cv_loss': l, **({'k': k} if name == 'ridge+pca' else {})}
    print(f'cv {name}: alpha={a:g} k={k} loss={l:.4f} (baseline {FIT["cv_baseline"]:.4f})', flush=True)
fx_mu, fx_ls = pooled(TR)
MIXM = mixture_fit(TR)
R0 = ridge_fit(X[TR], Y[TR], FIT['ridge']['alpha'])
Xa, Xb, PCA = design(TR, HO, FIT['ridge+pca']['k']); R1 = ridge_fit(Xa, Y[TR], FIT['ridge+pca']['alpha'])
PRED = {'fixed': np.repeat(np.concatenate([fx_mu, fx_ls])[None], len(HO), 0),
        'mixture': mixture_predict(MIXM, X[HO, FEATURES.index('silence_frac')]),
        'ridge': ridge_predict(R0, X[HO]), 'ridge+pca': ridge_predict(R1, Xb)}
t_fit = time.time() - t_fit
COEF = {'fixed': 2 * Q, 'mixture': 4 * Q,
        'ridge': R0['B'].size + R0['my'].size + 2 * R0['mx'].size,
        'ridge+pca': R1['B'].size + R1['my'].size + 2 * R1['mx'].size + PCA['V'].size + 2 * PCA['mz'].size}
np.savez(OUT / 'coefficients.npz', layers=np.array(GEN), offsets=OFF, features=np.array(FEATURES),
         fixed_mean=fx_mu, fixed_logstd=fx_ls, mix_m1_speech=MIXM[0], mix_m2_speech=MIXM[1], mix_m1_silence=MIXM[2], mix_m2_silence=MIXM[3],
         ridge_B=R0['B'], ridge_my=R0['my'], ridge_mx=R0['mx'], ridge_sx=R0['sx'],
         ridgepca_B=R1['B'], ridgepca_my=R1['my'], ridgepca_mx=R1['mx'], ridgepca_sx=R1['sx'],
         pca_V=PCA['V'], pca_mz=PCA['mz'], pca_sz=PCA['sz'])

# ---- per-layer prediction error (statistics space) -----------------------------------------------
sd_ref = np.exp(Yl[HO])
LERR = {k: {n: {'mean': float((np.abs(PRED[k][:, :Q][:, SL[n]] - Ym[HO][:, SL[n]]) / sd_ref[:, SL[n]]).mean()),
                'logstd': float(np.abs(PRED[k][:, Q:][:, SL[n]] - Yl[HO][:, SL[n]]).mean())} for n in GEN} for k in PREDICTORS}

# ---- holdout: end to end ---------------------------------------------------------------------------
def given(vec, dtype=np.float64):                               # (mean, log std) vector -> supplied (mean, var) per layer
    v = vec.astype(dtype).astype(np.float64); out = {}
    for n in GEN:
        mu = torch.from_numpy(v[:Q][SL[n]].copy()).view(1, -1, 1); ls = torch.from_numpy(v[Q:][SL[n]].copy()).view(1, -1, 1)
        out[n] = (mu, torch.exp(2 * ls))
    return out
def supplied(inp, G, active):
    ST['given'] = G; y, _ = run(inp, 'given', 0, active); ST['given'] = {}; return y
def logmel_db(r, y): return cn.logmel_db(r, y)
def wav(name, a):
    if A.wav: cn.write_wav(OUT / f'{name}.wav', a)
Pmap = {p['id']: p for p in PH}; HID = [PH[i]['id'] for i in HO]
for j, pid in enumerate(HID):                                   # exactness check first
    t = time.time(); p = Pmap[pid]; ref, inp, _ = HOLD[pid]; ST['T'] = inp['asr'].shape[-1]; ex = Y[HO[j]]
    runs = p['runs'] = {}
    runs['exact'] = cn.metrics(ref, supplied(inp, given(ex), cn.SCOPES['gen']))
    runs['exact-fp16'] = cn.metrics(ref, supplied(inp, given(ex, np.float16), cn.SCOPES['gen']))
    print(f"exact {j + 1:2d}/{len(HID)} {pid} {p['bucket']:8s} T={p['frames']:4d} fp32 {runs['exact']['snr_db']:.1f} dB  "
          f"fp16 {runs['exact-fp16']['snr_db']:.1f} dB  {time.time() - t:5.2f} s [{time.time() - t_start:.0f} s]", flush=True)
if min(Pmap[h]['runs']['exact']['snr_db'] for h in HID) < 100:
    (OUT / 'exactness_fail.json').write_text(json.dumps({h: Pmap[h]['runs'] for h in HID}, indent=1), encoding='utf-8')
    sys.exit('Exactness check failed: supplied exact statistics reproduce the reference below 100 dB. Stopping.')
for j, pid in enumerate(HID):
    t = time.time(); p = Pmap[pid]; ref, inp, _ = HOLD[pid]; ST['T'] = inp['asr'].shape[-1]; runs = p['runs']
    y, _ = run(inp, har=cn.source(inp, cn.SEED + 1)); runs['reseed'] = cn.metrics(ref, y)
    wav(f'{pid}_reference', ref); wav(f'{pid}_reseed', y)
    for k in PREDICTORS:
        y = supplied(inp, given(PRED[k][j]), cn.SCOPES['gen']); runs[k] = cn.metrics(ref, y); wav(f'{pid}_{k}', y)
    print(f"holdout {j + 1:2d}/{len(HID)} {pid} {p['bucket']:8s} T={p['frames']:4d}  "
          + '  '.join(f"{k}:{runs[k]['logmel_db']:.2f}" for k in ('reseed',) + PREDICTORS)
          + f"  {time.time() - t:5.2f} s [{time.time() - t_start:.0f} s]", flush=True)
H_lm = {k: np.mean([Pmap[h]['runs'][k]['logmel_db'] for h in HID]) for k in PREDICTORS}
BEST = min(H_lm, key=H_lm.get)
for j, pid in enumerate(HID):                                   # attribution: one stage predicted, others exact
    t = time.time(); p = Pmap[pid]; ref, inp, _ = HOLD[pid]; ST['T'] = inp['asr'].shape[-1]
    G = given(Y[HO[j]]); Gp = given(PRED[BEST][j])
    for g in ('gen0', 'gen1', 'noise'):
        mix = {n: (Gp[n] if n in cn.GROUPS[g] else G[n]) for n in GEN}
        p['runs'][f'only-{g}/{BEST}'] = cn.metrics(ref, supplied(inp, mix, cn.SCOPES['gen']))
    print(f'attrib {j + 1:2d}/{len(HID)} {pid} ' + '  '.join(f"{g}:{p['runs'][f'only-{g}/{BEST}']['logmel_db']:.2f}" for g in ('gen0', 'gen1', 'noise'))
          + f'  {time.time() - t:5.2f} s [{time.time() - t_start:.0f} s]', flush=True)

# ---- record --------------------------------------------------------------------------------------
sha = lambda f: hashlib.sha256(pathlib.Path(f).read_bytes()).hexdigest().upper()
results = {
    'phrases': PH, 'gen_layers': GEN, 'channels': {n: CH[n] for n in GEN}, 'group': {n: cn.group(n) for n in GEN},
    'fit': FIT, 'best': BEST, 'layer_error': LERR, 'features': FEATURES,
    'sizes': {'channels': Q, 'payload_fp32': 2 * Q * 4, 'payload_fp16': 2 * Q * 2, 'coef': COEF},
    'timing': {'wall_s': time.time() - t_start, 'decoder_runs': RUN_S[1], 's_per_run': RUN_S[0] / RUN_S[1],
               's_per_audio_s': RUN_S[0] / RUN_S[2], 'fit_s': t_fit},
    'provenance': {'model_dir_files': {f: sha(cn.M / f) for f in ('kokoro-v1_0.pth', 'config.json', f'voices/{cn.VOICE}.pt')},
                   'coefficients_sha256': sha(OUT / 'coefficients.npz'), 'phrase_stats_sha256': sha(OUT / 'phrase_stats.npz'),
                   'candidates_sha256': sha(CAND), 'voice': cn.VOICE, 'seed': A.seed, 'sinegen_seed': cn.SEED,
                   'kokoro': version('kokoro'), 'misaki': CANDS['misaki'], 'torch': torch.__version__, 'numpy': np.__version__,
                   'python': platform.python_version(), 'threads': torch.get_num_threads()}}
for p in PH: p.pop('runs', None) if p['split'] == 'train' else None
(OUT / 'results.json').write_text(json.dumps(results, indent=1, ensure_ascii=False), encoding='utf-8')
(OUT / 'summary.md').write_text(summarize(results), encoding='utf-8')
print(json.dumps({k: results[k] for k in ('fit', 'best', 'sizes', 'timing', 'provenance')}, indent=1), flush=True)
