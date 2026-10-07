"""Windows reference only: PCM fidelity of the generator tail with each 8-bit boundary removed.

Boundaries: conv_post input (A8 versus two signed byte planes) and the 8-bit
logit codes before exp/sin. Inputs are stock final LeakyReLU captures, so the
result bounds the tail itself, not upstream generator error.
"""
import argparse, contextlib, io, json, pathlib, runpy, sys
import numpy as np
import torch

ROOT = pathlib.Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--capture', type=pathlib.Path, action='append', required=True)
p.add_argument('--output', type=pathlib.Path, required=True)
args = p.parse_args()
out = args.output.resolve()
if out.exists() or not out.is_relative_to(ROOT/'build'):
    raise ValueError('Use a fresh output directory inside build/')
out.mkdir(parents=True)
# Reuse the integrity-checked audit: stock operators, tables and integer tail.
sys.argv = [str(ROOT/'tools/reference/Measure-KokoroGeneratorTailError.py'),
    '--capture', str(ROOT/'build/stock-generator-capture-20261006'),
    '--average-capture', str(ROOT/'build/stock-generator-average-capture-20261006'),
    '--fixture', str(ROOT/'build/generator-tail-fixture-20261007'),
    '--layout', str(ROOT/'build/emit/KokoroGeneratorTailRun/runner-layout.json'),
    '--output', str(out/'baseline-audit')]
with contextlib.redirect_stdout(io.StringIO()):
    a = runpy.run_path(sys.argv[0])
scale, ws, weight, bias, qw = a['scale'], a['ws'], a['weight'], a['bias'], a['qw']

def load(path):
    path = path.resolve(); m = a['js'](path/'capture.json')
    def r(n):
        it = m['tensors'][n]; f = path/it['file']
        if a['sha'](f) != it['sha256']: raise ValueError('Capture tensor integrity: '+n)
        return np.fromfile(f,'<f4').reshape(it['shape'])
    if not np.array_equal(r('generator.conv_post.weight'), weight): raise ValueError('Stock parameters differ')
    return r('generator.conv_post.input.0')[0], r('output').reshape(-1), a['sha'](path/'capture.json')

def conv(x, w):
    with torch.no_grad():
        return torch.nn.functional.conv1d(torch.tensor(x,dtype=torch.float32)[None],
            torch.tensor(w,dtype=torch.float32),torch.tensor(bias,dtype=torch.float32),padding=3).numpy()[0]
def a8(x): return (np.clip(np.rint(x/scale+128),0,255)-128)*scale
def a16(x):
    # Two signed byte planes at the existing A8 scale: x = scale*(hi + lo/256).
    hi = np.clip(np.rint(x/scale+128),0,255)-128
    lo = np.clip(np.rint((x/scale-hi)*256),-128,127)
    return (hi+lo/256)*scale
def codes_pcm(z):
    a['integer_pcm'].__globals__['F'] = z.shape[1]
    return a['integer_pcm'](a['quantize_logits'](z)).astype(np.float64)/32768

result = dict(scope='Reference only; stock final LeakyReLU inputs; raw PCM SNR, no lag, gain or cropping.',
    toolSHA256=a['sha'](pathlib.Path(__file__)), captures={})
for cap in args.capture:
    x, pcm, manifest = load(cap); row = {}
    for iname, xf in (('float',x),('A8',a8(x)),('A16',a16(x))):
        for wname, w in (('stockW',weight),('W8',qw*ws)):
            z = conv(xf, w)
            row[f'{iname}/{wname}/floatTail'] = a['metrics'](a['tail'](z),pcm)['snrDb']
            row[f'{iname}/{wname}/codes'] = a['metrics'](codes_pcm(z),pcm)['snrDb']
    result['captures'][str(cap)] = dict(manifestSHA256=manifest, pcmSnrDb=row)
(out/'report.json').write_text(json.dumps(result,indent=2))
for cap, v in result['captures'].items():
    print(cap)
    for k, s in v['pcmSnrDb'].items(): print(f'  {k:24s} {s:8.2f}')
print('Report:', out/'report.json')
