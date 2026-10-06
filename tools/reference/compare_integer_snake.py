"""Single-operator integer Snake check; numerical reference is the stock capture."""
import argparse
import json
import math
import pathlib
import numpy as np
from compare_integer_adain import digest, metrics, unpack_native


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--fixture', required=True)
    args = parser.parse_args()
    root = pathlib.Path(args.fixture)
    spec = json.loads((root/'fixture.json').read_text(encoding='utf-8-sig'))
    for file, key in [('input.bin', 'inputSha256'), ('parameters.bin', 'parameterSha256')]:
        if digest(root/file) != spec[key]:
            raise ValueError('Fixture integrity mismatch')
    frames, tiles = spec['frames'], spec['tiles']
    channels = spec['channels']
    if channels not in (128, 256):
        raise ValueError('Unsupported channel count')
    x = unpack_native(np.fromfile(root/'input.bin', dtype='<i2'), tiles, frames, channels).astype(np.int64)
    rawparams = (root/'parameters.bin').read_bytes()
    params = np.frombuffer(rawparams[:channels*12], dtype='<i4').reshape(3, channels).astype(np.int64)
    table = np.frombuffer(rawparams[channels*12:], dtype='<u2').reshape(4, 32, 2).transpose(0, 2, 1).ravel().astype(np.int64)
    phase = ((x*params[0, :, None]) >> 8) & 65535
    index, fraction = phase >> 8, phase & 255
    value = table[index]+((table[(index+1)&255]-table[index])*fraction >> 8)
    correction = (value*params[1, :, None]) >> 15
    requant = ((x+correction)*params[2, :, None]+32768) >> 16
    clipped = int(np.count_nonzero((requant < -128) | (requant > 127)))
    expected = np.clip(requant+128, 0, 255).astype(np.uint8)
    actual = unpack_native(np.fromfile(root/'simulator-output.bin', dtype=np.uint8)[1::2], tiles, frames, channels)
    bad = int(np.count_nonzero(actual != expected))
    capture_root = pathlib.Path(spec['captureDirectory'])
    if digest(capture_root/'capture.json') != spec['captureSha256']:
        raise ValueError('Capture identity mismatch')
    capture = json.loads((capture_root/'capture.json').read_text(encoding='utf-8-sig'))
    def read(name):
        item = capture['tensors'][name]
        path = capture_root/item['file']
        if digest(path) != item['sha256']:
            raise ValueError('Stock tensor integrity mismatch')
        return np.fromfile(path, dtype='<f4')
    alpha = read(f"stage{spec['stage']}.alpha").astype(np.float64).reshape(channels, 1)
    stock = read(f"stage{spec['stage']}.snake").reshape(channels, frames)
    realx = x.astype(np.float64)/256
    exact_operator = realx+np.sin(alpha*realx)**2/alpha
    integer_prequant = (x+correction).astype(np.float64)/256
    result = {'frames': frames, 'channels': channels, 'values': int(actual.size), 'integerMismatches': bad,
              'clippedValues': clipped, 'outputScale': spec['outputScale'],
              'lookupVsExactSnakeSameInput': metrics(integer_prequant, exact_operator),
              'stockFp32Error': metrics((actual.astype(np.float64)-128)*spec['outputScale'], stock),
              'outputSha256': digest(root/'simulator-output.bin')}
    path = root/'comparison.json'
    if path.exists():
        raise ValueError('Receipt already exists')
    path.write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result))
    if bad:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
