"""Resident stock-decoder evaluator. One JSON request per stdin line, one JSON reply per stdout line.
{"op":"swap","s":donorSentence,"i":token,"rs":replSentence,"ri":replToken}
  -> renders the donor sentence from its own bank tensors with token i's t_en column replaced, same noise draws as the
     donor's own render; replies with the log-mel distance over that token's frames (+-2 STFT frames) and globally."""
import json, pathlib, sys, types
import numpy as np
REPO = pathlib.Path(r'C:\Dev\Kokoro-Hexagon'); BANK = REPO / 'build' / 'unit-bank'
spec = json.loads((REPO / 'build/stock-albert-capture-hello/capture-spec.json').read_text(encoding='utf-8-sig'))
root = pathlib.Path(spec['sourceRoot'])
package = types.ModuleType('kokoro'); package.__path__ = [str(root / 'kokoro')]; sys.modules['kokoro'] = package
import torch, importlib
from loguru import logger; logger.remove()
torch.set_num_threads(4)
model = importlib.import_module('kokoro.model').KModel(repo_id='hexgrad/Kokoro-82M', config=spec['inputs']['config.json']['path'],
                                                        model=spec['inputs']['kokoro-v1_0.pth']['path']).eval()
pack = torch.load(spec['inputs']['voices\\af_heart.pt']['path'], map_location='cpu', weights_only=True)
order = json.loads((BANK / 'order.json').read_text(encoding='utf-8'))
SR = 24000; HOP = 256; FRAME = 600  # samples per alignment frame
chunks = {}
def chunk(c):
    if c not in chunks: z = np.load(BANK / f'chunk-{c:04d}.npz'); chunks[c] = {k: z[k] for k in z.files}
    return chunks[c]
def sentence(s):
    z = chunk(s // 1000); l = s % 1000; a, b = int(z['tok_off'][l]), int(z['tok_off'][l + 1]); fa, fb = int(z['frm_off'][l]), int(z['frm_off'][l + 1])
    te = z['t_en'][:, a:b].astype(np.float32) * z['scale'][:, None]
    return te, z['dur'][a:b].astype(np.int64), z['f0'][2 * fa:2 * fb].astype(np.float32), z['n'][2 * fa:2 * fb].astype(np.float32)
def column(s, i):
    z = chunk(s // 1000); t = int(z['tok_off'][s % 1000]) + i
    return z['t_en'][:, t].astype(np.float32) * z['scale']
def mel_fb(n_fft=1024, n_mels=80):
    hz2m = lambda h: 2595 * np.log10(1 + h / 700); m2hz = lambda m: 700 * (10 ** (m / 2595) - 1)
    pts = m2hz(np.linspace(0, hz2m(SR / 2), n_mels + 2)); b = np.floor((n_fft + 1) * pts / SR).astype(int); fb = np.zeros((n_mels, n_fft // 2 + 1))
    for i in range(1, n_mels + 1):
        for k in range(b[i - 1], b[i]): fb[i - 1, k] = (k - b[i - 1]) / max(1, b[i] - b[i - 1])
        for k in range(b[i], b[i + 1]): fb[i - 1, k] = (b[i + 1] - k) / max(1, b[i + 1] - b[i])
    return fb
FB = mel_fb()
def logmel(x):
    X = torch.stft(torch.tensor(x), 1024, HOP, window=torch.hann_window(1024), return_complex=True).abs().numpy() ** 2
    return 10 * np.log10(FB @ X + 1e-8).T
@torch.no_grad()
def render(te, dur, f0, n, s):
    idx = torch.repeat_interleave(torch.arange(te.shape[1]), torch.tensor(dur))
    aln = torch.zeros((te.shape[1], idx.shape[0])); aln[idx, torch.arange(idx.shape[0])] = 1
    torch.manual_seed(17)
    return model.decoder(torch.tensor(te)[None] @ aln[None], torch.tensor(f0)[None], torch.tensor(n)[None], pack[len(order[s]['phonemes']) - 1][:, :128]).squeeze().numpy()
own = {}
for line in sys.stdin:
    q = json.loads(line)
    try:
        s, i = q['s'], q['i']
        te, dur, f0, n = sentence(s)
        if s not in own:
            if len(own) > 64: own.clear()
            own[s] = logmel(render(te, dur, f0, n, s))
        A = own[s]; te2 = te.copy(); te2[:, i] = column(q['rs'], q['ri'])
        B = logmel(render(te2, dur, f0, n, s))
        f0_, f1_ = int(dur[:i].sum()) * FRAME // HOP - 2, int(dur[:i + 1].sum()) * FRAME // HOP + 2
        f0_ = max(0, f0_); f1_ = min(len(A), f1_)
        local = float(np.sqrt(((A[f0_:f1_] - B[f0_:f1_]) ** 2).mean(1)).mean())
        glob = float(np.sqrt(((A - B) ** 2).mean(1)).mean())
        print(json.dumps({'ok': True, 'local': round(local, 3), 'global': round(glob, 4)}), flush=True)
    except Exception as e:
        print(json.dumps({'ok': False, 'error': str(e)}), flush=True)
