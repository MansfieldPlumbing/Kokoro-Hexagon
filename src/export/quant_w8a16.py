# w8a16 QDQ (qai-hub TTS decoder precision) for any exported graph; calibration from raw .f32 inputs named in_<input>.f32.
import sys, pathlib, numpy as np, onnx, onnxruntime as ort
from onnxruntime.quantization import quantize, QuantType, CalibrationDataReader
from onnxruntime.quantization.execution_providers.qnn import get_qnn_qdq_config, qnn_preprocess_model

src = pathlib.Path(sys.argv[1]); data = pathlib.Path(sys.argv[2])
pre = src.with_name(src.stem + '_pre.onnx'); out = src.with_name(src.stem + '_w8a16.onnx')
m = onnx.load(str(src), load_external_data=False)
feed = {}
for i in m.graph.input:
    shape = [d.dim_value for d in i.type.tensor_type.shape.dim]
    feed[i.name] = np.fromfile(data / f'in_{i.name}.f32', dtype='<f4').reshape(shape)
print('inputs', {k: v.shape for k, v in feed.items()})

class Reader(CalibrationDataReader):
    def __init__(s): s.done = False
    def get_next(s):
        if s.done: return None
        s.done = True; return feed

modified = qnn_preprocess_model(str(src), str(pre))
base = pre if modified else src
import os
ops = [o for o in os.environ.get('QUANT_OPS', '').split(',') if o]
cfg = get_qnn_qdq_config(str(base), Reader(), activation_type=QuantType.QUInt16, weight_type=QuantType.QUInt8,
                         **({'op_types_to_quantize': ops} if ops else {}))
tag = os.environ.get('QUANT_TAG', '')
if tag: out = src.with_name(src.stem + '_w8a16' + tag + '.onnx')
print('quantizing op types:', ops or 'all')
quantize(str(base), str(out), cfg)
f = ort.InferenceSession(str(src), providers=['CPUExecutionProvider']).run(None, feed)[0]
q = ort.InferenceSession(str(out), providers=['CPUExecutionProvider']).run(None, feed)[0]
e = q - f
print(f'QDQ vs float: SNR={10*np.log10((f**2).sum()/(e**2).sum()):.2f} dB  max_abs={np.abs(e).max():.4f}  -> {out.name} {out.stat().st_size}')
