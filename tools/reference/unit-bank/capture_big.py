"""Bulk front-end capture from pinned stock Kokoro (no decoder): per sentence t_en (int16, per-chunk per-channel
scale), durations, F0/N half-frames (float16). Chunks of 1000 sentences under build/unit-bank/. Resumable."""
import json, pathlib, sys, types, time, random
import numpy as np
SCR = pathlib.Path(sys.argv[1])
REPO = pathlib.Path(r'C:\Dev\Kokoro-Hexagon'); OUT = REPO / 'build' / 'unit-bank'; OUT.mkdir(parents=True, exist_ok=True)
spec = json.loads((REPO / 'build/stock-albert-capture-hello/capture-spec.json').read_text(encoding='utf-8-sig'))
root = pathlib.Path(spec['sourceRoot'])
package = types.ModuleType('kokoro'); package.__path__ = [str(root / 'kokoro')]; sys.modules['kokoro'] = package
import torch, importlib
from loguru import logger; logger.remove()
torch.set_num_threads(int(sys.argv[2]) if len(sys.argv) > 2 else 8)
model = importlib.import_module('kokoro.model').KModel(repo_id='hexgrad/Kokoro-82M', config=spec['inputs']['config.json']['path'],
                                                        model=spec['inputs']['kokoro-v1_0.pth']['path']).eval()
pack = torch.load(spec['inputs']['voices\\af_heart.pt']['path'], map_location='cpu', weights_only=True)
rows = json.loads((SCR / 'corpus-phonemes.json').read_text(encoding='utf-8-sig'))
rows = [r for r in rows if all(p in model.vocab for p in r['phonemes']) and len(r['phonemes']) <= 510]
random.Random(7).shuffle(rows)
(OUT / 'order.json').write_text(json.dumps(rows, ensure_ascii=False), encoding='utf-8')
CH = 1000

@torch.no_grad()
def front(ph):
    ids = torch.LongTensor([[0, *[model.vocab[p] for p in ph], 0]]); ref_s = pack[len(ph) - 1]
    L = torch.full((1,), ids.shape[-1], dtype=torch.long)
    mask = torch.gt(torch.arange(ids.shape[-1]).unsqueeze(0) + 1, L.unsqueeze(1))
    d_en = model.bert_encoder(model.bert(ids, attention_mask=(~mask).int())).transpose(-1, -2)
    s = ref_s[:, 128:]
    d = model.predictor.text_encoder(d_en, s, L, mask)
    x, _ = model.predictor.lstm(d)
    dur = torch.round(torch.sigmoid(model.predictor.duration_proj(x)).sum(axis=-1)).clamp(min=1).long().squeeze(0)
    idx = torch.repeat_interleave(torch.arange(ids.shape[1]), dur)
    aln = torch.zeros((ids.shape[1], idx.shape[0])); aln[idx, torch.arange(idx.shape[0])] = 1
    F0, N = model.predictor.F0Ntrain(d.transpose(-1, -2) @ aln[None], s)
    t_en = model.text_encoder(ids, L, mask)
    return t_en[0].numpy(), dur.numpy(), F0[0].numpy(), N[0].numpy()

t0 = time.perf_counter(); done = 0
for c in range(0, len(rows), CH):
    path = OUT / f'chunk-{c // CH:04d}.npz'
    if path.exists(): continue
    T, D, F, Nn, tok_off, frm_off = [], [], [], [], [0], [0]
    for r in rows[c:c + CH]:
        t, d, f, n = front(r['phonemes'])
        T.append(t); D.append(d); F.append(f); Nn.append(n)
        tok_off.append(tok_off[-1] + t.shape[1]); frm_off.append(frm_off[-1] + int(d.sum()))
    T = np.concatenate(T, 1); scale = np.abs(T).max(1) / 32767 + 1e-12
    np.savez(path, t_en=np.round(T / scale[:, None]).astype(np.int16), scale=scale.astype(np.float32), dur=np.concatenate(D).astype(np.int16),
             f0=np.concatenate(F).astype(np.float16), n=np.concatenate(Nn).astype(np.float16), tok_off=np.array(tok_off), frm_off=np.array(frm_off))
    done += min(CH, len(rows) - c)
    print(f'chunk {c // CH} done, {done} sentences, {time.perf_counter() - t0:.0f} s', flush=True)
print('total', len(rows))
