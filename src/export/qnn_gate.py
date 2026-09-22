# QNN-friendliness gate: static shapes, op allowlist (device-proven on S23 HTP V73 / QAIRT 2.46), alignment report.
import sys, onnx
from collections import Counter

PROVEN = {  # each proven correct on-device by per-layer probes against PyTorch
    'Conv', 'ConvTranspose', 'Mul', 'Add', 'Sub', 'Div', 'Reciprocal', 'Sqrt', 'Abs', 'Sin', 'Exp', 'LeakyRelu',
    'ReduceMean', 'ReduceMax', 'ReduceSum', 'Slice', 'Reshape', 'Concat', 'Pad', 'Transpose', 'Gemm', 'Unsqueeze', 'Expand',
    'InstanceNormalization', 'Cos',   # device-proven 2026-09-22 (native-norm generator, in-graph iSTFT)
}
BANNED = {'Pow': 'wrong on HTP V73 (use Mul)', 'Resize': 'use expand/reshape', 'RandomNormal': 'noise must be an input',
          'RandomNormalLike': 'noise must be an input', 'RandomUniformLike': 'noise must be an input', 'Atan': 'NaN-prone decomposition'}

def gate(path):
    m = onnx.load(path, load_external_data=False); g = m.graph
    ops = Counter(n.op_type for n in g.node)
    problems = []
    for vi in list(g.input) + list(g.output):
        dims = [d.dim_value if d.HasField('dim_value') else None for d in vi.type.tensor_type.shape.dim]
        if any(d in (None, 0) for d in dims): problems.append(f'dynamic shape: {vi.name} {dims}')
        if dims and dims[-1] and dims[-1] > 64 and dims[-1] % 8: problems.append(f'unaligned length (not %8): {vi.name} {dims}')
    init = {i.name for i in g.initializer}
    for n in g.node:
        if n.op_type == 'ConvTranspose':
            grp = next((a.i for a in n.attribute if a.name == 'group'), 1)
            if grp > 1: problems.append(f'depthwise ConvTranspose (group={grp}): {n.name}')
    for op, c in ops.items():
        if op in BANNED: problems.append(f'banned {op} x{c}: {BANNED[op]}')
        elif op not in PROVEN and op != 'Constant': problems.append(f'unproven op {op} x{c}')
    name = path.replace('\\', '/').split('/')[-1]
    print(f"{'PASS' if not problems else 'FAIL'}  {name}  nodes={sum(ops.values())} types={len(ops)}")
    for p in problems[:12]: print('   -', p)
    return not problems

ok = all([gate(p) for p in sys.argv[1:]])
sys.exit(0 if ok else 1)
