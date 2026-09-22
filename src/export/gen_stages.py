# Generator split by upsampling stage at full phrase capacity (masked stats stay exact). Writes ONNX + inputs/oracles per stage.
import sys, numpy as np, torch, torch.nn.functional as F
ARGS = list(sys.argv)          # gen_stages.py <export_decoder.py> <masked.py> <outdir> <W>
sys.argv = ['x', ARGS[1], ARGS[3], ARGS[4]]
g = {'__name__': 'stages'}; exec(open(ARGS[2], encoding='utf-8').read(), g)
core, cap, har, pad, mask, U, CUR, W = (g[k] for k in ('core', 'cap', 'har', 'pad', 'mask', 'U', 'CUR', 'W'))
d = core.d; gen = d.generator; out = ARGS[3]
ins = dict(asr=pad(cap['asr'], 1), F0=pad(cap['F0'], 2), N=pad(cap['N'], 2), s=cap['s'], har=pad(har, U))

class Stage(torch.nn.Module):
    def __init__(s, i): super().__init__(); s.i = i; s.g = gen
    def forward(s, x, style, har, mask):
        CUR['mask'] = mask; g_ = s.g; i = s.i
        if i == g_.num_upsamples - 1: CUR['mask_by_len'] = {mask.shape[-1]: mask}
        x = F.leaky_relu(x, 0.1)
        xs_ = g_.noise_res[i](g_.noise_convs[i](har), style)
        x = g_.ups[i](x)
        if i == g_.num_upsamples - 1: x = g_.reflection_pad(x)
        x = x + xs_
        acc = None
        for j in range(g_.num_kernels):
            r = g_.resblocks[i * g_.num_kernels + j](x, style); acc = r if acc is None else acc + r
        return acc / g_.num_kernels
class Post(torch.nn.Module):
    def __init__(s): super().__init__(); s.g = gen
    def forward(s, x): return s.g.conv_post(F.leaky_relu(x))

def f32(name, t): t.detach().numpy().astype('<f4').tofile(f'{out}\\{name}.f32')
with torch.no_grad():
    CUR['mask'] = mask
    x = d.encode  # placeholder to keep names aligned
    # Front (fp32 reference) to obtain the generator input
    F0c, Nc, asr = ins['F0'], ins['N'], ins['asr'] * mask
    F0 = d.F0_conv(F0c.unsqueeze(1)); Nn = d.N_conv(Nc.unsqueeze(1))
    x = d.encode(torch.cat([asr, F0, Nn], 1), ins['s']); ar = d.asr_res(asr); res = True
    for b in d.decode:
        if res: x = torch.cat([x, ar, F0, Nn], 1)
        x = b(x, ins['s'])
        if b.upsample_type != 'none': res = False
    sp_, ph_ = gen.stft.transform(ins['har']); harin = torch.cat([sp_, ph_], 1)
    f32('in_style', ins['s']); f32('in_mask', mask); f32('in_har', harin)
    cur = x
    for i in range(gen.num_upsamples):
        f32(f'in_x{i}', cur)
        mk = F.interpolate(mask, size=harin.shape[-1], mode='nearest') if i == gen.num_upsamples - 1 else mask
        f32(f'in_mask{i}', mk)
        st = Stage(i).eval(); y = st(cur, ins['s'], harin, mk); CUR.pop('mask_by_len', None)
        torch.onnx.export(st, (cur, ins['s'], harin, mk), f'{out}\\kokoro_gen{i}_c{W}.onnx', dynamo=False, opset_version=17,
                          input_names=[f'x{i}', 'style', 'har', f'mask{i}'], output_names=[f'y{i}'])
        f32(f'oracle_y{i}', y); print(f'stage{i}: in {tuple(cur.shape)} -> out {tuple(y.shape)}'); cur = y
    f32('in_xp', cur); po = Post().eval(); y = po(cur)
    torch.onnx.export(po, (cur,), f'{out}\\kokoro_genpost_c{W}.onnx', dynamo=False, opset_version=17, input_names=['xp'], output_names=['post'])
    f32('oracle_post', y); print(f'post: -> {tuple(y.shape)}')

# --- stage 1 split into sub-graphs (compile memory) ---
i = gen.num_upsamples - 1
class G1U(torch.nn.Module):
    def __init__(s): super().__init__(); s.g = gen
    def forward(s, x): return s.g.reflection_pad(s.g.ups[i](F.leaky_relu(x, 0.1)))
class G1N(torch.nn.Module):
    def __init__(s): super().__init__(); s.g = gen
    def forward(s, har, style, mask):
        CUR['mask'] = mask; CUR['mask_by_len'] = {mask.shape[-1]: mask}
        return s.g.noise_res[i](s.g.noise_convs[i](har), style)
class G1R(torch.nn.Module):
    def __init__(s, j): super().__init__(); s.g = gen; s.j = j
    def forward(s, z, style, mask):
        CUR['mask'] = mask; CUR['mask_by_len'] = {mask.shape[-1]: mask}
        return s.g.resblocks[i * s.g.num_kernels + s.j](z, style)
x1 = torch.from_numpy(np.fromfile(f'{out}\\in_x1.f32', dtype='<f4').reshape(1, 256, -1))
mk = torch.from_numpy(np.fromfile(f'{out}\\in_mask1.f32', dtype='<f4').reshape(1, 1, -1))
with torch.no_grad():
    u = G1U()(x1); n = G1N()(harin, ins['s'], mk); z = u + n
    torch.onnx.export(G1U().eval(), (x1,), f'{out}\\kokoro_g1u_c{W}.onnx', dynamo=False, opset_version=17, input_names=['x1'], output_names=['u'])
    torch.onnx.export(G1N().eval(), (harin, ins['s'], mk), f'{out}\\kokoro_g1n_c{W}.onnx', dynamo=False, opset_version=17, input_names=['har', 'style', 'mask1'], output_names=['n'])
    f32('oracle_u', u); f32('oracle_n', n); f32('in_z', z); acc = None
    for j in range(gen.num_kernels):
        r = G1R(j)(z, ins['s'], mk); acc = r if acc is None else acc + r
        torch.onnx.export(G1R(j).eval(), (z, ins['s'], mk), f'{out}\\kokoro_g1r{j}_c{W}.onnx', dynamo=False, opset_version=17, input_names=['z', 'style', 'mask1'], output_names=[f'r{j}'])
        f32(f'oracle_r{j}', r)
    y1 = acc / gen.num_kernels
    ref = torch.from_numpy(np.fromfile(f'{out}\\oracle_y1.f32', dtype='<f4').reshape(y1.shape))
    print('stage1 split recombined vs y1 max_abs', float((y1 - ref).abs().max()))

# --- length experiment: pad 19201 -> multiple of 8 (masked tail) ---
Lp = ((harin.shape[-1] + 7) // 8) * 8
harp = F.pad(harin, (0, Lp - harin.shape[-1]), mode='replicate'); mkp = F.pad(mk, (0, Lp - mk.shape[-1]))
with torch.no_grad():
    np8 = G1N()(harp, ins['s'], mkp)
    print('padded g1n vs unpadded (valid region) max_abs', float((np8[..., :harin.shape[-1]] - n).abs().max()), 'Lp', Lp)
    torch.onnx.export(G1N().eval(), (harp, ins['s'], mkp), f'{out}\\kokoro_g1n8_c{W}.onnx', dynamo=False, opset_version=17, input_names=['har8', 'style', 'mask8'], output_names=['n8'])

# --- whole generator with stage-1 length aligned to 8 (masked tail) ---
HL = harin.shape[-1]
class Gen8(torch.nn.Module):
    def __init__(s): super().__init__(); s.g = gen
    def forward(s, x, style, har8, mask, mask8):
        g_ = s.g; CUR['mask'] = mask; CUR['mask_by_len'] = {mask8.shape[-1]: mask8}
        for i in range(g_.num_upsamples):
            x = F.leaky_relu(x, 0.1)
            hh = har8 if i == g_.num_upsamples - 1 else har8[..., :HL]
            xs_ = g_.noise_res[i](g_.noise_convs[i](hh), style)
            x = g_.ups[i](x)
            if i == g_.num_upsamples - 1:
                x = g_.reflection_pad(x); x = F.pad(x, (0, har8.shape[-1] - x.shape[-1]))
            x = x + xs_
            acc = None
            for j in range(g_.num_kernels):
                r = g_.resblocks[i * g_.num_kernels + j](x, style); acc = r if acc is None else acc + r
            x = acc / g_.num_kernels
        return g_.conv_post(F.leaky_relu(x))
x0 = torch.from_numpy(np.fromfile(f'{out}\\in_x0.f32', dtype='<f4').reshape(1, 512, -1))
with torch.no_grad():
    y8 = Gen8()(x0, ins['s'], harp, mask, mkp)
    ref = torch.from_numpy(np.fromfile(f'{out}\\oracle_post.f32', dtype='<f4').reshape(1, 22, -1))
    Lv = int(mask.sum().item()) * 120
    print('Gen8 vs unpadded post, valid region max_abs', float((y8[..., :Lv] - ref[..., :Lv]).abs().max()), 'shape', tuple(y8.shape))
    torch.onnx.export(Gen8().eval(), (x0, ins['s'], harp, mask, mkp), f'{out}\\kokoro_gen8_c{W}.onnx', dynamo=False, opset_version=17,
                      input_names=['x0', 'style', 'har8', 'mask', 'mask8'], output_names=['post8'])
    f32('in_har8', harp); f32('in_mask8', mkp); f32('oracle_post8', y8)

# --- consistent phrase set for the device run: front inputs + reference audio from this same exec ---
full = g['full']; L = g['L']
for k, n in (('asr', 'asr'), ('F0', 'F0_curve'), ('N', 'N')): f32(f'in_{n}', ins[k])
f32('oracle_audio', torch.from_numpy(np.ascontiguousarray(full)))
print('phrase: L', L, 'samples', full.shape[-1])

# --- generator with iSTFT inside the graph: waveform out ---
class GenWave(torch.nn.Module):
    def __init__(s): super().__init__(); s.gen8 = Gen8(); s.g = gen
    def forward(s, x, style, har8, mask, mask8):
        post = s.gen8(x, style, har8, mask, mask8); n = s.g.post_n_fft // 2 + 1
        return s.g.stft.inverse(torch.exp(post[:, :n]), torch.sin(post[:, n:]))
with torch.no_grad():
    wav = GenWave()(x0, ins['s'], harp, mask, mkp).reshape(-1)
    Lv = int(mask.sum().item()) * 600
    ref = torch.from_numpy(np.ascontiguousarray(g['full']))
    e = wav[:Lv] - ref[:Lv]
    print('GenWave samples', wav.numel(), 'valid SNR vs full %.2f dB' % float(10 * torch.log10((ref[:Lv] ** 2).sum() / (e ** 2).sum())))
    torch.onnx.export(GenWave().eval(), (x0, ins['s'], harp, mask, mkp), f'{out}\\kokoro_genwave_c{W}.onnx', dynamo=False, opset_version=17,
                      input_names=['x0', 'style', 'har8', 'mask', 'mask8'], output_names=['audio'])
    f32('oracle_audio_full', wav)

# --- generator with per-voice gamma/beta table instead of style (no fc/Gemm in graph) ---
g['gb_register'](core.d)
class GenWaveGB(torch.nn.Module):
    def __init__(s): super().__init__(); s.w = GenWave()
    def forward(s, x, gb, har8, mask, mask8):
        CUR['gb'] = gb
        return s.w(x, gb, har8, mask, mask8)
with torch.no_grad():
    gbv = g['gb_compute'](ins['s'])
    wav_gb = GenWaveGB()(x0, gbv, harp, mask, mkp).reshape(-1); CUR.pop('gb', None)
    print('GenWaveGB gb', tuple(gbv.shape), 'vs GenWave max_abs', float((wav_gb - wav).abs().max()))
    torch.onnx.export(GenWaveGB().eval(), (x0, gbv, harp, mask, mkp), f'{out}\\kokoro_genwavegb_c{W}.onnx', dynamo=False, opset_version=17,
                      input_names=['x0', 'gb', 'har8', 'mask', 'mask8'], output_names=['audio'])
    CUR.pop('gb', None); f32('in_gb', gbv)

# --- canonical norm form: native InstanceNormalization + per-voice gb (no fc) ---
g['NATIVE_IN'] = True
with torch.no_grad():
    CUR['gb'] = gbv
    wav_nin = GenWaveGB()(x0, gbv, harp, mask, mkp).reshape(-1); CUR.pop('gb', None)
    Lv = int(mask.sum().item()) * 600
    print('native-IN gb vs masked gb max_abs', float((wav_nin - wav_gb).abs().max()), ' valid SNR vs full %.2f dB' % float(10 * torch.log10((ref[:Lv] ** 2).sum() / ((wav_nin[:Lv] - ref[:Lv]) ** 2).sum())))
    torch.onnx.export(GenWaveGB().eval(), (x0, gbv, harp, mask, mkp), f'{out}\\kokoro_genwavenin_c{W}.onnx', dynamo=False, opset_version=17,
                      input_names=['x0', 'gb', 'har8', 'mask', 'mask8'], output_names=['audio'])
    CUR.pop('gb', None)
g['NATIVE_IN'] = False
