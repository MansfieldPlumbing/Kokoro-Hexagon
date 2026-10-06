"""Connected emitted-region receipts against captured stock boundaries.
Integer checks verify individual operator contracts, not a replacement Kokoro model.
"""
import argparse
import json
import math
import pathlib
import numpy as np
from compare_integer_adain import digest, metrics, unpack_native


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--fixture', required=True)
    parser.add_argument('--verify-inputs', action='store_true')
    args = parser.parse_args()
    root = pathlib.Path(args.fixture)
    spec = json.loads((root/'connected-fixture.json').read_text(encoding='utf-8-sig'))
    for item in spec['files']:
        path = root/item['path']
        if path.stat().st_size != item['bytes'] or digest(path) != item['sha256']:
            raise ValueError('Packed input integrity mismatch: '+item['path'])
    if args.verify_inputs:
        print(json.dumps({'verifiedFiles': len(spec['files']), 'frames': spec['frames'], 'stages': 6}))
        return
    frames, tiles = spec['frames'], spec['tiles']
    capture_root = pathlib.Path(spec['captureDirectory'])
    if digest(capture_root/'capture.json') != spec['captureSha256']:
        raise ValueError('Capture manifest identity mismatch')
    capture = json.loads((capture_root/'capture.json').read_text(encoding='utf-8-sig'))
    def stock(name):
        desc = capture['tensors'][name]
        path = capture_root/desc['file']
        if digest(path) != desc['sha256']:
            raise ValueError('Stock capture identity mismatch')
        return np.fromfile(path, dtype='<f4').reshape(desc['shape'])
    def native(path, q8=False):
        data = np.fromfile(path, dtype='<i2' if q8 else np.uint8)
        if not q8:
            data = data[1::2]
        return unpack_native(data, tiles, frames).astype(np.int64)
    records = []
    total_bad = 0
    for s, stage in enumerate(spec['stages']):
        folder = root/f'stage{s}'
        u = native(folder/'connected-input.bin')
        sums, squares = u.sum(axis=1), (u*u).sum(axis=1)
        raw = (folder/'adain-parameters.bin').read_bytes()
        coefficients = np.empty((2, 128), dtype=np.int64)
        for c in range(128):
            a, b = np.frombuffer(raw[16*c:16*c+8], dtype='<i4').astype(np.int64)
            eps = int.from_bytes(raw[16*c+8:16*c+16], 'little')
            denominator = math.isqrt(frames*int(squares[c])-int(sums[c])**2+eps)
            gain = int(np.sign(a))*(abs(int(a))*frames//denominator)
            mean = (int(sums[c]) << 16)//frames
            offset = int(b)-(gain*mean >> 16)
            if min(offset, gain*255+offset) < -2**31 or max(offset, gain*255+offset) >= 2**31:
                raise ValueError(f'Stage {s} affine intermediate exceeds int32')
            coefficients[:, c] = [gain, offset]
        actual_coef = np.fromfile(folder/'connected-coefficients.bin', dtype='<i4').reshape(2, 128)
        coefficient_bad = int(np.count_nonzero(coefficients != actual_coef))
        preclip = (coefficients[0, :, None]*u+coefficients[1, :, None]) >> 8
        adain_clipped = int(np.count_nonzero((preclip < -32768) | (preclip > 32767)))
        expected_adain = np.clip(preclip, -32768, 32767)
        adain = native(folder/'connected-adain.bin', True)
        adain_bad = int(np.count_nonzero(adain != expected_adain))
        raw = (folder/'snake-parameters.bin').read_bytes()
        p = np.frombuffer(raw[:1536], dtype='<i4').reshape(3, 128).astype(np.int64)
        table = np.frombuffer(raw[1536:], dtype='<u2').reshape(4, 32, 2).transpose(0, 2, 1).ravel().astype(np.int64)
        phase = ((adain*p[0, :, None]) >> 8) & 65535
        index, frac = phase >> 8, phase & 255
        sin2 = table[index]+((table[(index+1)&255]-table[index])*frac >> 8)
        correction = sin2*p[1, :, None] >> 15
        product = (adain+correction)*p[2, :, None]+32768
        if np.any(product < -2**31) or np.any(product >= 2**31):
            raise ValueError(f'Stage {s} Snake requantization exceeds int32')
        requant = product >> 16
        snake_clipped = int(np.count_nonzero((requant < -128) | (requant > 127)))
        expected_snake = np.clip(requant+128, 0, 255)
        snake = native(folder/'connected-snake.bin')
        snake_bad = int(np.count_nonzero(expected_snake != snake))
        conv = native(folder/'connected-conv.bin')
        result = {'stage': s, 'coefficientMismatches': coefficient_bad, 'affineMismatches': adain_bad,
                  'inputVsStock': metrics((u-128)*stage['inputScale'], stock(f'stage{s}.input').reshape(128, frames)),
                  'snakeMismatches': snake_bad, 'adainClippedValues': adain_clipped,
                  'snakeClippedValues': snake_clipped,
                  'adainVsStock': metrics(adain/256, stock(f'stage{s}.adain').reshape(128, frames)),
                  'snakeVsStock': metrics((snake-128)*stage['snakeScale'], stock(f'stage{s}.snake').reshape(128, frames)),
                  'convVsStock': metrics((conv-128)*stage['convScale'], stock(f'stage{s}.conv').reshape(128, frames)),
                  'convEndpointValues': int(np.count_nonzero((conv == 0) | (conv == 255)))}
        total_bad += coefficient_bad+adain_bad+snake_bad
        if s%2:
            skip_input = native(root/f'stage{s-1}'/'connected-input.bin')
            rp = np.fromfile(folder/'residual-parameters.bin', dtype='<i4').astype(np.int64)
            rq = (skip_input*rp[0]+conv*rp[1]+rp[2]) >> 16
            expected_residual = np.clip(rq, 0, 255)
            actual_residual = native(folder/'connected-residual.bin')
            residual_bad = int(np.count_nonzero(expected_residual != actual_residual))
            result['residualMismatches'] = residual_bad
            result['residualClippedValues'] = int(np.count_nonzero((rq < 0) | (rq > 255)))
            next_name = f'stage{s+1}.input' if s<5 else 'output'
            result['residualVsStock'] = metrics((actual_residual-128)*stage['residualScale'], stock(next_name).reshape(128, frames))
            total_bad += residual_bad
        records.append(result)
        print(json.dumps({'stage': s, 'convSnrDb': result['convVsStock']['snrDb'],
                          'residualSnrDb': result.get('residualVsStock', {}).get('snrDb')}), flush=True)
    final_file = root/'stage5'/'connected-residual.bin'
    result = {'frames': frames, 'channels': 128, 'convolutions': 6, 'residuals': 3,
              'integerContractMismatches': total_bad, 'stages': records,
              'finalStockFp32Error': records[-1]['residualVsStock'], 'outputSha256': digest(final_file),
              'captureSha256': spec['captureSha256'], 'fixtureSha256': digest(root/'connected-fixture.json'),
              'initialInputOutsideRangeValues': int(np.count_nonzero(np.abs(stock('stage0.input')) > 127*spec['initialInputScale'])),
              'scope': 'V73 simulator connected region; reference staging; no device or audio quality gate'}
    path = root/'connected-comparison.json'
    if path.exists():
        raise ValueError('Receipt already exists')
    path.write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps({'integerContractMismatches': total_bad, 'finalStockFp32Error': result['finalStockFp32Error'],
                      'outputSha256': result['outputSha256']}))
    if total_bad:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
