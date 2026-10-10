"""Unit-selection smoke test on pinned stock Kokoro.
capture: per-token units (t_en column, duration, F0/N half-frames) from donor sentences; target tensors kept apart.
render:  assemble selections (t_en -> asr through the stock alignment rule, F0, N) and run the unchanged decoder."""
import json, pathlib, sys, types, wave, time, zlib, struct
import numpy as np
SCR = pathlib.Path(sys.argv[2]); MODE = sys.argv[1]
REPO = pathlib.Path(r'C:\Dev\Kokoro-Hexagon'); OUT = REPO / 'build' / 'unit-selection-20261010'; OUT.mkdir(parents=True, exist_ok=True)
spec = json.loads((REPO / 'build/stock-albert-capture-hello/capture-spec.json').read_text(encoding='utf-8-sig'))
root = pathlib.Path(spec['sourceRoot'])
package = types.ModuleType('kokoro'); package.__path__ = [str(root / 'kokoro')]; sys.modules['kokoro'] = package
import torch, importlib
from loguru import logger; logger.remove()
torch.set_num_threads(8)
model = importlib.import_module('kokoro.model').KModel(repo_id='hexgrad/Kokoro-82M', config=spec['inputs']['config.json']['path'],
                                                        model=spec['inputs']['kokoro-v1_0.pth']['path']).eval()
pack = torch.load(spec['inputs']['voices\\af_heart.pt']['path'], map_location='cpu', weights_only=True)
SR = 24000; SEED = 17
sents = json.loads((SCR / 'sentences.json').read_text(encoding='utf-8-sig'))
TARGET = 'I can eat a peach for hours.'
target_ph = next(s['phonemes'] for s in sents if s['text'] == TARGET)

@torch.no_grad()
def stock(ph):
    ids = torch.LongTensor([[0, *[model.vocab[p] for p in ph], 0]]); ref_s = pack[len(ph) - 1]
    L = torch.full((1,), ids.shape[-1], dtype=torch.long)
    mask = torch.gt(torch.arange(ids.shape[-1]).unsqueeze(0) + 1, L.unsqueeze(1))
    d_en = model.bert_encoder(model.bert(ids, attention_mask=(~mask).int())).transpose(-1, -2)
    s = ref_s[:, 128:]
    d = model.predictor.text_encoder(d_en, s, L, mask)
    x, _ = model.predictor.lstm(d)
    dur = torch.round(torch.sigmoid(model.predictor.duration_proj(x)).sum(axis=-1)).clamp(min=1).long().squeeze()
    aln = alignment(ids.shape[1], dur)
    F0, N = model.predictor.F0Ntrain(d.transpose(-1, -2) @ aln, s)
    t_en = model.text_encoder(ids, L, mask)
    return dict(t_en=t_en[0].numpy(), dur=dur.numpy(), F0=F0[0].numpy(), N=N[0].numpy())

def alignment(n, dur):
    dur = torch.as_tensor(dur)
    idx = torch.repeat_interleave(torch.arange(n), dur)
    a = torch.zeros((n, idx.shape[0])); a[idx, torch.arange(idx.shape[0])] = 1
    return a.unsqueeze(0)

@torch.no_grad()
def decode(t_en, dur, F0, N, ref_s):
    asr = torch.tensor(t_en)[None] @ alignment(t_en.shape[1], dur)
    torch.manual_seed(SEED)
    return model.decoder(asr, torch.tensor(F0)[None].float(), torch.tensor(N)[None].float(), ref_s[:, :128]).squeeze().numpy()

def units(ph, cap, sid):
    toks = ['<s>', *ph, '</s>']; cum = np.concatenate([[0], np.cumsum(cap['dur'])]); out = []
    for i, t in enumerate(toks):
        a, b = 2 * cum[i], 2 * cum[i + 1]
        out.append(dict(s=sid, i=i, sym=t, left=toks[i - 1] if i else '', right=toks[i + 1] if i + 1 < len(toks) else '',
                        dur=int(cap['dur'][i]), f0=[round(float(v), 3) for v in cap['F0'][a:b]], n=[round(float(v), 3) for v in cap['N'][a:b]]))
    return out

if MODE == 'capture':
    bank, tens = [], {}
    for sid, s in enumerate(sents):
        cap = stock(s['phonemes'])
        if s['text'] == TARGET:
            np.savez(OUT / 'target-eval.npz', **cap)  # final evaluation and the assembly control only
            continue
        bank += units(s['phonemes'], cap, sid); tens[f's{sid}'] = cap['t_en']
    np.savez(OUT / 'bank-t_en.npz', **tens)
    (SCR / 'bank.json').write_text(json.dumps(dict(target=target_ph, units=bank), ensure_ascii=False), encoding='utf-8')
    print('units', len(bank), 'donors', len(tens))

# ---------- metrics / pictures ----------
def mel_fb(n_fft=1024, n_mels=80):
    hz2m = lambda h: 2595 * np.log10(1 + h / 700); m2hz = lambda m: 700 * (10 ** (m / 2595) - 1)
    pts = m2hz(np.linspace(0, hz2m(SR / 2), n_mels + 2)); b = np.floor((n_fft + 1) * pts / SR).astype(int); fb = np.zeros((n_mels, n_fft // 2 + 1))
    for i in range(1, n_mels + 1):
        for k in range(b[i - 1], b[i]): fb[i - 1, k] = (k - b[i - 1]) / max(1, b[i] - b[i - 1])
        for k in range(b[i], b[i + 1]): fb[i - 1, k] = (b[i + 1] - k) / max(1, b[i + 1] - b[i])
    return fb
FB = mel_fb()
def logmel(x):
    X = torch.stft(torch.tensor(x, dtype=torch.float32), 1024, 256, window=torch.hann_window(1024), return_complex=True).abs().numpy() ** 2
    return 10 * np.log10(FB @ X + 1e-8).T
def dtw_dist(a, b):
    A, B = logmel(a), logmel(b); C = np.sqrt(((A[:, None] - B[None]) ** 2).mean(-1))
    D = np.full((len(A) + 1, len(B) + 1), np.inf); D[0, 0] = 0; Ln = np.zeros_like(D)
    for i in range(1, len(A) + 1):
        for j in range(1, len(B) + 1):
            c = [(i - 1, j - 1), (i - 1, j), (i, j - 1)]; p = min(c, key=lambda q: D[q])
            D[i, j] = D[p] + C[i - 1, j - 1]; Ln[i, j] = Ln[p] + 1
    return float(D[-1, -1] / Ln[-1, -1])
def write_wav(name, x):
    with wave.open(str(OUT / (name + '.wav')), 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes((np.clip(x, -1, 1) * 32767).astype('<i2').tobytes())
def write_png(path, rows):
    """Stacked log-mel spectrograms (grey, low frequency at the bottom) with a 4-pixel black band between rows."""
    width = max(r.shape[0] for r in rows); parts = []
    for r in rows:
        img = np.clip((r.T[::-1] + 80 - r.max()) / 80, 0, 1); img = np.repeat(img, 2, axis=0)
        img = np.pad(img, ((0, 4), (0, width - img.shape[1])))
        parts.append(img)
    im = (np.concatenate(parts) * 255).astype(np.uint8); im = np.repeat(im, 2, axis=1)
    raw = b''.join(b'\x00' + row.tobytes() for row in im)
    chunk = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', im.shape[1], im.shape[0], 8, 0, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))

if MODE == 'render':
    sel = json.loads((SCR / 'selections.json').read_text(encoding='utf-8-sig'))
    bank = {u['s']: {} for u in json.loads((SCR / 'bank.json').read_text(encoding='utf-8'))['units']}
    for u in json.loads((SCR / 'bank.json').read_text(encoding='utf-8'))['units']: bank[u['s']][u['i']] = u
    tens = np.load(OUT / 'bank-t_en.npz'); tgt = dict(np.load(OUT / 'target-eval.npz'))
    ref_s = pack[len(target_ph) - 1]
    t0 = time.perf_counter(); ref = decode(tgt['t_en'], tgt['dur'], tgt['F0'], tgt['N'], ref_s); t_dec = time.perf_counter() - t0
    write_wav('target-stock', ref); results = {'decoder_s': t_dec}
    # assembly control: target's own units through the same per-token assembly
    toks = ['<s>', *target_ph, '</s>']; cum = np.concatenate([[0], np.cumsum(tgt['dur'])])
    te = np.stack([tgt['t_en'][:, i] for i in range(len(toks))], 1)
    F0 = np.concatenate([tgt['F0'][2 * cum[i]:2 * cum[i + 1]] for i in range(len(toks))]); N = np.concatenate([tgt['N'][2 * cum[i]:2 * cum[i + 1]] for i in range(len(toks))])
    ctrl = decode(te, tgt['dur'], F0, N, ref_s)
    results['assembly-control-max-abs'] = float(np.max(np.abs(ctrl - ref)))
    global_seed = SEED
    pics = [logmel(ref)]
    for name, picks in sel.items():
        te = np.stack([tens[f"s{p['s']}"][:, p['i']] for p in picks], 1)
        dur = np.array([bank[p['s']][p['i']]['dur'] for p in picks])
        F0 = np.concatenate([bank[p['s']][p['i']]['f0'] for p in picks]); N = np.concatenate([bank[p['s']][p['i']]['n'] for p in picks])
        a = decode(te, dur, F0, N, ref_s); write_wav('sel-' + name, a); pics.append(logmel(a))
        results[name] = dict(mel_dtw=round(dtw_dist(ref, a), 2), ms=round(len(a) / SR * 1000, 1))
        print(name, results[name])
    SEED = 18; alt = decode(tgt['t_en'], tgt['dur'], tgt['F0'], tgt['N'], ref_s); SEED = 17
    results['floor-seed'] = dict(mel_dtw=round(dtw_dist(ref, alt), 2))
    write_png(OUT / 'spectrograms.png', pics)
    print('control max |diff|', results['assembly-control-max-abs'], 'floor', results['floor-seed'], 'decoder s', round(t_dec, 3), 'stock ms', len(ref) / SR * 1000)
    (OUT / 'results.json').write_text(json.dumps(results, indent=1), encoding='utf-8')
