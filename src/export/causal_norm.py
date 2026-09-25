"""Host experiment: can the Kokoro decoder use causal AdaIN statistics instead of whole-phrase ones?

Usage: KOKORO_MODEL_DIR=<dir with kokoro-v1_0.pth, config.json, voices/> \\
       python causal_norm.py <outdir> [--wav] [--phrases N]
       python causal_norm.py <outdir> --summarize        # markdown tables from <outdir>/results.json

Every AdaIN1d InstanceNorm in the decoder front (encode, decode) and the iSTFTNet generator
(resblocks, noise_res) is swapped for a statistics variant: cumulative from phrase start, with
L frames of lookahead at the layer's own rate, exponential moving average, fixed per-voice
population statistics (leave-one-out over the corpus), and cumulative seeded with that prior.
The harmonic source (SineGen) is computed once per phrase and fed to every run, so waveform
comparison is phase-valid. CPU only; no device, no Hexagon. Writes results.json (and, with
--wav, 16-bit WAVs for listening) to <outdir>; nothing it writes belongs in the repository.
"""
import sys, types, json, math, hashlib, pathlib, os, argparse, time, platform
sys.modules['misaki'] = types.ModuleType('misaki')          # pipeline import only; G2P unused here
for n in ('en', 'espeak'):                                     # MToken: annotations are eager before Python 3.14
    setattr(sys.modules['misaki'], n, types.SimpleNamespace(MToken=object))
import numpy as np, scipy, scipy.signal, torch, torch.nn.functional as F
import kokoro.istftnet as ist
from kokoro.model import KModel
from importlib.metadata import version

ap = argparse.ArgumentParser()
ap.add_argument('out'); ap.add_argument('--wav', action='store_true'); ap.add_argument('--phrases', type=int, default=12)
ap.add_argument('--summarize', action='store_true')
A = ap.parse_args()
OUT = pathlib.Path(A.out); OUT.mkdir(parents=True, exist_ok=True)

def summarize(R):
    P = R['phrases']; mean = lambda xs: sum(xs) / len(xs)
    col = lambda k, f: [p['runs'][k][f] for p in P]
    L = []; w = L.append
    w('### Corpus\n\n| id | s | frames | tokens | phonemes |\n| --- | ---: | ---: | ---: | --- |')
    for p in P: w(f"| {p['id']} | {p['seconds']:.2f} | {p['frames']} | {p['tokens']} | `{p['phonemes']}` |")
    lat = R['latency_ms']
    w('\n### Whole-output metrics (mean over phrases; worst = largest log-mel distance)\n')
    w('| run | scope | waveform SNR dB | log-mel dB | worst log-mel dB | log-mel by quarter dB | norm lookahead ms (har ahead / streamed) |')
    w('| --- | --- | ---: | ---: | ---: | --- | --- |')
    keys = ['whole-replaced', 'reseed'] + [k for k in P[0]['runs'] if '/' in k and not k.startswith('only-')]
    for k in keys:
        sc, vn = (k.split('/') + [''])[:2] if '/' in k else ('', k)
        q = ' / '.join(f'{mean([p["runs"][k]["logmel_quarters"][i] for p in P]):.1f}' for i in range(4)) if 'logmel_quarters' in P[0]['runs'][k] else ''
        la = lat.get(k); la = f"{la['har_ahead']:.0f} / {la['streamed']:.0f}" if la else ('0' if sc else '')
        w(f"| {vn} | {sc} | {mean(col(k, 'snr_db')):.1f} | {mean(col(k, 'logmel_db')):.2f} | {max(col(k, 'logmel_db')):.2f} | {q} | {la} |")
    w('\n### Per-phrase log-mel distance, dB\n')
    sel = ['reseed', 'all/cum', 'all/la64', 'all/ema1600', 'gen/cum', 'gen/la4', 'gen/la64', 'gen/fixed', 'gen/seeded1000', 'all/fixed']
    w('| id | ' + ' | '.join(sel) + ' |'); w('| --- |' + ' ---: |' * len(sel))
    for p in P: w(f"| {p['id']} | " + ' | '.join(f"{p['runs'][k]['logmel_db']:.2f}" for k in sel) + ' |')
    w('\n### Attribution: one layer group non-whole at a time\n\n| group | stats | waveform SNR dB | log-mel dB | worst log-mel dB |\n| --- | --- | ---: | ---: | ---: |')
    for k in [k for k in P[0]['runs'] if k.startswith('only-')]:
        g, vn = k[5:].split('/')
        w(f"| {g} | {vn} | {mean(col(k, 'snr_db')):.1f} | {mean(col(k, 'logmel_db')):.2f} | {max(col(k, 'logmel_db')):.2f} |")
    probes = ['encode.norm1', 'decode.3.norm2', 'generator.noise_res.0.adain2.2', 'generator.resblocks.0.adain1.0',
              'generator.resblocks.2.adain2.2', 'generator.noise_res.1.adain2.2', 'generator.resblocks.3.adain1.0', 'generator.resblocks.5.adain2.2']
    w('\n### Per-layer activation SNR along the path, dB (AdaIN output vs reference, mean over phrases)\n')
    sel = ['all/cum', 'all/la64', 'all/ema400', 'all/fixed', 'gen/cum', 'gen/la64', 'gen/fixed', 'gen/seeded1000', 'only-gen1/cum', 'only-gen1/fixed']
    w('| layer | ' + ' | '.join(sel) + ' |'); w('| --- |' + ' ---: |' * len(sel))
    for n in probes:
        w(f'| {n} | ' + ' | '.join(f"{mean([p['runs'][k]['layer_snr'][n] for p in P]):.1f}" for k in sel) + ' |')
    w(f"\nExactness of the replacement path (whole-phrase statistics through the variant code): min layer SNR "
      f"{min(min(p['runs']['whole-replaced']['layer_snr'].values()) for p in P):.1f} dB, min output SNR {min(col('whole-replaced', 'snr_db')):.1f} dB.")
    c = R['conv_lookahead']
    w(f"\nConvolution (non-norm) lookahead, measured with causal norms: whole decoder {c['decoder_samples']['ms']:.1f} ms, "
      f"generator alone {c['generator_samples']['ms']:.1f} ms.")
    return '\n'.join(L)
if A.summarize:
    print(summarize(json.loads((OUT / 'results.json').read_text(encoding='utf-8')))); sys.exit(0)
M = pathlib.Path(os.environ['KOKORO_MODEL_DIR'])
REPO = pathlib.Path(__file__).resolve().parents[2]
SR, U, FPS = 24000, 600, 40.0                                  # asr frame = 600 samples = 25 ms
VOICE, SEED = 'af_heart', 0
LOOKAHEADS = (4, 8, 16, 32, 64)                                # frames at each layer's own rate
EMA_TAUS_MS = (100, 400, 1600)
torch.set_num_threads(os.cpu_count() or 1)

sha = lambda p: hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest().upper()
cfg = json.loads((M / 'config.json').read_text(encoding='utf-8'))
km = KModel(repo_id='hexgrad/Kokoro-82M', config=str(M / 'config.json'),
            model=str(M / 'kokoro-v1_0.pth'), disable_complex=True).eval()
dec, gen = km.decoder, km.decoder.generator

# ---- corpus: bench/corpus.json p01..p10 plus two long concatenations (same voice) ----------
corpus = {c['id']: c for c in json.loads((REPO / 'bench' / 'corpus.json').read_text(encoding='utf-8'))}
PHRASES = [(k, corpus[k]['phonemes']) for k in sorted(corpus)]
PHRASES += [('long1', ' '.join(corpus[k]['phonemes'] for k in ('p06', 'p08', 'p10'))),
            ('long2', ' '.join(corpus[k]['phonemes'] for k in ('p09', 'p05', 'p07', 'p03')))]
PHRASES = PHRASES[:A.phrases]

# ---- norm sites -----------------------------------------------------------------------------
NAMES = {id(m): n for n, m in dec.named_modules() if isinstance(m, ist.AdaIN1d)}
def group(n):
    if n.startswith(('encode', 'decode')): return 'front'
    if n.startswith('generator.noise_res'): return 'noise'
    return 'gen0' if int(n.split('.')[2]) < gen.num_kernels else 'gen1'
GROUPS = {g: {n for n in NAMES.values() if group(n) == g} for g in ('front', 'noise', 'gen0', 'gen1')}
SCOPES = {'all': set(NAMES.values()), 'gen': GROUPS['noise'] | GROUPS['gen0'] | GROUPS['gen1']}

ST = {'moments': None, 'prior': {}, 'name': None, 'mode': 'whole', 'p': 0, 'active': set(), 'T': 1, 'cap': None, 'ref': None, 'acc': None, 'len': {}}

def stats(x, mode, p, rate):
    """x [1,C,T] float64 -> (mean, biased var), broadcastable to x. Row t uses only what mode allows."""
    if mode == 'whole':
        return x.mean(-1, keepdim=True), x.var(-1, unbiased=False, keepdim=True)
    T = x.shape[-1]
    if mode == 'cum':                                          # frames [0, min(t+p, T-1)]
        idx = torch.clamp(torch.arange(T) + p, max=T - 1)
        n = (idx + 1).to(x.dtype)
        m1, m2 = x.cumsum(-1)[..., idx] / n, (x * x).cumsum(-1)[..., idx] / n
    elif mode in ('fixed', 'seeded'):                          # population prior (mu0, E[x^2]0) from other phrases
        mu0, sq0 = ST['prior'][ST['name']]
        if mode == 'fixed': return mu0, (sq0 - mu0 * mu0).clamp_min(0)
        n0 = p / 1000.0 * rate; n = torch.arange(1, T + 1, dtype=x.dtype)    # prior weighs p ms of frames
        m1 = (n0 * mu0 + x.cumsum(-1)) / (n0 + n); m2 = (n0 * sq0 + (x * x).cumsum(-1)) / (n0 + n)
    elif mode == 'ema':                                        # bias-corrected exponential weights, tau = p ms
        a = 1.0 - math.exp(-1.0 / (p / 1000.0 * rate)); b, d = [a], [1.0, -(1.0 - a)]
        xn = x.numpy(); w = scipy.signal.lfilter(b, d, np.ones(T))
        m1 = torch.from_numpy(scipy.signal.lfilter(b, d, xn, axis=-1) / w)
        m2 = torch.from_numpy(scipy.signal.lfilter(b, d, xn * xn, axis=-1) / w)
    else:
        raise ValueError(mode)
    return m1, (m2 - m1 * m1).clamp_min(0)

def adain(self, x, s):
    h = self.fc(s).view(s.size(0), -1, 1); gamma, beta = torch.chunk(h, 2, dim=1)
    name = NAMES.get(id(self))                                 # None: prosody predictor, left untouched
    if name is None: return (1 + gamma) * self.norm(x) + beta
    ST['len'][name] = x.shape[-1]; ST['name'] = name
    if ST.get('moments') is not None:                         # per-channel whole-phrase moments of the norm input
        xd = x.double(); ST['moments'][name] = (xd.sum(-1, keepdim=True), (xd * xd).sum(-1, keepdim=True), x.shape[-1])
    if name in ST['active']:
        xd = x.double(); mu, var = stats(xd, ST['mode'], ST['p'], x.shape[-1] / ST['T'] * FPS)
        y = ((xd - mu) / torch.sqrt(var + self.norm.eps)).float()
        y = y * self.norm.weight.view(1, -1, 1) + self.norm.bias.view(1, -1, 1)
    else:
        y = self.norm(x)
    o = (1 + gamma) * y + beta
    if ST['cap'] is not None: ST['cap'][name] = o.detach().clone()
    if ST['ref'] is not None:
        r = ST['ref'][name]; ST['acc'][name] = 10 * math.log10(float((r.double() ** 2).sum()) / max(float(((r - o).double() ** 2).sum()), 1e-30))
    return o
ist.AdaIN1d.forward = adain

def front(asr, F0_curve, N, s):
    F0 = dec.F0_conv(F0_curve.unsqueeze(1)); Nn = dec.N_conv(N.unsqueeze(1))
    x = dec.encode(torch.cat([asr, F0, Nn], 1), s)
    asr_res = dec.asr_res(asr); res = True
    for b in dec.decode:
        if res: x = torch.cat([x, asr_res, F0, Nn], 1)
        x = b(x, s)
        if b.upsample_type != 'none': res = False
    return x

def generator(x, s, har_source):                               # Generator.forward with the source lifted to an input
    g = gen; spec, phase = g.stft.transform(har_source); har = torch.cat([spec, phase], 1)
    for i in range(g.num_upsamples):
        x = F.leaky_relu(x, 0.1)
        xs_ = g.noise_res[i](g.noise_convs[i](har), s)
        x = g.ups[i](x)
        if i == g.num_upsamples - 1: x = g.reflection_pad(x)
        x = x + xs_
        acc = None
        for j in range(g.num_kernels):
            r = g.resblocks[i * g.num_kernels + j](x, s)
            acc = r if acc is None else acc + r
        x = acc / g.num_kernels
    x = g.conv_post(F.leaky_relu(x))
    n = g.post_n_fft // 2 + 1
    return g.stft.inverse(torch.exp(x[:, :n]), torch.sin(x[:, n:])).reshape(-1)

def run(inp, mode='whole', p=0, active=(), har=None, cap=None, ref=None):
    ST.update(mode=mode, p=p, active=set(active), cap=cap, ref=ref, acc={} if ref is not None else None)
    with torch.no_grad():
        y = generator(front(inp['asr'], inp['F0'], inp['N'], inp['s']), inp['s'], inp['har'] if har is None else har)
    acc = ST['acc']; ST.update(cap=None, ref=None, acc=None, active=set())
    return y.numpy().astype(np.float64), acc

# ---- metrics --------------------------------------------------------------------------------
def snr_db(r, p): return 10 * math.log10((r ** 2).sum() / max(((r - p) ** 2).sum(), 1e-30))
def mel_fb(n_fft=1024, n_mels=80, fmax=SR / 2):
    hz2m = lambda f: 2595 * np.log10(1 + f / 700); m2hz = lambda m: 700 * (10 ** (m / 2595) - 1)
    pts = m2hz(np.linspace(0, hz2m(fmax), n_mels + 2)); f = np.linspace(0, SR / 2, n_fft // 2 + 1)
    fb = np.zeros((n_mels, f.size))
    for i in range(n_mels):
        lo, c, hi = pts[i:i + 3]
        fb[i] = np.clip(np.minimum((f - lo) / (c - lo), (hi - f) / (hi - c)), 0, None)
    return fb
FB = mel_fb()
def logmel(a):
    S = torch.stft(torch.from_numpy(a), 1024, 256, window=torch.hann_window(1024, dtype=torch.float64), return_complex=True).abs() ** 2
    return 10 * np.log10(FB @ S.numpy() + 1e-12)
def logmel_db(r, p):
    """Mean |dB| over 80 mel bands x 10.7 ms frames; both floored at reference max - 80 dB."""
    R, P = logmel(r), logmel(p); fl = R.max() - 80
    return float(np.abs(np.maximum(R, fl) - np.maximum(P, fl)).mean())
def metrics(r, p): return {'snr_db': snr_db(r, p), 'logmel_db': logmel_db(r, p)}

def write_wav(path, a):
    import wave
    with wave.open(str(path), 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes((np.clip(a, -1, 1) * 32767).astype('<i2').tobytes())

# ---- variants -------------------------------------------------------------------------------
PRIOR_MS = 1000                                                # 'seeded': prior weighs this many ms of frames
VARIANTS = ([('cum', 'cum', 0)] + [(f'la{L}', 'cum', L) for L in LOOKAHEADS] + [(f'ema{t}', 'ema', t) for t in EMA_TAUS_MS]
            + [('fixed', 'fixed', 0), (f'seeded{PRIOR_MS}', 'seeded', PRIOR_MS)])
ATTRIBUTE = [('cum', 'cum', 0), ('fixed', 'fixed', 0)]         # one layer group at a time

def logmel_quarters(r, p):                                     # time-resolved: is it only the phrase start?
    R, P = logmel(r), logmel(p); fl = R.max() - 80; D = np.abs(np.maximum(R, fl) - np.maximum(P, fl))
    return [float(q.mean()) for q in np.array_split(D, 4, axis=1)]

pack = torch.load(M / 'voices' / f'{VOICE}.pt', weights_only=True)
cap_in = {}; dec.register_forward_hook(lambda m, a, o: cap_in.update(asr=a[0], F0=a[1], N=a[2], s=a[3]))
def source(inp, seed):
    torch.manual_seed(seed)
    with torch.no_grad():
        return gen.m_source(gen.f0_upsamp(inp['F0'][:, None]).transpose(1, 2))[0].transpose(1, 2).squeeze(1)
def prepare(ph):
    ids = [0] + [cfg['vocab'][c] for c in ph if c in cfg['vocab']] + [0]
    torch.manual_seed(SEED)
    with torch.no_grad():
        km.forward_with_tokens(torch.tensor([ids]), pack[len(ids) - 2])    # capture decoder inputs
    inp = {k: v.detach().clone() for k, v in cap_in.items()}
    inp['har'] = source(inp, SEED)                                          # one source per phrase, shared by all runs
    return ids, inp

results = {'phrases': [], 'layers': list(NAMES.values()),
           'voice_pack_sha256': sha(M / 'voices' / f'{VOICE}.pt')}
t_start = time.time()
# Pass 1: decoder inputs and whole-phrase moments of every norm input (for the leave-one-out prior).
DATA = []
for pid, ph in PHRASES:
    ids, inp = prepare(ph); ST['T'] = inp['asr'].shape[-1]
    ST['moments'] = {}; run(inp); DATA.append((pid, ph, ids, inp, ST['moments'])); ST['moments'] = None
def prior(excl):
    out = {}
    for n in NAMES.values():
        rows = [d[4][n] for d in DATA if d[0] != excl]; c = sum(r[2] for r in rows)
        out[n] = (sum(r[0] for r in rows) / c, sum(r[1] for r in rows) / c)
    return out

# Pass 2: reference, calibration and variants.
for pid, ph, ids, inp, _ in DATA:
    T = inp['asr'].shape[-1]; ST['T'] = T; ST['prior'] = prior(pid)
    ref_cap = {}
    ref, _ = run(inp, cap=ref_cap)                                          # original InstanceNorm, whole phrase
    rec = {'id': pid, 'phonemes': ph, 'tokens': len(ids), 'frames': T, 'seconds': T / FPS, 'runs': {}}
    y, acc = run(inp, 'whole', 0, SCOPES['all'], ref=ref_cap)               # exactness of the replacement path
    rec['runs']['whole-replaced'] = dict(metrics(ref, y), layer_snr=acc)
    y, _ = run(inp, har=source(inp, SEED + 1))                              # calibration: SineGen reseed only
    rec['runs']['reseed'] = dict(metrics(ref, y), logmel_quarters=logmel_quarters(ref, y))
    if A.wav: write_wav(OUT / f'{pid}_reference.wav', ref); write_wav(OUT / f'{pid}_reseed.wav', y)
    for scope in ('all', 'gen'):
        for vn, mode, p in VARIANTS:
            y, acc = run(inp, mode, p, SCOPES[scope], ref=ref_cap)
            rec['runs'][f'{scope}/{vn}'] = dict(metrics(ref, y), logmel_quarters=logmel_quarters(ref, y), layer_snr=acc)
            if A.wav: write_wav(OUT / f'{pid}_{scope}_{vn}.wav', y)
    for gname, gset in GROUPS.items():
        for vn, mode, p in ATTRIBUTE:
            y, acc = run(inp, mode, p, gset, ref=ref_cap)
            rec['runs'][f'only-{gname}/{vn}'] = dict(metrics(ref, y), layer_snr=acc)
    results['phrases'].append(rec)
    print(f'{pid:6s} T={T:4d} ({T / FPS:5.2f} s)  reseed logmel={rec["runs"]["reseed"]["logmel_db"]:.2f}  '
          + '  '.join(f'{k}:{rec["runs"][k]["logmel_db"]:.2f}' for k in ('all/cum', 'gen/cum', 'gen/la4', 'gen/la64', 'gen/fixed', 'all/fixed')),
          f'[{time.time() - t_start:.0f} s]', flush=True)
    del ref_cap

# ---- rates and norm-induced lookahead latency on the critical path ---------------------------
rate = {n: l / ST['T'] * FPS for n, l in ST['len'].items()}                # last phrase; ratios are fixed
def serial(g, i=None):
    if g == 'front': return [n for n in NAMES.values() if group(n) == 'front']
    if g == 'gen': b = i * gen.num_kernels; return [n for n in NAMES.values() if n.startswith(f'generator.resblocks.{b}.')]
    return [n for n in NAMES.values() if n.startswith(f'generator.noise_res.{i}.')]
PATHS = {'main': serial('front') + serial('gen', 0) + serial('gen', 1),
         'noise0': serial('noise', 0) + serial('gen', 0) + serial('gen', 1),
         'noise1': serial('noise', 1) + serial('gen', 1)}
def latency_ms(L, scope, har_ahead):
    act = SCOPES[scope]; paths = ['main'] if har_ahead else list(PATHS)
    return max(sum(1000.0 * L / rate[n] for n in PATHS[p] if n in act) for p in paths)
results['latency_ms'] = {f'{s}/la{L}': {'streamed': latency_ms(L, s, False), 'har_ahead': latency_ms(L, s, True)}
                         for s in ('all', 'gen') for L in LOOKAHEADS}
results['rate_hz'] = rate

# ---- intrinsic (non-norm) lookahead of the convolutions, measured with causal norms ---------
def conv_lookahead():
    inp = DATA[-1][3]; T = inp['asr'].shape[-1]; ST['T'] = T
    t0 = T // 2; out = {}
    base, _ = run(inp, 'cum', 0, SCOPES['all'])
    pert = dict(inp); pert['asr'] = inp['asr'].clone(); pert['asr'][..., t0:] += 0.5
    pert['F0'] = inp['F0'].clone(); pert['F0'][..., 2 * t0:] += 20.0
    pert['N'] = inp['N'].clone(); pert['N'][..., 2 * t0:] += 0.5
    pert['har'] = inp['har'].clone(); pert['har'][..., U * t0:] += 0.05
    y, _ = run(pert, 'cum', 0, SCOPES['all'])
    d = np.nonzero(np.abs(y - base) > 1e-6 * np.abs(base).max())[0]
    out['decoder_samples'] = int(U * t0 - d[0]) if d.size else None
    with torch.no_grad():                                                   # generator alone, front fixed
        ST.update(active=set()); x = front(inp['asr'], inp['F0'], inp['N'], inp['s'])
        ST.update(mode='cum', p=0, active=SCOPES['gen']); g0 = generator(x, inp['s'], inp['har']).numpy()
        x2 = x.clone(); x2[..., 2 * t0:] += 0.5; h2 = inp['har'].clone(); h2[..., U * t0:] += 0.05
        g1 = generator(x2, inp['s'], h2).numpy(); ST.update(active=set())
    d = np.nonzero(np.abs(g1 - g0) > 1e-6 * np.abs(g0).max())[0]
    out['generator_samples'] = int(U * t0 - d[0]) if d.size else None
    return {k: {'samples': v, 'ms': None if v is None else 1000.0 * v / SR} for k, v in out.items()}
results['conv_lookahead'] = conv_lookahead()

results['provenance'] = {
    'model_dir_files': {f: sha(M / f) for f in ('kokoro-v1_0.pth', 'config.json', f'voices/{VOICE}.pt')},
    'voice': VOICE, 'seed': SEED, 'kokoro': version('kokoro'), 'torch': torch.__version__,
    'numpy': np.__version__, 'scipy': scipy.__version__, 'python': platform.python_version(),
    'threads': torch.get_num_threads(), 'wall_s': time.time() - t_start}
(OUT / 'results.json').write_text(json.dumps(results, indent=1), encoding='utf-8')
(OUT / 'summary.md').write_text(summarize(results), encoding='utf-8')
print(json.dumps({k: results[k] for k in ('latency_ms', 'conv_lookahead', 'provenance')}, indent=1))
