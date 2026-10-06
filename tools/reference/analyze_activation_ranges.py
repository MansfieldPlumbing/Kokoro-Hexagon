"""Reference-only sensitivity sweep through the pinned stock AdaIN class.
One capture diagnoses range sensitivity; it cannot select production calibration.
"""
import argparse
import importlib
import json
import pathlib
import sys
import types
import numpy as np
from compare_integer_adain import digest, metrics


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--capture', required=True)
    parser.add_argument('--stage', type=int, default=0, choices=range(6))
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    root = pathlib.Path(args.capture)
    out = pathlib.Path(args.output)
    if out.exists():
        raise ValueError('Choose a new diagnostic output file')
    capture = json.loads((root/'capture.json').read_text(encoding='utf-8-sig'))
    spec = json.loads((root/'capture-spec.json').read_text(encoding='utf-8-sig'))
    if capture['sourceCommit'] != 'dfb907a02bba8152ca444717ca5d78747ccb4bec' or capture['verifiedCheckpointTensors'] != 548:
        raise ValueError('Verified stock capture required')
    if spec['sourceCommit'] != capture['sourceCommit']:
        raise ValueError('Source revision mismatch')
    source = pathlib.Path(spec['sourceRoot'])
    for item in spec['sourceFiles']:
        if digest(source/item['path']) != item['sha256']:
            raise ValueError('Stock source digest mismatch')
    def read(name):
        item = capture['tensors'][name]
        file = root/item['file']
        if digest(file) != item['sha256']:
            raise ValueError('Captured tensor identity mismatch')
        return np.fromfile(file, dtype='<f4').reshape(item['shape'])
    package = types.ModuleType('kokoro')
    package.__path__ = [str(source/'kokoro')]
    sys.modules['kokoro'] = package
    import torch
    torch.set_num_threads(4)
    cls = importlib.import_module('kokoro.istftnet').AdaIN1d
    module = cls(128, 128).eval()
    prefix = f'stage{args.stage}.adain.'
    module.load_state_dict({name: torch.from_numpy(read(prefix+name)) for name in module.state_dict()}, strict=True)
    x = read(f'stage{args.stage}.input')
    stock = read(f'stage{args.stage}.adain')
    style = torch.from_numpy(read('style'))
    maximum = float(np.max(np.abs(x)))
    candidates = [('full-range', maximum)]
    for percentile in [99, 99.9, 99.99, 99.999]:
        candidates.append((f'absolute-percentile-{percentile}', float(np.percentile(np.abs(x), percentile))))
    # Bounded midpoint histogram search, not AIMET TF Enhanced reproduction.
    counts, edges = np.histogram(x, bins=8192, range=(-maximum, maximum))
    centers = (edges[:-1].astype(np.float64)+edges[1:].astype(np.float64))/2
    trials = np.geomspace(maximum/16, maximum, 128)
    errors = []
    for threshold in trials:
        scale = threshold/127
        restored = np.clip(np.rint(centers/scale), -127, 127)*scale
        errors.append(float(np.sum(counts*(restored-centers)**2)/x.size))
    chosen = int(np.argmin(errors))
    candidates.append(('histogram-mse-candidate', float(trials[chosen])))
    results = []
    with torch.inference_mode():
        unquantized = module(torch.from_numpy(x), style).numpy()
        identity = metrics(unquantized, stock)
        if identity['maximumAbsoluteError'] > 1e-5:
            raise ValueError('Original AdaIN replay does not match capture')
        for name, threshold in candidates:
            scale = threshold/127
            q = np.clip(np.rint(x/np.float32(scale)), -127, 127)
            restored = q*np.float32(scale)
            result = module(torch.from_numpy(restored), style).numpy()
            row = {'candidate': name, 'threshold': threshold, 'scale': scale,
                   'clippedValues': int(np.count_nonzero(np.abs(x) > threshold)),
                   'inputError': metrics(restored, x), 'stockAdaInError': metrics(result, stock)}
            results.append(row)
            print(json.dumps({'candidate': name, 'inputSnrDb': row['inputError']['snrDb'],
                              'adaInSnrDb': row['stockAdaInError']['snrDb'], 'clippedValues': row['clippedValues']}), flush=True)
    receipt = {'sourceCommit': capture['sourceCommit'], 'captureSha256': digest(root/'capture.json'),
               'toolSha256': digest(__file__), 'stage': args.stage, 'shape': list(x.shape),
               'referenceReplayError': identity, 'histogramBins': 8192, 'searchCandidates': 128,
               'results': results, 'scope': 'Single-capture original-class diagnostic; no DSP, holdout or production-calibration claim'}
    out.write_text(json.dumps(receipt, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()
