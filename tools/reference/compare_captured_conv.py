"""Reference-only PyTorch convolution comparison for a PowerShell-packed tile."""
import argparse
import hashlib
import json
import pathlib
import numpy as np
import torch
import torch.nn.functional as functional


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--fixture',required=True)
    parser.add_argument('--output',default='simulator-output.bin')
    parser.add_argument('--write-expected',action='store_true')
    args=parser.parse_args()
    root=pathlib.Path(args.fixture)
    spec=json.loads((root/'fixture.json').read_text(encoding='utf-8-sig'))
    capture_root=pathlib.Path(spec['capture'])
    manifest_path=capture_root/'capture.json'
    if hashlib.sha256(manifest_path.read_bytes()).hexdigest().upper()!=spec['captureSha256']:
        raise ValueError('Capture manifest integrity mismatch')
    capture=json.loads(manifest_path.read_text(encoding='utf-8'))
    stage=spec['stage']; count=spec['frames']; channels=spec['channels']
    descriptor=capture['tensors'][f'stage{stage}.conv']
    reference_path=capture_root/descriptor['file']
    if hashlib.sha256(reference_path.read_bytes()).hexdigest().upper()!=descriptor['sha256']:
        raise ValueError('Stock output integrity mismatch')
    stock=np.fromfile(reference_path,dtype='<f4').reshape(descriptor['shape'])[0,:,spec['startFrame']:spec['startFrame']+count]
    output_path=root/args.output
    data=output_path.read_bytes()
    if len(data)!=spec['tiles']*4*2048:
        raise ValueError('Unexpected HMX output size')
    offsets=np.array([((t//32)*4+c//32)*2048+2*(64*((t%32)//2)+2*(c%32)+(t%2))+1 for c in range(channels) for t in range(count)])
    q=np.frombuffer(data,dtype=np.uint8)[offsets].reshape(channels,count)
    actual=(q.astype(np.float64)-128)*spec['outputScale']
    x=np.fromfile(root/'input.s8',dtype=np.int8).reshape(1,channels,count+64)
    weight=np.fromfile(root/'weight.s8',dtype=np.int8).reshape(channels,channels,3)
    # Independent integer-accumulation reference uses stock PyTorch's Conv1d.
    # Double arithmetic exactly represents these bounded int8 sums.
    with torch.inference_mode():
        acc=functional.conv1d(torch.from_numpy(x.astype(np.float64)),torch.from_numpy(weight.astype(np.float64)),padding=spec['dilation'],dilation=spec['dilation']).numpy()[0,:,32:32+count]
    integer_bias=np.array(spec['biasQuantized'])[:,None]
    dequantized=(acc+integer_bias)*spec['inputScale']*np.array(spec['weightScales'])[:,None]
    ideal_q=np.clip(np.rint(dequantized/spec['outputScale'])+128,0,255).astype(np.uint8)
    def error(candidate):
        diff=candidate-stock
        rms=float(np.sqrt(np.mean(diff*diff)))
        signal=float(np.sqrt(np.mean(stock.astype(np.float64)**2)))
        return {'rmse':rms,'maxAbs':float(np.max(np.abs(diff))),
                'snrDb':float(20*np.log10(signal/rms)) if rms else None}
    result={'stage':stage,'frames':count,'outputSha256':hashlib.sha256(data).hexdigest().upper(),
            'stockCaptureSha256':spec['captureSha256'],
            'hmxVsStock':error(actual),'quantizedConvVsStock':error(dequantized),
            'requantVsIdealMaxLsb':int(np.max(np.abs(q.astype(np.int16)-ideal_q.astype(np.int16)))),
            'requantVsIdealMismatchCount':int(np.count_nonzero(q!=ideal_q)),
            'saturatedValues':int(np.count_nonzero((q==0)|(q==255))),'values':count*channels}
    (root/(args.output+'.comparison.json')).write_text(json.dumps(result,indent=2),encoding='utf-8')
    if args.write_expected:
        # This expectation is specifically simulator/device agreement. The
        # numerical quality comparison above remains against stock PyTorch.
        (root/'expected-before-simulator.bin').write_bytes((root/'expected.bin').read_bytes())
        (root/'expected.bin').write_bytes(data)
    print(json.dumps(result))


if __name__=='__main__':
    main()
