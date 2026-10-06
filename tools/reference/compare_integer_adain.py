"""Check one emitted integer AdaIN operator against its integer contract and stock capture."""
import argparse
import hashlib
import json
import math
import pathlib
import numpy as np


def digest(path):
    with open(path, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest().upper()


def unpack_native(data, tiles, frames, channels=128):
    return data.reshape(tiles, channels//32, 16, 32, 2).transpose(0, 2, 4, 1, 3).reshape(tiles*32, channels)[:frames].T


def metrics(actual, reference):
    error = actual.astype(np.float64)-reference.astype(np.float64)
    mse = float(np.mean(error*error))
    signal = float(np.mean(reference.astype(np.float64)**2))
    return {'rmse': math.sqrt(mse), 'maximumAbsoluteError': float(np.max(np.abs(error))),
            'snrDb': 10*math.log10(signal/mse) if mse else None}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--fixture', required=True)
    parser.add_argument('--prepare', action='store_true')
    args = parser.parse_args()
    root = pathlib.Path(args.fixture)
    spec = json.loads((root/'fixture.json').read_text(encoding='utf-8-sig'))
    for file, key in [('activations.bin', 'activationSha256'), ('parameters.bin', 'parameterSha256'),
                      ('moments.bin', 'expectedSha256')]:
        if digest(root/file) != spec[key]:
            raise ValueError('Fixture integrity mismatch: '+file)
    channels = spec['channels']
    if channels not in (128, 256):
        raise ValueError('Unsupported channel count')
    import torch
    if torch.nn.InstanceNorm1d(channels, affine=True).eps != spec['epsilon']:
        raise ValueError('Stock InstanceNorm epsilon differs from the packed experiment')
    frames, tiles = spec['frames'], spec['tiles']
    raw = np.fromfile(root/'activations.bin', dtype=np.uint8)[1::2]
    u = unpack_native(raw, tiles, frames, channels).astype(np.int64)
    moments = np.fromfile(root/'moments.bin', dtype='<u4').reshape(channels//32, 2, 32)
    sums, squares = moments[:, 0].ravel(), moments[:, 1].ravel()
    if not np.array_equal(u.sum(axis=1), sums) or not np.array_equal((u*u).sum(axis=1), squares):
        raise ValueError('Moment file differs from complete-group input')
    coefficients = np.empty((2, channels), dtype='<i4')
    for c in range(channels):
        param = (root/'parameters.bin').read_bytes()[16*c:16*(c+1)]
        a, b = np.frombuffer(param[:8], dtype='<i4').astype(np.int64)
        eps = int.from_bytes(param[8:], 'little')
        variance_numerator = frames*int(squares[c])-int(sums[c])**2+eps
        denominator = math.isqrt(variance_numerator)
        gain = int(np.sign(a))*(abs(int(a))*frames//denominator)
        mean = (int(sums[c]) << 16)//frames
        offset = int(b)-(gain*mean >> 16)
        if not (-2**31 < gain < 2**31 and -2**31 <= offset < 2**31):
            raise ValueError('Integer coefficient overflow')
        endpoints = [offset, gain*255+offset]
        if min(endpoints) < -2**31 or max(endpoints) >= 2**31:
            raise ValueError('HVX affine intermediate overflow')
        coefficients[:, c] = [gain, offset]
    expected_q8 = (coefficients[0, :, None].astype(np.int64)*u+coefficients[1, :, None]) >> 8
    clipping = int(np.count_nonzero((expected_q8 < -32768) | (expected_q8 > 32767)))
    expected_q8 = np.clip(expected_q8, -32768, 32767).astype('<i2')
    if args.prepare:
        target = root/'expected-coefficients.bin'
        if target.exists():
            raise ValueError('Expected coefficients already exist')
        coefficients.tofile(target)
        print(json.dumps({'frames': frames, 'coefficientValues': 2*channels, 'clippedValues': clipping,
                          'epsilon': spec['epsilon'], 'expectedSha256': digest(target)}))
        return
    actual_coef = np.fromfile(root/'simulator-coefficients.bin', dtype='<i4').reshape(2, channels)
    actual_q8 = unpack_native(np.fromfile(root/'simulator-affine.bin', dtype='<i2'), tiles, frames, channels)
    coefficient_bad = int(np.count_nonzero(actual_coef != coefficients))
    affine_bad = int(np.count_nonzero(actual_q8 != expected_q8))
    capture_root = pathlib.Path(spec['captureDirectory'])
    capture_file = capture_root/'capture.json'
    if digest(capture_file) != spec['captureSha256']:
        raise ValueError('Capture manifest integrity mismatch')
    capture = json.loads(capture_file.read_text(encoding='utf-8-sig'))
    descriptor = capture['tensors'][f"stage{spec['stage']}.adain"]
    stock_file = capture_root/descriptor['file']
    if digest(stock_file) != descriptor['sha256']:
        raise ValueError('Stock AdaIN tensor integrity mismatch')
    stock = np.fromfile(stock_file, dtype='<f4').reshape(channels, frames)
    result = {'frames': frames, 'channels': channels, 'values': int(actual_q8.size),
              'coefficientMismatches': coefficient_bad, 'affineMismatches': affine_bad,
              'clippedValues': clipping, 'outputFractionBits': 8,
              'stockFp32Error': metrics(actual_q8.astype(np.float64)/256, stock),
              'coefficientSha256': digest(root/'simulator-coefficients.bin'),
              'outputSha256': digest(root/'simulator-affine.bin')}
    target = root/'comparison.json'
    if target.exists():
        raise ValueError('Comparison receipt already exists')
    target.write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result))
    if coefficient_bad or affine_bad:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
