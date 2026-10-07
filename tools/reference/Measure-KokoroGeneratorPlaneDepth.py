"""Reference only: PCM fidelity of the stock generator with byte-plane quantization per conv.

Runs pinned stock PyTorch Kokoro once per capture spec, records the generator's
inputs and RNG state, then replays only the generator under each configuration.
Every Conv1d and ConvTranspose1d gets its input, weight and output represented by
n signed byte planes (A8xn, W8xn, O8xn): activations per tensor, weights per output
channel. exp/sin/iSTFT stay stock. Score: raw PCM SNR against the unquantized
replay, which must equal the saved stock capture output exactly.

--model storage: every conv output is a stored 8-bit-plane boundary.
--model recompute: conv inputs are regenerated per tile (planes cost compute),
convs1 and conv_post outputs feed the next stage wide, and only stored tensors
(residual stream after each add, ups/noise_convs stage outputs) take output planes.
--greedy-target D: start every conv at x2/x2/x2 and drop single planes, least
harmful first, while every capture stays at or above D dB.
"""
import argparse, hashlib, importlib, json, pathlib, sys, time, types

ROOT = pathlib.Path(__file__).resolve().parents[2]
def digest(p): return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest().upper()

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--spec', type=pathlib.Path, action='append', required=True,
                    help='capture-spec.json of an existing stock generator capture')
parser.add_argument('--output', type=pathlib.Path, required=True)
parser.add_argument('--model', choices=('storage', 'recompute'), default='storage')
parser.add_argument('--clip', choices=('absmax', 'mse'), default='absmax',
                    help='single-plane activation scale: absmax/127, or the per-tensor clip minimizing MSE')
parser.add_argument('--greedy-target', type=float,
                    help='run the greedy plane reduction to this PCM SNR (dB) instead of the global/leave-one-out sweep')
parser.add_argument('--render-plan', type=pathlib.Path,
                    help='report.json of a greedy run: write stock and plan WAVs per capture instead of searching')
args = parser.parse_args()
out = args.output.resolve()
if out.exists() or not out.is_relative_to(ROOT/'build'):
    raise ValueError('Use a fresh output directory inside build/')

import numpy as np
import torch
from torch.nn.utils import parametrize
torch.set_num_threads(4)  # matches capture_stock_generator.py; reductions must bit-match the capture

def planes(x, scale, n):
    r = x/scale; acc = torch.clamp(torch.round(r), -127, 127)
    for k in range(1, n):
        acc = acc + torch.clamp(torch.round((r-acc)*256**k), -128, 127)/256**k
    return acc*scale

CLIPS = (1.0, 0.75, 0.5, 0.35, 0.25, 0.18, 0.125, 0.09, 0.0625)
def single_scale(x, amax):
    # Same-utterance calibration: the clip fraction whose one-plane rounding has least MSE.
    if args.clip == 'absmax': return amax/127
    best = min(CLIPS, key=lambda c: float(torch.mean((planes(x, amax*c/127, 1)-x)**2)))
    return amax*best/127

class WeightPlanes(torch.nn.Module):
    def __init__(self, axis): super().__init__(); self.axis = axis; self.n = 0
    def forward(self, w):
        if self.n == 0: return w
        dims = [d for d in range(w.dim()) if d != self.axis]
        return planes(w, torch.clamp(w.abs().amax(dim=dims, keepdim=True), min=1e-12)/127, self.n)

def snr(a, r):
    a = a.double(); r = r.double()
    return float(10*torch.log10(torch.sum(r*r)/torch.clamp(torch.sum((a-r)**2), min=1e-300)))

def role(name):
    if args.model == 'storage': return 'stored'
    if '.convs2.' in name: return 'residual'
    if name.startswith(('ups.', 'noise_convs.')): return 'stored'
    return 'wide'

def passes(i, w):
    # Plane-pair products kept to leading order: pairs (a, b) with a + b < max(i, w).
    return sum(1 for a in range(i) for b in range(w) if a+b < max(i, w)) if i and w else 1

class Capture:
    def __init__(self, spec_path):
        spec = json.loads(spec_path.read_text(encoding='utf-8-sig'))
        self.spec_path, self.spec = spec_path, spec
        root = pathlib.Path(spec['sourceRoot'])
        if spec['sourceCommit'] != json.loads((ROOT/'lib/manifest.json').read_text(encoding='utf-8-sig'))['kokoroSource']['commit']:
            raise ValueError('Stock source commit differs from repository pin')
        for item in spec['sourceFiles']:
            if digest(root/item['path']) != item['sha256']: raise ValueError('Stock source integrity')
        for item in spec['inputs'].values():
            if digest(item['path']) != item['sha256']: raise ValueError('Stock input integrity')
        package = types.ModuleType('kokoro'); package.__path__ = [str(root/'kokoro')]
        for name in [m for m in sys.modules if m == 'kokoro' or m.startswith('kokoro.')]: del sys.modules[name]
        sys.modules['kokoro'] = package
        from loguru import logger; logger.remove(); logger.add(sys.stderr, level='WARNING')
        torch.manual_seed(spec['seed'])  # before construction, as capture_stock_generator.py does
        model = importlib.import_module('kokoro.model').KModel(repo_id='hexgrad/Kokoro-82M',
            config=spec['inputs']['config.json']['path'], model=spec['inputs']['kokoro-v1_0.pth']['path']).eval()
        pack = torch.load(spec['inputs']['voices\\'+spec['voice']+'.pt']['path'], map_location='cpu', weights_only=True)
        phonemes = spec['phonemes']
        if not (1 <= len(phonemes) <= 510) or any(p not in model.vocab for p in phonemes):
            raise ValueError('Phonemes out of bounds or outside the stock vocabulary')
        self.gen = gen = model.decoder.generator
        self.convs = [(n, m) for n, m in gen.named_modules() if isinstance(m, (torch.nn.Conv1d, torch.nn.ConvTranspose1d))]
        state = {}
        def grab(module, a, kw):
            state['args'] = tuple(t.detach().clone() for t in a); state['rng'] = torch.get_rng_state()
        h = gen.register_forward_pre_hook(grab, with_kwargs=True)
        with torch.no_grad(): full = model(phonemes, pack[len(phonemes)-1], speed=1).reshape(-1)
        h.remove(); self.state = state
        manifest = json.loads((pathlib.Path(spec['output'])/'capture.json').read_text(encoding='utf-8-sig'))
        stock_file = pathlib.Path(spec['output'])/manifest['tensors']['output']['file']
        if digest(stock_file) != manifest['tensors']['output']['sha256']: raise ValueError('Capture output integrity')
        stock = torch.from_numpy(np.fromfile(stock_file, '<f4')).reshape(-1)

        self.cfg = cfg = {}; amax = {}; track = {}; self.macs = macs = {}; flags = dict(calibrating=False)
        for bname, block in gen.named_modules():
            if type(block).__name__ == 'AdaINResBlock1':
                block.register_forward_pre_hook(lambda mod, a, b=bname: track.__setitem__(b, a[0]))
        for name, m in self.convs:
            axis = 1 if isinstance(m, torch.nn.ConvTranspose1d) else 0
            wp = WeightPlanes(axis); parametrize.register_parametrization(m, 'weight', wp)
            cfg[name] = dict(i=0, w=wp, o=0)
            def pre(mod, a, name=name):
                x = a[0]
                if flags['calibrating']:
                    amax[name+'.i'] = max(float(x.abs().max()), 1e-12); amax[name+'.i1'] = single_scale(x, amax[name+'.i'])
                n = cfg[name]['i']
                return (planes(x, amax[name+'.i1'] if n == 1 else amax[name+'.i']/127, n),) if n else None
            def post(mod, a, y, name=name):
                if flags['calibrating']:
                    w = mod.weight; k = w.shape[2]
                    frames = a[0].shape[2] if isinstance(mod, torch.nn.ConvTranspose1d) else y.shape[2]
                    macs[name] = int(w.shape[0]*w.shape[1]*k*frames)
                r = role(name)
                if r == 'wide': return None
                if r == 'residual':
                    # Stock adds x = xt + x after convs2; quantize that stored sum, return q - x_prev.
                    b = name.rsplit('.convs2.', 1)[0]; prev = track[b]; s = y + prev
                    if flags['calibrating']:
                        amax[name+'.o'] = max(float(s.abs().max()), 1e-12); amax[name+'.o1'] = single_scale(s, amax[name+'.o'])
                    n = cfg[name]['o']
                    q = planes(s, amax[name+'.o1'] if n == 1 else amax[name+'.o']/127, n) if n else s
                    track[b] = q
                    return (q - prev) if n else None
                if flags['calibrating']:
                    amax[name+'.o'] = max(float(y.abs().max()), 1e-12); amax[name+'.o1'] = single_scale(y, amax[name+'.o'])
                n = cfg[name]['o']
                return planes(y, amax[name+'.o1'] if n == 1 else amax[name+'.o']/127, n) if n else None
            m.register_forward_pre_hook(pre); m.register_forward_hook(post)
        flags['calibrating'] = True
        self.base = self.run(lambda n: (0, 0, 0))
        flags['calibrating'] = False
        if not torch.equal(self.base, full): raise ValueError('Generator replay does not reproduce the full stock run')
        if not torch.equal(full, stock): raise ValueError('Stock run differs from the saved capture output')

    def run(self, setting):
        for name, _ in self.convs:
            i, w, o = setting(name); self.cfg[name]['i'] = i; self.cfg[name]['w'].n = w; self.cfg[name]['o'] = o
        torch.set_rng_state(self.state['rng'])
        with torch.no_grad(): return self.gen(*self.state['args']).reshape(-1)

    def score(self, setting): return snr(self.run(setting), self.base)

def compute_multiplier(plan, macs):
    # HMX work relative to today's single-plane path (one pass per conv, conv1 once).
    today = sum(macs.values())
    cost = sum(passes(i, w)*macs[n]*(2 if args.model == 'recompute' and '.convs1.' in n else 1)
               for n, (i, w, o) in plan.items())
    return cost/today

out.mkdir(parents=True)
t0 = time.time()
caps = [Capture(p) for p in args.spec]
names = [n for n, _ in caps[0].convs]
report = dict(scope='Reference only. Stock generator with byte-plane quantization at every conv; stock AdaIN, '
    'Snake, residual arithmetic and tail in float. Activation scales calibrated on the same utterance.',
    toolSHA256=digest(__file__), model=args.model, singlePlaneActivationScale=args.clip,
    captures=[dict(spec=str(c.spec_path), voice=c.spec['voice'], seed=c.spec['seed'], phonemes=c.spec['phonemes'],
                   samples=int(c.base.numel()), stockReplayExact=True) for c in caps],
    convMacs=caps[0].macs)

if args.render_plan is not None:
    import wave
    source = json.loads(args.render_plan.read_text(encoding='utf-8'))
    if source.get('model') != args.model: raise ValueError('Plan was searched under a different dataflow model')
    plan = {n: (v['A'], v['W'], v['O'] or 0) for n, v in source['plan'].items()}
    if set(plan) != set(names): raise ValueError('Plan conv names differ from this generator')
    def write(path, x):
        pcm = np.clip(np.rint(x.numpy()*32767), -32768, 32767).astype('<i2')
        with wave.open(str(path), 'wb') as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(24000); w.writeframes(pcm.tobytes())
    report['renderedPlan'] = dict(source=str(args.render_plan), sourceSHA256=digest(args.render_plan), files=[])
    for c in caps:
        y = c.run(lambda n: plan[n]); v = c.spec['voice']
        write(out/f'{v}-1-stock.wav', c.base); write(out/f'{v}-2-plan.wav', y)
        report['renderedPlan']['files'].append(dict(voice=v, pcmSnrDb=snr(y, c.base)))
elif args.greedy_target is None:
    for c, entry in zip(caps, report['captures']):
        entry['globalPcmSnrDb'] = {f'A8x{i}/W8x{w}/O8x{o}': c.score(lambda n: (i, w, o))
                                   for i in (1, 2, 3) for w in (1, 2) for o in (1, 2, 3)}
        entry['leaveOneOutBaseSnrDb'] = c.score(lambda n: (2, 2, 2))
        entry['leaveOneOutToSinglePlanePcmSnrDb'] = {t: c.score(lambda n, t=t: (1, 1, 1) if n == t else (2, 2, 2)) for t in names}
    report['leaveOneOutBase'] = 'A8x2/W8x2/O8x2'
else:
    plan = {n: [2, 2, 2] for n in names}
    def worst(p): return min(c.score(lambda n: tuple(p[n])) for c in caps)
    start = worst(plan)
    # Candidate single-plane drops; output drops only where the output is a stored tensor.
    cands = [(n, k) for n in names for k in (0, 1, 2) if k < 2 or role(n) != 'wide']
    trial = {}
    for n, k in cands:
        p = {m: list(v) for m, v in plan.items()}; p[n][k] = 1; trial[(n, k)] = worst(p)
    accepted = []
    for (n, k) in sorted(cands, key=lambda c: -trial[c]):
        if trial[(n, k)] < args.greedy_target: continue
        p = {m: list(v) for m, v in plan.items()}; p[n][k] = 1
        s = worst(p)
        if s >= args.greedy_target: plan = p; accepted.append(dict(conv=n, operand='AWO'[k], worstSnrDb=s))
    final = {c.spec['voice']: c.score(lambda n: tuple(plan[n])) for c in caps}
    full2 = {n: (2, 2, 2) for n in names}
    report.update(greedyTargetDb=args.greedy_target, startWorstSnrDb=start, finalSnrDb=final,
        singleDropWorstSnrDb={f'{n}:{"AWO"[k]}': v for (n, k), v in trial.items()}, acceptedDrops=accepted,
        plan={n: dict(A=v[0], W=v[1], O=v[2] if role(n) != 'wide' else None, role=role(n), hmxPasses=passes(v[0], v[1]))
              for n, v in plan.items()},
        hmxWorkVsToday=dict(allPlanesX2=compute_multiplier(full2, caps[0].macs),
                            greedyPlan=compute_multiplier({n: tuple(v) for n, v in plan.items()}, caps[0].macs)),
        storedTensorsAtX2=[n for n, v in plan.items() if role(n) != 'wide' and v[2] == 2])
report['seconds'] = round(time.time()-t0, 1)
(out/'report.json').write_text(json.dumps(report, indent=2))
print('Report:', out/'report.json', 'seconds', report['seconds'])
if args.greedy_target is not None:
    print('final', {k: round(v, 2) for k, v in report['finalSnrDb'].items()}, 'accepted drops', len(report['acceptedDrops']),
          'HMX work vs today', {k: round(v, 2) for k, v in report['hmxWorkVsToday'].items()})
