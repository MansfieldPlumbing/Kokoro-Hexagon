# Rewrite ONNX Pow(x, 2) -> Mul(x, x). QNN HTP V73 (QAIRT 2.46) computes Pow(x, 2) incorrectly (verified on SM8550).
import sys, numpy as np, onnx
from onnx import numpy_helper, helper
src, dst = sys.argv[1], sys.argv[2]
m = onnx.load(src, load_external_data=True)
g = m.graph
consts = {i.name: numpy_helper.to_array(i) for i in g.initializer}
for n in g.node:
    if n.op_type == 'Constant':
        for a in n.attribute:
            if a.name == 'value': consts[n.output[0]] = numpy_helper.to_array(a.t)
count = 0; other = []
for idx, n in enumerate(list(g.node)):
    if n.op_type != 'Pow': continue
    e = consts.get(n.input[1])
    if e is not None and e.size == 1 and float(e.reshape(-1)[0]) == 2.0:
        g.node.remove(n); g.node.insert(idx, helper.make_node('Mul', [n.input[0], n.input[0]], list(n.output), name=n.name + '_as_mul')); count += 1
    else:
        other.append(n.name)
onnx.checker.check_model(m, full_check=False) if m.ByteSize() < 2**31 - 1 else None
onnx.save(m, dst)
print(f'Pow(x,2)->Mul: {count}  other Pow left: {len(other)} {other[:5]}')
