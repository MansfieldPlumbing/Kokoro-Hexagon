"""Select a baseline output encoding from an original stock generator capture.

Diagnostic full-range encoding, not a calibrated audio quality threshold.
"""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--capture', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    capture = json.loads((a.capture/'capture.json').read_text(encoding='utf-8-sig'))
    tensor = capture['tensors']['generator.leaky.2.input']
    file = (a.capture/tensor['file']).resolve()
    if not file.is_relative_to(a.capture.resolve()) or hashlib.sha256(file.read_bytes()).hexdigest().upper() != tensor['sha256'].upper():
        raise ValueError('Stock branch average integrity')
    values = np.fromfile(file, dtype='<f4')
    if tensor['shape'] != [1, 128, 7801] or not np.all(np.isfinite(values)):
        raise ValueError('Unexpected stock branch average shape')
    scale = float(np.max(np.abs(values)))/127
    if not np.isfinite(scale) or scale <= 0:
        raise ValueError('Invalid output encoding')
    if a.output.exists():
        raise ValueError('Use a new encoding output')
    a.output.write_text(json.dumps({'Frames':7801, 'Channels':128, 'Scale':scale,
        'StockTensor':str(file), 'StockSHA256':tensor['sha256'],
        'CaptureManifestSHA256':hashlib.sha256((a.capture/'capture.json').read_bytes()).hexdigest().upper(),
        'Method':'Full-range stock capture baseline; integration diagnostic'}, indent=2), encoding='utf-8')
    print(json.dumps({'branchAverageFrames':7801, 'outputScale':scale}))


if __name__ == '__main__':
    main()
