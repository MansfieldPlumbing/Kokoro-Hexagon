"""Compare native integer LeakyReLU output with the original captured tensor."""
import argparse
import json
from pathlib import Path
import numpy as np
from compare_integer_adain import digest, metrics, unpack_native


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--fixture',type=Path,required=True)
    p.add_argument('--capture',type=Path,required=True)
    a = p.parse_args()
    spec = json.loads((a.fixture/'fixture.json').read_text(encoding='utf-8-sig'))
    capture_file = a.capture/'capture.json'
    capture = json.loads(capture_file.read_text(encoding='utf-8-sig'))
    descriptor = capture['tensors']['generator.leaky.2.output']
    stock_file = (a.capture/descriptor['file']).resolve()
    if not stock_file.is_relative_to(a.capture.resolve()) or digest(stock_file) != descriptor['sha256']:
        raise ValueError('Stock LeakyReLU capture integrity')
    if descriptor['shape'] != [1,spec['Channels'],spec['Frames']]:
        raise ValueError('Stock LeakyReLU shape')
    raw = np.fromfile(a.fixture/'simulator-output.bin',dtype=np.uint8)
    if raw.size != spec['Tiles']*spec['Channels']*64:
        raise ValueError('Native output length')
    q = unpack_native(raw[1::2],spec['Tiles'],spec['Frames'],spec['Channels'])
    stock = np.fromfile(stock_file,dtype='<f4').reshape(spec['Channels'],spec['Frames'])
    actual = (q.astype(np.float64)-128)*spec['OutputScale']
    result = {'Frames':spec['Frames'],'Channels':spec['Channels'],
        'StockFp32Error':metrics(actual,stock),'OutputSHA256':digest(a.fixture/'simulator-output.bin'),
        'CaptureManifestSHA256':digest(capture_file),
        'Scope':'Connected three-branch average followed by integer LeakyReLU; audio quality unverified'}
    path = a.fixture/'stock-comparison.json'
    if path.exists():
        raise ValueError('Comparison receipt exists')
    path.write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
