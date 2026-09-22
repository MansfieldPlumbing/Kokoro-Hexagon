# Split the masked fixed-capacity decoder into front (frame rate) and generator graphs; verify the chain.
import sys, math, pathlib, hashlib, numpy as np, torch, torch.nn.functional as F
ARGS = list(sys.argv)                   # split_export.py <export_decoder.py> <masked.py> <outdir> <W>
sys.argv = ['x', ARGS[1], ARGS[3], ARGS[4]]
g = {'__name__': 'split'}; exec(open(ARGS[2], encoding='utf-8').read(), g)   # builds masked Cap, cap, har, full, pad, mask
core, cap, har, full, pad, mask, L, W, U, CUR, snr = (g[k] for k in ('core', 'cap', 'har', 'full', 'pad', 'mask', 'L', 'W', 'U', 'CUR', 'snr'))
d, gen = core.d, core.d.generator

class Front(torch.nn.Module):
    def __init__(s): super().__init__(); s.d = d
    def forward(s, asr, F0_curve, N, style, mask):
        CUR['mask'] = mask; asr = asr * mask
        F0 = d.F0_conv(F0_curve.unsqueeze(1)); Nn = d.N_conv(N.unsqueeze(1))
        x = d.encode(torch.cat([asr, F0, Nn], 1), style)
        asr_res = d.asr_res(asr); res = True
        for b in d.decode:
            if res: x = torch.cat([x, asr_res, F0, Nn], 1)
            x = b(x, style)
            if b.upsample_type != 'none': res = False
        return x

class Gen(torch.nn.Module):
    def __init__(s): super().__init__(); s.g = gen
    def forward(s, x, style, har_source, mask):
        CUR['mask'] = mask; g_ = s.g
        spec, phase = g_.stft.transform(har_source); har = torch.cat([spec, phase], 1)
        for i in range(g_.num_upsamples):
            x = F.leaky_relu(x, 0.1)
            xs_ = g_.noise_res[i](g_.noise_convs[i](har), style)
            x = g_.ups[i](x)
            if i == g_.num_upsamples - 1: x = g_.reflection_pad(x)
            x = x + xs_
            acc = None
            for j in range(g_.num_kernels):
                r = g_.resblocks[i * g_.num_kernels + j](x, style); acc = r if acc is None else acc + r
            x = acc / g_.num_kernels
        x = g_.conv_post(F.leaky_relu(x)); n = g_.post_n_fft // 2 + 1
        return g_.stft.inverse(torch.exp(x[:, :n]), torch.sin(x[:, n:]))

out = pathlib.Path(ARGS[3]); fr, ge = Front().eval(), Gen().eval()
ins = dict(asr=pad(cap['asr'], 1), F0=pad(cap['F0'], 2), N=pad(cap['N'], 2), s=cap['s'], har=pad(har, U))
with torch.no_grad():
    x = fr(ins['asr'], ins['F0'], ins['N'], ins['s'], mask)
    y = ge(x, ins['s'], ins['har'], mask).reshape(-1).numpy()[:L * U]
print(f'front out {tuple(x.shape)}  chain SNR vs full={snr(full, y):.2f} dB')
torch.onnx.export(fr, (ins['asr'], ins['F0'], ins['N'], ins['s'], mask), str(out / f'kokoro_front_c{W}.onnx'), dynamo=False, opset_version=17,
                  input_names=['asr', 'F0_curve', 'N', 'style', 'mask'], output_names=['x'])
torch.onnx.export(ge, (x, ins['s'], ins['har'], mask), str(out / f'kokoro_gen_c{W}.onnx'), dynamo=False, opset_version=17,
                  input_names=['x', 'style', 'har_source', 'mask'], output_names=['audio'])
for n in (f'kokoro_front_c{W}.onnx', f'kokoro_gen_c{W}.onnx'):
    p = out / n; print(n, p.stat().st_size, hashlib.sha256(p.read_bytes()).hexdigest().upper()[:16])
np.save(out / f'front_x_c{W}.npy', x.numpy())

# --- spectral generator: STFT and iSTFT on CPU; graph ends at conv_post ---
class GenSpec(torch.nn.Module):
    def __init__(s): super().__init__(); s.g = gen
    def forward(s, x, style, har, mask):
        CUR['mask'] = mask; g_ = s.g
        for i in range(g_.num_upsamples):
            x = F.leaky_relu(x, 0.1)
            xs_ = g_.noise_res[i](g_.noise_convs[i](har), style)
            x = g_.ups[i](x)
            if i == g_.num_upsamples - 1: x = g_.reflection_pad(x)
            x = x + xs_
            acc = None
            for j in range(g_.num_kernels):
                r = g_.resblocks[i * g_.num_kernels + j](x, style); acc = r if acc is None else acc + r
            x = acc / g_.num_kernels
        return g_.conv_post(F.leaky_relu(x))
gs = GenSpec().eval()
with torch.no_grad():
    sp_, ph_ = gen.stft.transform(ins['har']); har_in = torch.cat([sp_, ph_], 1)
    post = gs(x, ins['s'], har_in, mask); n = gen.post_n_fft // 2 + 1
    y2 = gen.stft.inverse(torch.exp(post[:, :n]), torch.sin(post[:, n:])).reshape(-1).numpy()[:L * U]
print(f'har_in {tuple(har_in.shape)}  post {tuple(post.shape)}  spectral chain SNR vs full={snr(full, y2):.2f} dB')
torch.onnx.export(gs, (x, ins['s'], har_in, mask), str(out / f'kokoro_genspec_c{W}.onnx'), dynamo=False, opset_version=17,
                  input_names=['x', 'style', 'har', 'mask'], output_names=['post'])
p = out / f'kokoro_genspec_c{W}.onnx'; print(p.name, p.stat().st_size)
