"""Reference-only pooled activation calibration; no model implementation.
Range selection follows AIMET's documented min/max and MSE principles:
qualcomm/aimet 6f1416e0bc3868a1dc43ce48072a4d5fe778f042,
Docs/tutorials/quantsim.rst. Histogram midpoint search is an approximation.
"""
import argparse
import json
import pathlib
import numpy as np
from compare_integer_adain import digest

PIN = 'dfb907a02bba8152ca444717ca5d78747ccb4bec'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--capture', action='append', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    out = pathlib.Path(args.output)
    if out.exists():
        raise ValueError('Choose a new encoding directory')
    roots = [pathlib.Path(p).resolve() for p in args.capture]
    if len(set(roots)) != len(roots) or len(roots) < 2:
        raise ValueError('At least two distinct calibration groups required')
    captures = []
    identities = []
    for root in roots:
        path = root/'capture.json'
        cap = json.loads(path.read_text(encoding='utf-8-sig'))
        if cap['sourceCommit'] != PIN or cap['verifiedCheckpointTensors'] != 548:
            raise ValueError('Verified pinned capture required')
        captures.append(cap)
        identities.append({'path': str(path), 'sha256': digest(path)})
    names = ['stage0.input'] + [f'stage{s}.{kind}' for s in range(6)
                               for kind in ['snake', 'conv']] + ['stage2.input', 'stage4.input', 'output']
    methods = ['full-range', 'percentile-99.9', 'percentile-99.99', 'histogram-mse']
    scales = {method: {} for method in methods}
    diagnostics = {}
    for name in names:
        arrays = []
        for root, cap in zip(roots, captures):
            item = cap['tensors'][name]
            if pathlib.Path(item['file']).name != item['file']:
                raise ValueError('Invalid tensor path')
            path = root/item['file']
            if path.stat().st_size != item['bytes'] or digest(path) != item['sha256']:
                raise ValueError('Tensor digest mismatch')
            data = np.fromfile(path, dtype='<f4')
            if data.size != np.prod(item['shape']) or not np.isfinite(data).all():
                raise ValueError('Tensor shape or values invalid')
            arrays.append(data)
        values = np.concatenate(arrays).astype(np.float64)
        maximum = float(np.max(np.abs(values)))
        if maximum <= 0:
            raise ValueError('Zero range requires explicit handling')
        counts, edges = np.histogram(values, bins=8192, range=(-maximum, maximum))
        centers = (edges[:-1]+edges[1:])/2
        trials = np.geomspace(maximum/16, maximum, 128)
        errors = [float(np.sum(counts*(np.clip(np.rint(centers/(t/127)), -127, 127)*(t/127)-centers)**2))
                  for t in trials]
        thresholds = [maximum, float(np.percentile(np.abs(values), 99.9)),
                      float(np.percentile(np.abs(values), 99.99)), float(trials[np.argmin(errors)])]
        diagnostics[name] = {'values': int(values.size), 'maximum': maximum,
                             'thresholds': dict(zip(methods, thresholds))}
        for method, threshold in zip(methods, thresholds):
            scales[method][name] = threshold/127
    out.mkdir(parents=True)
    for method in methods:
        document = {'schema': 1, 'sourceCommit': PIN, 'method': method, 'zeroPoint': 128,
                    'signedRange': [-127, 127], 'scales': scales[method],
                    'calibrationCaptures': identities, 'toolSha256': digest(__file__),
                    'scope': 'Two-group pilot; frozen before connected holdout evaluation'}
        (out/(method+'.json')).write_text(json.dumps(document, indent=2), encoding='utf-8')
    (out/'diagnostics.json').write_text(json.dumps(diagnostics, indent=2), encoding='utf-8')
    print(json.dumps({'calibrationGroups': len(roots), 'boundaries': len(names), 'candidates': methods}))


if __name__ == '__main__':
    main()
