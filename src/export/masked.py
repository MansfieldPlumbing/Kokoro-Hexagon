# Fixed-capacity decoder with length-masked InstanceNorm; exactness check against the full-length run.
import sys, os, math, numpy as np, torch, torch.nn.functional as F
src = open(sys.argv[1], encoding='utf-8').read().split('# Real decoder inputs')[0]
ARGS = list(sys.argv); g = {'__name__': 'masked'}; sys.argv = ['x', ARGS[2]]; exec(src, g)
import kokoro.istftnet as ist
core, km, U = g['core'], g['km'], 600
CUR = {}

GB = {'offsets': {}, 'size': 0}                                              # per-voice gamma/beta table (fc(style) precomputed)
def gb_register(model):
    for mod in model.modules():
        if isinstance(mod, ist.AdaIN1d):
            GB['offsets'][id(mod)] = (GB['size'], mod.fc.out_features); GB['size'] += mod.fc.out_features
def gb_compute(s):
    return torch.cat([m.fc(s) for m in km.decoder.modules() if isinstance(m, ist.AdaIN1d)], 1)
def masked_adain(self, x, s):
    if 'gb' in CUR:
        o, n = GB['offsets'][id(self)]; h = CUR['gb'][:, o:o + n].reshape(1, -1, 1)
    else:
        h = self.fc(s).view(s.size(0), -1, 1)
    gamma, beta = torch.chunk(h, 2, dim=1)
    m = CUR['mask']
    for mh in CUR.get('mask_by_len', {}).values():                        # stage-resolution mask supplied as graph input
        if int(mh.shape[-1]) == int(x.shape[-1]): m = mh
    r = x.shape[-1] // m.shape[-1]
    if r * m.shape[-1] == x.shape[-1]:
        if r > 1: m = m.unsqueeze(-1).expand(*m.shape, r).reshape(*m.shape[:-1], m.shape[-1] * r)   # nearest xr, no Resize
    else:
        m = F.interpolate(m, size=x.shape[-1], mode='nearest')
    k = x.shape[-1] / m.sum(-1, keepdim=True)                            # W / n: means stay in range
    mu = (x * m).mean(-1, keepdim=True) * k
    if NATIVE_IN:
        # Canonical form for QNN fusion: pad region := valid mean, native InstanceNorm over W, rescale by sqrt(n/W).
        # Exact: mean(x') = mu, var(x') = var_valid * n/W  =>  IN(x') * sqrt(n/W) = (x - mu)/sqrt(var_valid + eps*W/n).
        xp = x * m + mu * (1 - m)
        C = x.shape[1]; y = F.instance_norm(xp, weight=torch.ones(C), bias=torch.zeros(C), eps=self.norm.eps) * torch.rsqrt(k)   # static C for export   # eps enters as eps*W/n: <=1e-5 relative at n>=W/2
    else:
        # fp16-safe variance (HTP accumulates in fp16): scale each channel by its own max |x - mu| first.
        sc = ((x - mu) * m).abs().amax(-1, keepdim=True) + 1e-6
        c = (x - mu) / sc
        vs = ((c * m) ** 2).mean(-1, keepdim=True) * k
        y = c / torch.sqrt(vs + self.norm.eps / (sc * sc))
    y = y * self.norm.weight.view(1, -1, 1) + self.norm.bias.view(1, -1, 1)
    return ((1 + gamma) * y + beta) * m
NATIVE_IN = False
ist.AdaIN1d.forward = masked_adain

def up2(x):   # nearest x2 as Expand+Reshape (HTP Resize avoided)
    return x.unsqueeze(-1).expand(*x.shape, 2).reshape(*x.shape[:-1], x.shape[-1] * 2)
ist.UpSample1d.forward = lambda self, x: x if self.layer_type == 'none' else up2(x)

class PolyphaseUp(torch.nn.Module):
    """Depthwise ConvTranspose1d(k=3, s=2, p=1, op=1) as polyphase: y[2t]=w1 x[t]+b, y[2t+1]=w2 x[t]+w0 x[t+1]+b."""
    def __init__(s, ct):
        super().__init__(); w = ct.weight.detach()[:, 0, :]                 # [C,3] effective (weight_norm applied)
        s.register_buffer('w0', w[:, 0].view(1, -1, 1)); s.register_buffer('w1', w[:, 1].view(1, -1, 1)); s.register_buffer('w2', w[:, 2].view(1, -1, 1))
        s.register_buffer('b', ct.bias.detach().view(1, -1, 1))
    def forward(s, x):
        nxt = F.pad(x[..., 1:], (0, 1))
        ev = s.w1 * x + s.b; od = s.w2 * x + s.w0 * nxt + s.b
        return torch.stack([ev, od], -1).reshape(x.shape[0], x.shape[1], x.shape[2] * 2)
with torch.no_grad():
    for blk in km.decoder.decode:
        if blk.upsample_type != 'none':
            ref_ct = blk.pool; blk.pool = PolyphaseUp(ref_ct)
            probe = torch.randn(1, ref_ct.in_channels, 17)
            assert torch.allclose(ref_ct(probe), blk.pool(probe), atol=1e-5), 'polyphase mismatch'

class Cap(torch.nn.Module):
    def __init__(s, c): super().__init__(); s.c = c
    def forward(s, asr, F0_curve, N, style, har_source, mask):
        CUR['mask'] = mask
        return s.c(asr * mask, F0_curve, N, style, har_source)

# Reference: unmasked full-length (restore original forward temporarily).
ph = os.environ.get('KOKORO_QNN_PHONEMES', 'həlˈoʊ wˈɜɹld. ðɪs ɪz kˈoʊkəɹoʊ ɑn hɛksəɡˌɑn.')
voice = os.environ.get('KOKORO_QNN_VOICE', 'af_heart')
cfg = g['cfg']; ids = [0] + [cfg['vocab'][c] for c in ph if c in cfg['vocab']] + [0]
ref_s = torch.load(g['M'] / 'voices' / f'{voice}.pt', weights_only=True)[len(ids) - 2]
cap = {}; km.decoder.register_forward_hook(lambda m, a, o: cap.update(asr=a[0], F0=a[1], N=a[2], s=a[3]))
orig = masked_adain
def plain(self, x, s):
    h = self.fc(s).view(s.size(0), -1, 1); gamma, beta = torch.chunk(h, 2, dim=1)
    return (1 + gamma) * self.norm(x) + beta
ist.AdaIN1d.forward = plain
with torch.no_grad():
    km.forward_with_tokens(torch.tensor([ids]), ref_s)
    gen = km.decoder.generator
    har = gen.m_source(gen.f0_upsamp(cap['F0'][:, None]).transpose(1, 2))[0].transpose(1, 2).squeeze(1)
    L = cap['asr'].shape[-1]
    full = core(cap['asr'], cap['F0'], cap['N'], cap['s'], har).squeeze().numpy()
ist.AdaIN1d.forward = orig

def snr(r, p): e = p - r; return 10 * math.log10((r ** 2).sum() / (e ** 2).sum())
def logmel_db(r, p):
    S = lambda a: torch.stft(torch.tensor(a), 1024, 256, window=torch.hann_window(1024), return_complex=True).abs().clamp_min(1e-5).log10() * 20
    return (S(r) - S(p)).abs().mean().item()

W = int(ARGS[3]) if len(ARGS) > 3 else 256
if L > W:
    raise ValueError(f'phrase requires {L} frames but capacity is {W}')
def pad(t, r):   # replicate tail to capacity (content beyond L is masked anyway)
    return F.pad(t.reshape(1, -1, t.shape[-1]), (0, (W - L) * r), mode='replicate').reshape(*t.shape[:-1], -1)
mask = torch.zeros(1, 1, W); mask[..., :L] = 1
m = Cap(core).eval()
with torch.no_grad():
    y = m(pad(cap['asr'], 1), pad(cap['F0'], 2), pad(cap['N'], 2), cap['s'], pad(har, U), mask).reshape(-1).numpy()[:L * U]
print(f'L={L} W={W}  masked-capacity SNR={snr(full, y):.2f} dB  logmel_mae={logmel_db(full, y):.3f} dB')
if len(ARGS) > 4:
    import pathlib, hashlib
    p = pathlib.Path(ARGS[4]); ex = (torch.zeros(1, 512, W), torch.zeros(1, 2 * W), torch.zeros(1, 2 * W), torch.zeros(1, 128), torch.zeros(1, W * U), torch.ones(1, 1, W))
    torch.onnx.export(m, ex, str(p), dynamo=False, opset_version=17,
                      input_names=['asr', 'F0_curve', 'N', 'style', 'har_source', 'mask'], output_names=['audio'])
    import onnxruntime as ort
    o = ort.InferenceSession(str(p), providers=['CPUExecutionProvider']).run(None, {
        'asr': pad(cap['asr'], 1).numpy(), 'F0_curve': pad(cap['F0'], 2).numpy(), 'N': pad(cap['N'], 2).numpy(),
        'style': cap['s'].numpy(), 'har_source': pad(har, U).numpy(), 'mask': mask.numpy()})[0].reshape(-1)[:L * U]
    print(f'ORT SNR vs full={snr(full, o):.2f} dB  nan={np.isnan(o).sum()}  sha256={hashlib.sha256(p.read_bytes()).hexdigest().upper()}')
    np.savez(p.with_suffix('.inputs.npz'), asr=pad(cap['asr'], 1).numpy(), F0=pad(cap['F0'], 2).numpy(), N=pad(cap['N'], 2).numpy(),
             s=cap['s'].numpy(), har_source=pad(har, U).numpy(), mask=mask.numpy(), full=full, L=L)
    import wave
    for nm, a in (('reference_full', full), ('capacity_ort', o)):
        with wave.open(str(p.parent / f'{nm}.wav'), 'wb') as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(24000); w.writeframes((np.clip(a, -1, 1) * 32767).astype('<i2').tobytes())
