"""One-time experiment: substitute duration / F0 / N / d_en in pinned stock Kokoro and measure against the stock render.
Zira (System.Speech) phoneme durations and PCM pitch are the external metadata source."""
import json, pathlib, sys, types, wave
import numpy as np

REPO = pathlib.Path(r'C:\Dev\Kokoro-Hexagon')
SCR = pathlib.Path(sys.argv[1])
OUT = REPO / 'build' / 'zira-substitution-20261010'
OUT.mkdir(parents=True, exist_ok=True)
spec = json.loads((REPO / 'build/stock-albert-capture-hello/capture-spec.json').read_text(encoding='utf-8-sig'))
root = pathlib.Path(spec['sourceRoot'])
package = types.ModuleType('kokoro'); package.__path__ = [str(root / 'kokoro')]; sys.modules['kokoro'] = package
import torch, importlib
torch.set_num_threads(8)
model = importlib.import_module('kokoro.model').KModel(repo_id='hexgrad/Kokoro-82M', config=spec['inputs']['config.json']['path'],
                                                        model=spec['inputs']['kokoro-v1_0.pth']['path']).eval()
pack = torch.load(spec['inputs']['voices\\af_heart.pt']['path'], map_location='cpu', weights_only=True)
SEED = 17
SR = 24000

SENTENCES = {
    'hello': ('həlˈoʊ wˈɜɹld.', 'zira-hello'),
    'bench1': ('ði ˈɜɹli mˈɔɹnɪŋ sˈʌn kˈæst lˈɔŋ ʃˈædOz əkɹˈɔs ði ˈɛmpti stɹˈit.', 'zira-bench1'),
}

# ---------- stock pieces (copied call order from model.forward_with_tokens, no new math) ----------
@torch.no_grad()
def front(ids, ref_s, d_en_override=None):
    L = torch.full((1,), ids.shape[-1], dtype=torch.long)
    mask = torch.gt(torch.arange(ids.shape[-1]).unsqueeze(0) + 1, L.unsqueeze(1))
    bert_dur = model.bert(ids, attention_mask=(~mask).int())
    d_en = model.bert_encoder(bert_dur).transpose(-1, -2)
    if d_en_override is not None:
        d_en = d_en_override
    s = ref_s[:, 128:]
    d = model.predictor.text_encoder(d_en, s, L, mask)
    x, _ = model.predictor.lstm(d)
    dur = torch.sigmoid(model.predictor.duration_proj(x)).sum(axis=-1)
    pred_dur = torch.round(dur).clamp(min=1).long().squeeze()
    t_en = model.text_encoder(ids, L, mask)
    return dict(d_en=d_en, d=d, pred_dur=pred_dur, t_en=t_en, s=s)

def alignment(n_tok, dur):
    idx = torch.repeat_interleave(torch.arange(n_tok), dur)
    a = torch.zeros((n_tok, idx.shape[0])); a[idx, torch.arange(idx.shape[0])] = 1
    return a.unsqueeze(0)

@torch.no_grad()
def back(f, dur, ref_s, F0=None, N=None):
    aln = alignment(f['d'].shape[1], dur)
    en = f['d'].transpose(-1, -2) @ aln
    F0p, Np = model.predictor.F0Ntrain(en, f['s'])
    asr = f['t_en'] @ aln
    F0 = F0p if F0 is None else F0
    N = Np if N is None else N
    torch.manual_seed(SEED)
    audio = model.decoder(asr, F0, N, ref_s[:, :128]).squeeze()
    return audio.numpy(), F0p, Np

# ---------- metrics ----------
def mel_fb(n_fft=1024, n_mels=80, sr=SR):
    hz2m = lambda h: 2595 * np.log10(1 + h / 700); m2hz = lambda m: 700 * (10 ** (m / 2595) - 1)
    pts = m2hz(np.linspace(hz2m(0), hz2m(sr / 2), n_mels + 2)); bins = np.floor((n_fft + 1) * pts / sr).astype(int)
    fb = np.zeros((n_mels, n_fft // 2 + 1))
    for i in range(1, n_mels + 1):
        for k in range(bins[i - 1], bins[i]): fb[i - 1, k] = (k - bins[i - 1]) / max(1, bins[i] - bins[i - 1])
        for k in range(bins[i], bins[i + 1]): fb[i - 1, k] = (bins[i + 1] - k) / max(1, bins[i + 1] - bins[i])
    return fb
FB = mel_fb()
def logmel(x):
    X = torch.stft(torch.tensor(x, dtype=torch.float32), 1024, 256, window=torch.hann_window(1024), return_complex=True).abs().numpy() ** 2
    return 10 * np.log10(FB @ X + 1e-8).T  # frames x mels

def mel_dist(a, b, dtw=False):
    A, B = logmel(a), logmel(b)
    if not dtw:
        n = min(len(A), len(B)); return float(np.mean(np.sqrt(np.mean((A[:n] - B[:n]) ** 2, axis=1))))
    C = np.sqrt(((A[:, None, :] - B[None, :, :]) ** 2).mean(-1))
    D = np.full((len(A) + 1, len(B) + 1), np.inf); D[0, 0] = 0; L = np.zeros_like(D)
    for i in range(1, len(A) + 1):
        for j in range(1, len(B) + 1):
            k = np.argmin([D[i - 1, j - 1], D[i - 1, j], D[i, j - 1]])
            prev = [(i - 1, j - 1), (i - 1, j), (i, j - 1)][k]
            D[i, j] = D[prev] + C[i - 1, j - 1]; L[i, j] = L[prev] + 1
    return float(D[-1, -1] / L[-1, -1])

def snr(ref, x):
    n = min(len(ref), len(x)); e = ref[:n] - x[:n]
    return float(10 * np.log10(np.sum(ref[:n] ** 2) / max(np.sum(e ** 2), 1e-20)))

def write_wav(name, x, sr=SR):
    with wave.open(str(OUT / (name + '.wav')), 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype('<i2').tobytes())

# ---------- Zira ----------
def read_wav(p):
    with wave.open(str(p)) as w:
        return np.frombuffer(w.readframes(w.getnframes()), '<i2').astype(np.float64) / 32768, w.getframerate()

def yin(x, sr, hop_s, fmin=70, fmax=500, thr=0.15):
    W = int(sr / fmin) * 2; hop = hop_s * sr; out = []
    n_frames = int(len(x) / hop)
    for f in range(n_frames):
        c = int(f * hop); seg = x[max(0, c - W // 2): max(0, c - W // 2) + W]
        if len(seg) < W: seg = np.pad(seg, (0, W - len(seg)))
        if np.sqrt(np.mean(seg ** 2)) < 0.01: out.append(0.0); continue
        tmax = int(sr / fmin); d = np.array([np.sum((seg[:W - tmax] - seg[t:t + W - tmax]) ** 2) for t in range(tmax)])
        cm = d.copy(); cm[1:] = d[1:] * np.arange(1, tmax) / np.maximum(np.cumsum(d[1:]), 1e-12); cm[0] = 1
        tmin = int(sr / fmax); cand = np.where(cm[tmin:] < thr)[0]
        if len(cand) == 0: out.append(0.0); continue
        t = cand[0] + tmin
        while t + 1 < tmax and cm[t + 1] < cm[t]: t += 1
        out.append(sr / t)
    return np.array(out)

VOWELS = set('aeiouæɑɒɔəɛɜɪʊʌɐᵻAEIOUWYɚɝɘɵɤɯ')
NONPHONE = set('ˈˌ .,!?;:—…"()“”-')
def cls(c): return 'v' if c in VOWELS else 'c'
def norm(c): return {'ɻ': 'ɹ', 'r': 'ɹ', 'ɝ': 'ɜ', 'ɚ': 'ə'}.get(c, c)

def zira_token_times(ph_tokens, zira):
    """Align Kokoro phone tokens (chars) with Zira phones by DP; return per-Kokoro-token durations (s) and
    per-token Zira time spans for warping. Zira silence before/after goes to BOS/final punctuation+EOS."""
    zp = [z for z in zira if z['Kind'] == 'phoneme']
    lead = zp[0]['DurMs'] if zp[0]['Text'].strip() == '' else 0.0
    trail = zp[-1]['DurMs'] if zp[-1]['Text'].strip() == '' else 0.0
    core = [z for z in zp if z['Text'].strip() != '']
    t = lead; zs = []
    for z in core:
        zs.append((norm(z['Text'][0]) if z['Text'] else '', t, t + z['DurMs'])); t += z['DurMs']
    k_idx = [i for i, c in enumerate(ph_tokens) if c not in NONPHONE]
    k = [norm(ph_tokens[i]) for i in k_idx]
    n, m = len(k), len(zs)
    def sub(a, b): return 0 if a == b else (1 if cls(a) == cls(b) else 2.5)
    D = np.zeros((n + 1, m + 1)); D[:, 0] = np.arange(n + 1) * 1.5; D[0, :] = np.arange(m + 1) * 1.5
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            D[i, j] = min(D[i - 1, j - 1] + sub(k[i - 1], zs[j - 1][0]), D[i - 1, j] + 1.5, D[i, j - 1] + 1.5)
    # backtrace: map each Kokoro phone -> list of Zira indices (a Kokoro phone deleted shares its neighbor's Zira phone)
    i, j = n, m; assign = [[] for _ in range(n)]; zown = [None] * m
    while i > 0 or j > 0:
        if i > 0 and j > 0 and D[i, j] == D[i - 1, j - 1] + sub(k[i - 1], zs[j - 1][0]):
            assign[i - 1].append(j - 1); zown[j - 1] = i - 1; i -= 1; j -= 1
        elif i > 0 and D[i, j] == D[i - 1, j] + 1.5:
            i -= 1
        else:
            zown[j - 1] = ('ins', i); j -= 1
    # Zira phones inserted (no Kokoro partner) go to the preceding Kokoro phone (or following if at start)
    for jj, o in enumerate(zown):
        if isinstance(o, tuple):
            tgt = max(0, o[1] - 1); assign[min(tgt, n - 1)].append(jj)
    # Kokoro phones with no Zira phone split the time of the nearest assigned neighbor equally
    span = [None] * n
    for ii in range(n):
        if assign[ii]:
            js = sorted(assign[ii]); span[ii] = [zs[js[0]][1], zs[js[-1]][2]]
    groups = []  # runs of unassigned phones attach to the previous assigned phone
    for ii in range(n):
        if span[ii] is None:
            p = ii - 1
            while p >= 0 and span[p] is None: p -= 1
            if p < 0:
                p = ii + 1
                while span[p] is None: p += 1
            groups.append((ii, p))
    share = {}
    for ii, p in groups: share.setdefault(p, [p]).append(ii)
    for p, members in share.items():
        a, b = span[p]; members = sorted(members); w = (b - a) / len(members)
        for q, mm in enumerate(members): span[mm] = [a + q * w, a + (q + 1) * w]
    ok = sum(1 for ii in range(n) if assign[ii] and any(zs[j][0] == k[ii] for j in assign[ii]))
    tok_span = [None] * len(ph_tokens)
    for ii, ti in enumerate(k_idx): tok_span[ti] = span[ii]
    return tok_span, lead, trail, t + trail, ok, n, m

def zira_durations(ph_tokens, tok_span, lead, trail, frame_ms):
    """Per input_id frame counts: [BOS] + tokens + [EOS]. Boundary times from Zira, rounded to frames."""
    # boundary times for each token: phones from their spans; non-phones are zero-width at the previous phone end,
    # except final punctuation + EOS which take Zira's trailing silence
    T = len(ph_tokens); starts = np.zeros(T + 2); ends = np.zeros(T + 2)
    starts[0], ends[0] = 0, lead
    cur = lead
    for i, c in enumerate(ph_tokens):
        if tok_span[i] is not None:
            starts[i + 1], ends[i + 1] = tok_span[i]; cur = tok_span[i][1]
        else:
            starts[i + 1] = ends[i + 1] = cur
    end_all = cur + trail
    # final punctuation gets half the trailing silence, EOS the rest
    last = T  # index of last token in ids space
    if ph_tokens[-1] in '.!?':
        ends[last] = cur + trail / 2
        starts[T + 1], ends[T + 1] = cur + trail / 2, end_all
    else:
        starts[T + 1], ends[T + 1] = cur, end_all
    bounds = np.round(np.maximum.accumulate(ends) / frame_ms).astype(int)
    dur = np.diff(np.concatenate([[0], bounds]))
    return torch.tensor(np.maximum(dur, 1), dtype=torch.long), ends

def warp_f0(zf0, z_hop_ms, z_bounds_ms, k_bounds_frames, n_frames_f0):
    """Map Zira F0 (on its PCM timebase) onto Kokoro F0 frames (2 per alignment frame) by piecewise-linear warp of
    token boundaries."""
    zb = np.concatenate([[0], z_bounds_ms]); kb = np.concatenate([[0], k_bounds_frames]) * 2  # F0 frames
    out = np.zeros(n_frames_f0)
    for f in range(n_frames_f0):
        t = np.interp(f + 0.5, kb, zb)  # ms in Zira time
        idx = int(t / z_hop_ms)
        out[f] = zf0[idx] if 0 <= idx < len(zf0) else 0.0
    return out

def stats(f0):
    v = f0[f0 > 10]; return (float(np.mean(np.log(v))), float(np.std(np.log(v)))) if len(v) else (0, 1)

results = {}
for name, (ph, zprefix) in SENTENCES.items():
    ids = torch.LongTensor([[0, *[model.vocab[p] for p in ph], 0]])
    ref_s = pack[len(ph) - 1]
    f = front(ids, ref_s)
    stock, F0s, Ns = back(f, f['pred_dur'], ref_s)
    write_wav(name + '-stock', stock)
    nfr = int(f['pred_dur'].sum()); frame_ms = len(stock) / nfr / SR * 1000
    r = {'frames': nfr, 'frame_ms': frame_ms, 'stock_ms': len(stock) / SR * 1000, 'pred_dur': f['pred_dur'].tolist()}
    rows = []
    def add(label, audio, dtw=False, note=''):
        rows.append(dict(case=label, snr=None if dtw else round(snr(stock, audio), 2),
                         mel=round(mel_dist(stock, audio, dtw), 2), ms=round(len(audio) / SR * 1000, 1), note=note))
        write_wav(name + '-' + label, audio)
    # noise floor: same everything, different generator random draws
    SEED = 18; a, _, _ = back(f, f['pred_dur'], ref_s); SEED = 17
    add('seed-only', a, note='only the source noise draws differ')
    # (a) d_en noise
    p = f['d_en'].pow(2).mean()
    for db in (20, 25, 30, 35, 40):
        g = torch.Generator().manual_seed(5)
        noisy = f['d_en'] + torch.randn(f['d_en'].shape, generator=g) * torch.sqrt(p / 10 ** (db / 10))
        f2 = front(ids, ref_s, noisy)
        same = torch.equal(f2['pred_dur'], f['pred_dur'])
        a, _, _ = back(f2, f2['pred_dur'], ref_s)
        add(f'd_en-{db}dB', a, dtw=not same, note='durations unchanged' if same else 'durations changed')
    # (b) F0 / N ablations with stock durations
    F0n, Nn = F0s.numpy()[0], Ns.numpy()[0]
    voiced = F0n > 10
    k = np.ones(9) / 9
    a, _, _ = back(f, f['pred_dur'], ref_s, N=torch.full_like(Ns, float(Nn.mean()))); add('N-const-mean', a)
    a, _, _ = back(f, f['pred_dur'], ref_s, N=torch.tensor(np.convolve(Nn, k, 'same'))[None].float()); add('N-smooth9', a)
    a, _, _ = back(f, f['pred_dur'], ref_s, N=torch.zeros_like(Ns)); add('N-zero', a)
    flat = np.where(voiced, np.exp(np.mean(np.log(F0n[voiced]))), F0n)
    a, _, _ = back(f, f['pred_dur'], ref_s, F0=torch.tensor(flat)[None].float()); add('F0-flat-voiced', a, note='voicing kept')
    # Zira
    zira = json.loads((SCR / (zprefix + '.json')).read_text(encoding='utf-8-sig'))
    zpcm, zsr = read_wav(SCR / (zprefix + '.wav'))
    tok_span, lead, trail, zend, ok, nk, nz = zira_token_times(ph, zira)
    zdur, zends = zira_durations(ph, tok_span, lead, trail, frame_ms)
    r['zira'] = dict(kokoro_phones=nk, zira_phones=nz, exact_matches=ok, zira_ms=zend, zira_frames=int(zdur.sum()),
                     zira_dur=zdur.tolist())
    zf0 = yin(zpcm, zsr, 0.005)
    kb_stock = np.cumsum(f['pred_dur'].numpy()); kb_zira = np.cumsum(zdur.numpy())
    # (c) Zira durations, Kokoro F0/N predicted on the new alignment
    a, F0z, Nz = back(f, zdur, ref_s); add('zira-dur', a, dtw=True, note='Kokoro F0/N from Zira alignment')
    # (d) Zira F0 on stock durations (raw, and with Kokoro's register: log-mean/std matched to stock F0)
    zw = warp_f0(zf0, 5.0, zends, kb_stock, F0s.shape[-1])
    a, _, _ = back(f, f['pred_dur'], ref_s, F0=torch.tensor(zw)[None].float()); add('zira-F0-raw', a)
    (ms, ss), (mz, sz) = stats(F0n), stats(zw)
    zr = np.where(zw > 10, np.exp((np.log(np.maximum(zw, 1)) - mz) / sz * ss + ms), 0)
    a, _, _ = back(f, f['pred_dur'], ref_s, F0=torch.tensor(zr)[None].float()); add('zira-F0-register', a)
    zv = np.where(voiced, np.where(zr > 10, zr, np.exp(ms)), 0)
    a, _, _ = back(f, f['pred_dur'], ref_s, F0=torch.tensor(zv)[None].float()); add('zira-F0-stockvoicing', a, note='Zira contour inside stock voicing mask')
    # (e) full bypass: Zira durations + Zira F0 (register) + N constant -> no ALBERT, no predictor
    zw2 = warp_f0(zf0, 5.0, zends, kb_zira, 2 * int(zdur.sum()))
    zr2 = np.where(zw2 > 10, np.exp((np.log(np.maximum(zw2, 1)) - mz) / sz * ss + ms), 0)
    Nc = torch.full((1, 2 * int(zdur.sum())), float(Nn.mean()))
    a, _, _ = back(f, zdur, ref_s, F0=torch.tensor(zr2)[None].float(), N=Nc); add('bypass-zira-dur-F0-Nconst', a, dtw=True,
        note='ALBERT and all 5 predictor BiLSTMs unused')
    # (e') same, N from Zira loudness mapped linearly to stock N statistics
    hop = 1000 * frame_ms / 2 / 1000  # F0-frame length in s
    zb_ms = np.concatenate([[0], np.maximum.accumulate(zends)]); kb2 = np.concatenate([[0], kb_zira * 2])
    centers = [int(np.interp(i + 0.5, kb2, zb_ms) / 1000 * zsr) for i in range(2 * int(zdur.sum()))]
    zr_rms = np.array([np.sqrt(np.mean(zpcm[max(0, c - 256):max(0, c - 256) + 512] ** 2) + 1e-9) for c in centers])
    ld = 20 * np.log10(zr_rms + 1e-6); ld = (ld - ld.mean()) / (ld.std() + 1e-9) * Nn.std() + Nn.mean()
    a, _, _ = back(f, zdur, ref_s, F0=torch.tensor(zr2)[None].float(), N=torch.tensor(ld)[None].float())
    add('bypass-zira-dur-F0-Nloudness', a, dtw=True, note='ALBERT and all 5 predictor BiLSTMs unused')
    # reference distance: stock vs Zira itself (different voice), DTW
    zr24 = np.interp(np.arange(int(len(zpcm) * SR / zsr)) * zsr / SR, np.arange(len(zpcm)), zpcm)
    rows.append(dict(case='zira-voice-itself', snr=None, mel=round(mel_dist(stock, zr24, True), 2), ms=round(len(zr24) / SR * 1000, 1), note='other speaker'))
    r['rows'] = rows
    r['f0'] = dict(stock_voiced_frac=float(voiced.mean()), stock_logmean_hz=float(np.exp(ms)), zira_logmean_hz=float(np.exp(mz)),
                   N_mean=float(Nn.mean()), N_std=float(Nn.std()))
    results[name] = r
    print(name, json.dumps({k: v for k, v in r.items() if k not in ('rows', 'pred_dur')}, ensure_ascii=False))
    for row in rows: print('  {case:30s} snr={snr!s:>7} mel={mel:6.2f} ms={ms:8.1f} {note}'.format(**row))
(OUT / 'results.json').write_text(json.dumps(results, indent=1, ensure_ascii=False), encoding='utf-8')
