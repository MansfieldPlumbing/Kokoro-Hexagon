# Residual-branch dropout knob: quality vs generator compute, measured on CPU against the undropped masked model.
import sys, math, random, wave, numpy as np, torch
ARGS = list(sys.argv)                       # dropknob.py <export_decoder.py> <masked.py> <gen_stages.py> <outdir>
sys.argv = ['x', ARGS[1], ARGS[2], ARGS[4], '160']
g = {'__name__': 'drop'}; src = open(ARGS[3], encoding='utf-8').read()
exec(src, g)
import kokoro.istftnet as ist
gen, Gen8, x0, ins, harp, mask, mkp, out = (g[k] for k in ('gen', 'Gen8', 'x0', 'ins', 'harp', 'mask', 'mkp', 'out'))
blocks = list(gen.resblocks)                  # 2 stages x 3 kernels; each has 3 residual branches
branches = [(bi, j) for bi in range(len(blocks)) for j in range(len(blocks[bi].convs1))]
L = int(mask.sum().item())
# cost of one branch ~ 2 convs: C*C*k*T (T = stage length)
def cost(bi, j):
    b = blocks[bi]; c = b.convs1[j]; T = (x0.shape[-1] * 10) if bi < 3 else harp.shape[-1]
    return 2 * c.in_channels * c.out_channels * c.kernel_size[0] * T
total = sum(cost(*b) for b in branches)
SKIP = set()
orig = ist.AdaINResBlock1.forward
def fwd(self, x, s):
    if self not in blocks: return orig(self, x, s)          # noise_res blocks: unchanged
    bi = blocks.index(self)
    for j, (c1, c2, n1, n2, a1, a2) in enumerate(zip(self.convs1, self.convs2, self.adain1, self.adain2, self.alpha1, self.alpha2)):
        if (bi, j) in SKIP: continue                                  # carry the residual input through the Add
        xt = n1(x, s); xt = xt + (1 / a1) * (torch.sin(a1 * xt) * torch.sin(a1 * xt)); xt = c1(xt)
        xt = n2(xt, s); xt = xt + (1 / a2) * (torch.sin(a2 * xt) * torch.sin(a2 * xt)); xt = c2(xt)
        x = xt + x
    return x
ist.AdaINResBlock1.forward = fwd
def audio():
    with torch.no_grad():
        post = Gen8()(x0, ins['s'], harp, mask, mkp); n = gen.post_n_fft // 2 + 1
        return gen.stft.inverse(torch.exp(post[:, :n]), torch.sin(post[:, n:])).reshape(-1)[:L * 600].numpy()
def logmel(a):
    S = torch.stft(torch.tensor(a), 1024, 256, window=torch.hann_window(1024), return_complex=True).abs().clamp_min(1e-5)
    return 20 * S.log10()
ref = audio(); R = logmel(ref)
def save(name, a):
    with wave.open(f'{out}\\{name}.wav', 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(24000); w.writeframes((np.clip(a, -1, 1) * 32767).astype('<i2').tobytes())
save('drop_000', ref)
print(f'branches={len(branches)} generator-branch MACs={total/1e9:.1f} G')
for frac in (0.06, 0.125, 0.25, 0.375):
    rng = random.Random(1234); k = round(frac * len(branches))
    # seeded choice, cheapest-quality-first heuristic not applied: plain seeded sample (reproducible)
    SKIP = set(rng.sample(branches, k)); saved = sum(cost(*b) for b in SKIP)
    y = audio(); e = y - ref
    print(f'drop {frac:5.1%} ({k:2d} branches)  MACs saved {saved/total:5.1%}  logmel_mae={float((logmel(y)-R).abs().mean()):.3f} dB  SNR={10*math.log10((ref**2).sum()/(e**2).sum()):6.2f} dB')
    save(f'drop_{int(frac*1000):03d}', y)

