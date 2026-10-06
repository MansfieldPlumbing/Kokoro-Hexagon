"""Compare emitted native-layout mean directly with a captured stock tensor."""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--fixture', type=Path, required=True)
    p.add_argument('--encoding', type=Path, required=True)
    a = p.parse_args()
    spec = json.loads((a.fixture/'fixture.json').read_text(encoding='utf-8-sig'))
    encoding = json.loads(a.encoding.read_text(encoding='utf-8-sig'))
    file = Path(encoding['StockTensor'])
    if hashlib.sha256(file.read_bytes()).hexdigest().upper() != encoding['StockSHA256'].upper():
        raise ValueError('Stock average hash mismatch')
    native = a.fixture/'simulator-output.bin'
    raw = np.fromfile(native, dtype=np.uint8)
    if raw.size != spec['Tiles']*8192 or spec['Frames'] != encoding['Frames'] or spec['OutputScale'] != encoding['Scale']:
        raise ValueError('Average fixture contract mismatch')
    q = raw.reshape(spec['Tiles'],4,16,32,2,2)[...,1].transpose(0,2,4,1,3).reshape(-1,128).T[:,:spec['Frames']]
    stock = np.fromfile(file,dtype='<f4').reshape(128,spec['Frames']).astype(np.float64)
    actual = (q.astype(np.float64)-128)*spec['OutputScale']
    error = actual-stock
    result = {'Frames':spec['Frames'], 'Channels':128,
        'StockSnrDb':float(10*np.log10(np.sum(stock*stock)/np.sum(error*error))),
        'Rmse':float(np.sqrt(np.mean(error*error))), 'MaxAbsoluteError':float(np.max(np.abs(error))),
        'EndpointValues':int(np.count_nonzero((q==0)|(q==255))),
        'OutputSHA256':hashlib.sha256(native.read_bytes()).hexdigest().upper(),
        'StockSHA256':encoding['StockSHA256'], 'EncodingSHA256':hashlib.sha256(a.encoding.read_bytes()).hexdigest().upper(),
        'Scope':'Connected three-branch mean; stock capture baseline; audio quality unverified'}
    path = a.fixture/'stock-comparison.json'
    if path.exists():
        raise ValueError('Receipt already exists')
    path.write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
