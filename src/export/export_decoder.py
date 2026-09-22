# One-time artifact producer: static Kokoro decoder window + CPU chunk-stitch gate.
import sys, types, json, math, hashlib, pathlib
sys.modules['misaki'] = types.ModuleType('misaki')          # pipeline import only; G2P unused here
for n in ('en', 'espeak'):
    setattr(sys.modules['misaki'], n, None)
import numpy as np, torch, torch.nn.functional as F
from kokoro.model import KModel

W, CORE, OV = 64, 40, 12          # window, kept core, overlap each side (qai-hub Piper/Melo)
U = 600                           # samples per asr frame (10*6*5*2)
import os
M = pathlib.Path(os.environ['KOKORO_MODEL_DIR'])          # directory with kokoro-v1_0.pth, config.json, voices/
OUT = pathlib.Path(sys.argv[1])
OUT.mkdir(parents=True, exist_ok=True)
torch.manual_seed(0)

cfg = json.loads((M / 'config.json').read_text(encoding='utf-8'))
km = KModel(repo_id='hexgrad/Kokoro-82M', config=str(M / 'config.json'),
            model=str(M / 'kokoro-v1_0.pth'), disable_complex=True).eval()
dec, gen = km.decoder, km.decoder.generator

class Core(torch.nn.Module):
    """Decoder.forward with the stochastic harmonic source lifted to an input."""
    def __init__(s, d): super().__init__(); s.d = d
    def forward(s, asr, F0_curve, N, style, har_source):
        d, g = s.d, s.d.generator
        F0 = d.F0_conv(F0_curve.unsqueeze(1)); Nn = d.N_conv(N.unsqueeze(1))
        x = d.encode(torch.cat([asr, F0, Nn], 1), style)
        asr_res = d.asr_res(asr); res = True
        for b in d.decode:
            if res: x = torch.cat([x, asr_res, F0, Nn], 1)
            x = b(x, style)
            if b.upsample_type != 'none': res = False
        spec, phase = g.stft.transform(har_source)
        har = torch.cat([spec, phase], 1)
        for i in range(g.num_upsamples):
            x = F.leaky_relu(x, 0.1)
            xs_ = g.noise_res[i](g.noise_convs[i](har), style)
            x = g.ups[i](x)
            if i == g.num_upsamples - 1: x = g.reflection_pad(x)
            x = x + xs_
            acc = None
            for j in range(g.num_kernels):
                r = g.resblocks[i * g.num_kernels + j](x, style)
                acc = r if acc is None else acc + r
            x = acc / g.num_kernels
        x = g.conv_post(F.leaky_relu(x))
        n = g.post_n_fft // 2 + 1
        return g.stft.inverse(torch.exp(x[:, :n]), torch.sin(x[:, n:]))

core = Core(dec).eval()

# Real decoder inputs: capture them from one full forward pass.
ph = 'həlˈoʊ wˈɜɹld. ðɪs ɪz kˈoʊkəɹoʊ ɑn hɛksəɡˌɑn.'
ids = [0] + [cfg['vocab'][c] for c in ph if c in cfg['vocab']] + [0]
ref_s = torch.load(M / 'voices' / 'af_heart.pt', weights_only=True)[len(ids) - 2]
cap = {}
dec.register_forward_hook(lambda m, a, o: cap.update(asr=a[0], F0=a[1], N=a[2], s=a[3]))
with torch.no_grad():
    km.forward_with_tokens(torch.tensor([ids]), ref_s)
    # Edge-replicate OV frames (+ tail to a whole core) so no window sees exact zeros.
    T0 = cap['asr'].shape[-1]; tail = OV + (-T0) % CORE
    rep = lambda t, r: F.pad(t.reshape(1, -1, t.shape[-1]), (OV * r, tail * r), mode='replicate').reshape(*t.shape[:-1], -1)
    cap.update(asr=rep(cap['asr'], 1), F0=rep(cap['F0'], 2), N=rep(cap['N'], 2))
    f0u = gen.f0_upsamp(cap['F0'][:, None]).transpose(1, 2)
    har_source = gen.m_source(f0u)[0].transpose(1, 2).squeeze(1)      # [1, T*U], continuous phase
    T = cap['asr'].shape[-1]
    full = core(cap['asr'], cap['F0'], cap['N'], cap['s'], har_source).squeeze().numpy()
print(f'T={T} frames  samples={full.size}  expected={T*U}')

# Static export: one window.
ex = (torch.zeros(1, 512, W), torch.zeros(1, 2 * W), torch.zeros(1, 2 * W),
      torch.zeros(1, 128), torch.zeros(1, W * U))
onnx_path = OUT / f'kokoro_decoder_w{W}.onnx'
torch.onnx.export(core, ex, str(onnx_path), dynamo=False, opset_version=17,
                  input_names=['asr', 'F0_curve', 'N', 'style', 'har_source'], output_names=['audio'])

# CPU gate: windowed ORT run, stitched, against the full-length torch reference.
import onnxruntime as ort
sess = ort.InferenceSession(str(onnx_path), providers=['CPUExecutionProvider'])
def win(t, start, rate):        # [..., T*rate] -> zero-padded window of W*rate
    a, b = (start - OV) * rate, (start - OV + W) * rate
    out = torch.zeros(*t.shape[:-1], W * rate)
    lo, hi = max(a, 0), min(b, t.shape[-1])
    if hi > lo: out[..., lo - a:hi - a] = t[..., lo:hi]
    return out.numpy()
pcm = []
for st in range(OV, OV + T0, CORE):
    o = sess.run(None, {'asr': win(cap['asr'], st, 1), 'F0_curve': win(cap['F0'], st, 2),
                        'N': win(cap['N'], st, 2), 'style': cap['s'].numpy(),
                        'har_source': win(har_source, st, U)})[0].reshape(-1)
    pcm.append(o[OV * U:(OV + CORE) * U])
pcm = np.concatenate(pcm)[:T0 * U]; full = full[OV * U:(OV + T0) * U]
err = pcm - full
snr = 10 * math.log10((full ** 2).sum() / max((err ** 2).sum(), 1e-20))
print(f'windows={math.ceil(T0/CORE)} T0={T0}  max_abs_err={np.abs(err).max():.6f}  SNR={snr:.2f} dB')

import wave
for name, a in (('reference_full', full), ('stitched_cpu', pcm)):
    with wave.open(str(OUT / f'{name}.wav'), 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(24000)
        w.writeframes((np.clip(a, -1, 1) * 32767).astype('<i2').tobytes())
np.savez(OUT / 'decoder_inputs.npz', asr=cap['asr'].numpy(), F0=cap['F0'].numpy(),
         N=cap['N'].numpy(), s=cap['s'].numpy(), har_source=har_source.numpy(), full=full)
print('onnx', hashlib.sha256(onnx_path.read_bytes()).hexdigest().upper(), onnx_path.stat().st_size)
