"""Replay the pinned original AdaIN class on dequantized integer input."""
import argparse
import importlib
import json
import pathlib
import sys
import types
import numpy as np
from compare_integer_adain import digest, metrics, unpack_native


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--fixture', required=True)
    args = parser.parse_args()
    root = pathlib.Path(args.fixture)
    fixture = json.loads((root/'fixture.json').read_text(encoding='utf-8-sig'))
    capture_root = pathlib.Path(fixture['captureDirectory'])
    if digest(capture_root/'capture.json') != fixture['captureSha256']:
        raise ValueError('Capture identity mismatch')
    capture = json.loads((capture_root/'capture.json').read_text(encoding='utf-8-sig'))
    spec = json.loads((capture_root/'capture-spec.json').read_text(encoding='utf-8-sig'))
    if spec['sourceCommit'] != capture['sourceCommit']:
        raise ValueError('Stock source revision mismatch')
    source = pathlib.Path(spec['sourceRoot'])
    for item in spec['sourceFiles']:
        if digest(source/item['path']) != item['sha256']:
            raise ValueError('Stock source digest mismatch')
    package = types.ModuleType('kokoro')
    package.__path__ = [str(source/'kokoro')]
    sys.modules['kokoro'] = package
    import torch
    torch.set_num_threads(4)
    cls = importlib.import_module('kokoro.istftnet').AdaIN1d
    module = cls(128, 128).eval()
    def read(name):
        item = capture['tensors'][name]
        path = capture_root/item['file']
        if digest(path) != item['sha256']:
            raise ValueError('Captured parameter digest mismatch')
        return np.fromfile(path, dtype='<f4').reshape(item['shape'])
    prefix = f"stage{fixture['stage']}.adain."
    state = {name: torch.from_numpy(read(prefix+name)) for name in module.state_dict()}
    module.load_state_dict(state, strict=True)
    frames, tiles = fixture['frames'], fixture['tiles']
    if digest(root/'activations.bin') != fixture['activationSha256']:
        raise ValueError('Integer input identity mismatch')
    q = unpack_native(np.fromfile(root/'activations.bin', dtype=np.uint8)[1::2], tiles, frames)
    x = (q.astype(np.float32)-128)*np.float32(fixture['inputScale'])
    with torch.inference_mode():
        original = module(torch.from_numpy(x[None]), torch.from_numpy(read('style'))).numpy()[0]
    fixed = unpack_native(np.fromfile(root/'simulator-affine.bin', dtype='<i2'), tiles, frames)/256
    stock = read(f"stage{fixture['stage']}.adain")[0]
    result = {'sourceCommit': spec['sourceCommit'], 'epsilon': module.norm.eps,
              'originalAdaInOnQuantizedInputVsStockCapture': metrics(original, stock),
              'integerAdaInVsOriginalSameQuantizedInput': metrics(fixed, original)}
    path = root/'diagnosis.json'
    if path.exists():
        raise ValueError('Diagnosis receipt already exists')
    path.write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
