"""Windows reference audit. Original stock modules; no product inference path."""
import hashlib, importlib, json, pathlib, sys, types
import numpy as np
import torch

ROOT = pathlib.Path(__file__).resolve().parents[2]
import argparse
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--capture', type=pathlib.Path, required=True)
parser.add_argument('--average-capture', type=pathlib.Path, required=True)
parser.add_argument('--fixture', type=pathlib.Path, required=True)
parser.add_argument('--layout', type=pathlib.Path, required=True)
parser.add_argument('--output', type=pathlib.Path, required=True)
parser.add_argument('--stock-input-output', type=pathlib.Path)
parser.add_argument('--phone-output', type=pathlib.Path, action='append', default=[])
args = parser.parse_args()
CAP, FIX, OUT = args.capture.resolve(), args.fixture.resolve(), args.output.resolve()
if not OUT.is_relative_to(ROOT/'build') or OUT.exists():
    raise ValueError('Use a fresh output directory inside this repository build/')
OUT.mkdir(parents=True)
def js(p): return json.loads(p.read_text(encoding='utf-8-sig'))
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest().upper()
spec, capture, fixture = js(CAP/'capture-spec.json'), js(CAP/'capture.json'), js(FIX/'fixture.json')
if spec['sourceCommit'] != js(ROOT/'lib/manifest.json')['kokoroSource']['commit']:
    raise ValueError('Stock source commit differs from repository pin')
for item in spec['sourceFiles']:
    if sha(pathlib.Path(spec['sourceRoot'])/item['path']) != item['sha256']: raise ValueError('Source integrity')
if sha(CAP/'capture.json') != fixture['CaptureManifestSHA256']: raise ValueError('Capture integrity')
for item in fixture['Files']:
    if sha(FIX/item['Name']) != item['SHA256']: raise ValueError('Fixture integrity')
package = types.ModuleType('kokoro'); package.__path__ = [str(pathlib.Path(spec['sourceRoot'])/'kokoro')]
sys.modules['kokoro'] = package
TorchSTFT = importlib.import_module('kokoro.istftnet').TorchSTFT
torch.set_num_threads(4)
def read(name):
    item = capture['tensors'][name]; path = CAP/item['file']
    if sha(path) != item['sha256']: raise ValueError('Tensor integrity: '+name)
    return np.fromfile(path, '<f4').reshape(item['shape'])
def metrics(actual, reference):
    a, r = np.asarray(actual, dtype=np.float64), np.asarray(reference, dtype=np.float64)
    if a.shape != r.shape: raise ValueError('Shape mismatch')
    e = a-r; power = np.sum(r*r); noise = np.sum(e*e)
    return dict(snrDb=float(10*np.log10(max(power,1e-300)/max(noise,1e-300))),
                maxAbsoluteError=float(np.max(np.abs(e))), meanAbsoluteError=float(np.mean(np.abs(e))),
                signedMeanError=float(np.mean(e)), rmse=float(np.sqrt(np.mean(e*e))))
F = fixture['Frames']; tiles = fixture['Tiles']; scale = fixture['InputScale']
raw = np.fromfile(FIX/'activations.bin',np.uint8)
q = raw.reshape(tiles,4,16,32,2,2)[...,1].transpose(0,2,4,1,3).reshape(-1,128).T[:,:F].astype(np.int64)
x = (q-128)*scale
AVG = args.average_capture.resolve()
avg_manifest = js(AVG/'capture.json')
def read_avg(name):
    item=avg_manifest['tensors'][name]; path=AVG/item['file']
    if sha(path)!=item['sha256']: raise ValueError('Average capture integrity')
    return np.fromfile(path,'<f4').reshape(item['shape'])
stock_x = read_avg('generator.leaky.2.input').reshape(128,F)
stock_leaky = read_avg('generator.leaky.2.output').reshape(128,F)
if not np.array_equal(stock_leaky,read('generator.conv_post.input.0').reshape(128,F)):
    raise ValueError('Historical and full capture tail inputs differ')
stock_post = read('generator.conv_post.output').reshape(22,F)
stock_audio = read('output').reshape(-1)
weight, bias = read('generator.conv_post.weight'), read('generator.conv_post.bias')
conv = torch.nn.Conv1d(128,22,7,padding=3).eval()
with torch.no_grad():
    conv.weight.copy_(torch.from_numpy(weight)); conv.bias.copy_(torch.from_numpy(bias))
stft = TorchSTFT(20,5,20)
def post(a, w=None):
    if w is None:
        with torch.no_grad(): return conv(torch.tensor(a,dtype=torch.float32)[None]).numpy()[0]
    # Original PyTorch Conv1d operator, effective quantized weights only for isolation.
    with torch.no_grad():
        return torch.nn.functional.conv1d(torch.tensor(a,dtype=torch.float32)[None],
            torch.tensor(w,dtype=torch.float32),torch.from_numpy(bias),padding=3).numpy()[0]
def inverse(mag, phase):
    with torch.no_grad(): return stft.inverse(torch.tensor(mag,dtype=torch.float32)[None],
                                             torch.tensor(phase,dtype=torch.float32)[None]).numpy().reshape(-1)
def tail(z): return inverse(np.exp(z[:11]),np.sin(z[11:]))
def pcm_metrics(a):
    m = metrics(a,stock_audio); best = (-2,None)
    for lag in range(-240,241):
        aa = a[max(0,lag):min(len(a),len(a)+lag)]
        rr = stock_audio[max(0,-lag):min(len(a),len(a)-lag)]
        corr = float(np.corrcoef(aa,rr)[0,1])
        if corr>best[0]: best=(corr,lag)
    lag=best[1]; aa=a[max(0,lag):min(len(a),len(a)+lag)]; rr=stock_audio[max(0,-lag):min(len(a),len(a)-lag)]
    m.update(bestLagSamples=lag,bestLagCorrelation=best[0],bestLagSnrDb=metrics(aa,rr)['snrDb'])
    return m
leaky_float = torch.nn.functional.leaky_relu(torch.tensor(x,dtype=torch.float32)).numpy()
ql = np.clip((fixture['LeakyPositive']*np.maximum(q,128)+fixture['LeakyNegative']*np.minimum(q,128)+fixture['LeakyBias'])>>16,0,255)
leaky_integer = (ql-128)*scale
z1 = post(leaky_float); zleaky = post(leaky_integer)
ws = np.asarray(fixture['WeightScale'])[:,None,None]
qw = np.rint(weight/ws).clip(-127,127)
zweights = post(leaky_integer,qw*ws)
layout = js(args.layout)
buffer = (FIX/'simulator-output.bin').read_bytes()
if len(buffer)!=layout['OutputBytes'] or int.from_bytes(buffer[44:48],'little')!=1:
    raise ValueError('Tail output length or completion differs')
offset = int(np.frombuffer(buffer,dtype='<i4',count=1,offset=40)[0])
if offset<layout['CodesFloor'] or offset+2*tiles*8192>len(buffer):
    raise ValueError('Tail code offsets outside output buffer')
codes = {}; zs = {}
for i,name in enumerate(('Coarse','Fine')):
    b=np.frombuffer(buffer,dtype=np.uint8,count=tiles*8192,offset=offset+i*tiles*8192)
    codes[name]=b.reshape(tiles,4,16,32,2,2)[...,1].transpose(0,2,4,1,3).reshape(-1,128).T[:22,:F].astype(np.int64)
    zs[name]=(codes[name]-np.asarray(fixture['OutputZero'][name])[:,None])*np.asarray(fixture['OutputScale'][name])[:,None]
fine_valid=(codes['Fine']>0)&(codes['Fine']<255)
z2=np.where(fine_valid,zs['Fine'],zs['Coarse'])
params=np.fromfile(FIX/'tables.bin','<i4'); p=fixture['ParameterLayout']
tables={}
for name in ('Coarse','Fine'):
    start=p['Pass'+name]//4; tables[name]=params[start:start+3*11*256].reshape(3,11,256).astype(np.int64)
def integer_spectral(codes):
    valid=(codes['Fine']>0)&(codes['Fine']<255)
    values=[]
    for which in range(3):
        ch=np.arange(11)[:,None]; cc=codes['Coarse'][0:11 if which==0 else 22] if which==0 else codes['Coarse'][11:]
        ff=codes['Fine'][:11] if which==0 else codes['Fine'][11:]
        v=valid[:11] if which==0 else valid[11:]
        values.append(np.where(v,tables['Fine'][which,ch,ff],tables['Coarse'][which,ch,cc]))
    e,c,s=values
    re=((e*c+16384)>>15)/65536.; im=((e*s+16384)>>15)/65536.
    return e/65536.,c/32768.,s/32768.,re,im
em,cosphase,sinphase,re,im=integer_spectral(codes)
audio1=tail(z1); audio2=tail(z2)
audio3=inverse(np.hypot(re,im),np.arctan2(im,re))
audio4=np.frombuffer(buffer,'<i2',count=fixture['Samples'],offset=layout['PcmOffset']).astype(np.float64)/32768
stock_mag=np.exp(stock_post[:11]); stock_phase=np.sin(stock_post[11:])
ledger={'generator_mean':metrics(x,stock_x),'leaky_float_same_frozen_input':metrics(leaky_float,stock_leaky),
        'leaky_integer':metrics(leaky_integer,stock_leaky),'stock_tail_reproduction':pcm_metrics(tail(stock_post)),
        'conv_stock_weights_frozen_input':metrics(z1,stock_post), 'conv_after_integer_leaky':metrics(zleaky,stock_post),
        'conv_quantized_weights_before_output_codes':metrics(zweights,stock_post),
        'conv_actual_hmx_codes':metrics(z2,stock_post),
        'magnitude_logits':metrics(z2[:11],stock_post[:11]),'phase_logits':metrics(z2[11:],stock_post[11:]),
        'exp_magnitude_float':metrics(np.exp(z2[:11]),stock_mag),'sin_phase_float':metrics(np.sin(z2[11:]),stock_phase),
        'exp_magnitude_integer':metrics(em,stock_mag),'cos_phase_integer':metrics(cosphase,np.cos(stock_phase)),
        'sin_phase_integer':metrics(sinphase,np.sin(stock_phase)),
        'ladder_1_stock_tail_frozen':pcm_metrics(audio1),'integer_leaky_stock_rest':pcm_metrics(tail(zleaky)),
        'int8_weights_stock_rest':pcm_metrics(tail(zweights)),
        'ladder_2_hmx_codes_stock_math':pcm_metrics(audio2),'ladder_3_integer_spectral_stock_istft':pcm_metrics(audio3),
        'ladder_4_complete_integer':pcm_metrics(audio4),
        'integer_istft_incremental_error':metrics(audio4,audio3)}
per_channel=[]
for ch in range(22):
    m=metrics(z2[ch],stock_post[ch]); m.update(channel=ch,
        coarseEndpointCount=int(np.count_nonzero((codes['Coarse'][ch]==0)|(codes['Coarse'][ch]==255))),
        fineEndpointCount=int(np.count_nonzero(~fine_valid[ch])),
        hmx_vs_ideal_quantized_conv=metrics(z2[ch],zweights[ch]))
    per_channel.append(m)
halo=[]
for period in (32,layout['BatchTiles']*32):
    f=np.arange(F); mask=(f%period<3)|(f%period>=period-3)
    err=z2-zweights
    halo.append(dict(periodFrames=period,boundaryRmse=float(np.sqrt(np.mean(err[:,mask]**2))),
                     interiorRmse=float(np.sqrt(np.mean(err[:,~mask]**2)))))
result=dict(sourceCommit=spec['sourceCommit'],torchVersion=torch.__version__,frozenInputSHA256=sha(FIX/'activations.bin'),
            simulatorOutputSHA256=sha(FIX/'simulator-output.bin'),
            pcmSHA256=hashlib.sha256(buffer[layout['PcmOffset']:layout['PcmOffset']+2*fixture['Samples']]).hexdigest().upper(),
            ledger=ledger,convPostChannels=per_channel,haloDiagnostics=halo,
            alignment='Raw SNR: no alignment, scaling or cropping. Lag search: +/-240 samples, Pearson correlation, overlap only.',
            scope='Reference-only boundary attribution on one frozen capture; no phone rerun or perceptual acceptance.')

# Same integer formulation as Test-KokoroGeneratorTailOutput.ps1, vectorized
# only for Windows reference auditing. Must reproduce emitted PCM exactly.
def quantize_logits(z):
    return {name:np.clip(np.rint(z/np.asarray(fixture['OutputScale'][name])[:,None]+
        np.asarray(fixture['OutputZero'][name])[:,None]),0,255).astype(np.int64) for name in ('Coarse','Fine')}
def integer_pcm(cd):
    _,_,_,re,im=integer_spectral(cd)
    ri=np.rint(re*65536).astype(np.int64); ii=np.rint(im*65536).astype(np.int64)
    A=params[p['CoefA']//4:p['CoefA']//4+220].reshape(20,11).astype(np.int64)
    B=params[p['CoefB']//4:p['CoefB']//4+220].reshape(20,11).astype(np.int64)
    frames=(A@ri+B@ii+2097152)>>22
    acc=np.zeros(20+5*(F-1),dtype=np.int64)
    for n in range(20): acc[n:n+5*F:5]+=frames[n]
    v=acc[10:10+5*(F-1)].copy()
    gains=params[p['EdgeGain']//4:p['EdgeGain']//4+10].astype(np.int64)
    v[:5]=(v[:5]*gains[:5]+8192)>>14; v[-5:]=(v[-5:]*gains[5:]+8192)>>14
    return np.clip((v+256)>>9,-32768,32767).astype(np.int16)
if not np.array_equal(integer_pcm(codes),np.rint(audio4*32768).astype(np.int16)):
    raise ValueError('Integer reference does not match emitted PCM')
result['integerReferencePcmMismatches']=0
result['factorial']={
    'stock_logits_integer_downstream':pcm_metrics(integer_pcm(quantize_logits(stock_post))/32768.),
    'stock_leaky_stock_conv_integer_downstream':pcm_metrics(integer_pcm(quantize_logits(post(stock_leaky)))/32768.),
    'frozen_integer_leaky_stock_conv_integer_downstream':pcm_metrics(integer_pcm(quantize_logits(zleaky))/32768.),
    'frozen_integer_leaky_actual_hmx_integer_downstream':pcm_metrics(audio4),
    'frozen_float_leaky_stock_conv_integer_downstream':pcm_metrics(integer_pcm(quantize_logits(z1))/32768.)}
if args.stock_input_output:
    alt=args.stock_input_output.resolve()
    af=js(alt.parent/'fixture.json')
    for item in af['Files']:
        if sha(alt.parent/item['Name'])!=item['SHA256']: raise ValueError('Stock-input fixture integrity')
    if af['InputScale']!=scale or af['LeakyPositive']!=65536 or af['LeakyNegative']!=65536 or af['LeakyBias']!=-8355840:
        raise ValueError('Stock-input identity LeakyReLU contract differs')
    altbytes=alt.read_bytes()
    if len(altbytes)!=layout['OutputBytes'] or int.from_bytes(altbytes[44:48],'little')!=1:
        raise ValueError('Stock-input job did not complete')
    aq=np.fromfile(alt.parent/'activations.bin',np.uint8).reshape(tiles,4,16,32,2,2)[...,1].transpose(0,2,4,1,3).reshape(-1,128).T[:,:F]
    if not np.array_equal(aq,np.clip(np.rint(stock_leaky/scale+128),0,255)):
        raise ValueError('Stock-input fixture does not contain quantized stock LeakyReLU')
    for name in ('Coarse','Fine'):
        if af['OutputScale'][name]!=fixture['OutputScale'][name] or af['OutputZero'][name]!=fixture['OutputZero'][name]:
            raise ValueError('Output calibration differs')
    if sha(alt.parent/'weights.bin')!=sha(FIX/'weights.bin'):
        raise ValueError('Stock-input convolution weights differ')
    if (alt.parent/'tables.bin').read_bytes()[12:]!=(FIX/'tables.bin').read_bytes()[12:]:
        raise ValueError('Stock-input downstream parameters differ')
    apcm=np.frombuffer(altbytes,'<i2',count=fixture['Samples'],offset=layout['PcmOffset']).astype(np.float64)/32768.
    ao=int.from_bytes(altbytes[40:44],'little')
    if ao<layout['CodesFloor'] or ao+2*tiles*8192>len(altbytes):
        raise ValueError('Stock-input code offsets outside output buffer')
    acodes={}
    for i,name in enumerate(('Coarse','Fine')):
        b=np.frombuffer(altbytes,np.uint8,count=tiles*8192,offset=ao+i*tiles*8192)
        acodes[name]=b.reshape(tiles,4,16,32,2,2)[...,1].transpose(0,2,4,1,3).reshape(-1,128).T[:22,:F].astype(np.int64)
    if not np.array_equal(integer_pcm(acodes),np.rint(apcm*32768).astype(np.int16)):
        raise ValueError('Stock-input PCM differs from integer reference')
    result['factorial']['stock_leaky_quantized_actual_hmx_integer_downstream']=pcm_metrics(apcm)
    result['stockInputOutputSHA256']=sha(alt)
result['toolSHA256']=sha(pathlib.Path(__file__))
result['savedPhoneArtifacts']=[]
for phone_path in args.phone_output:
    phone_path=phone_path.resolve()
    receipt_path=phone_path.with_name(phone_path.name.replace('device-output-','device-receipt-')).with_suffix('.txt')
    receipt={line.partition('=')[0]:line.partition('=')[2] for line in receipt_path.read_text().splitlines() if '=' in line}
    if receipt.get('OutputSHA256')!=sha(phone_path) or receipt.get('Passed')!='True':
        raise ValueError('Saved phone output/receipt integrity')
    pb=phone_path.read_bytes()
    if len(pb)!=layout['OutputBytes'] or int.from_bytes(pb[44:48],'little')!=1:
        raise ValueError('Saved phone output length/completion')
    pp=np.frombuffer(pb,'<i2',count=fixture['Samples'],offset=layout['PcmOffset'])
    if not np.array_equal(pp,np.rint(audio4*32768).astype(np.int16)):
        raise ValueError('Saved phone PCM differs from simulator')
    po=int.from_bytes(pb[40:44],'little')
    if po<layout['CodesFloor'] or po+2*tiles*8192>len(pb): raise ValueError('Phone code bounds')
    if pb[po:po+2*tiles*8192]!=buffer[offset:offset+2*tiles*8192]:
        raise ValueError('Saved phone code tensors differ from simulator')
    soc=next((name for name in ('SM8550','SM8635') if name in phone_path.name),None)
    result['savedPhoneArtifacts'].append(dict(soc=soc,outputSHA256=sha(phone_path),pcmMatchesSimulator=True,
        codesMatchSimulator=True,recordedMedianTiming=receipt.get('MedianRegionTicks'),
        evidence='Reverified saved artifact and receipt; no fresh phone run.'))
result['pcmSaturationCount']=int(np.count_nonzero((audio4==-1)|(audio4==32767/32768)))
result['leakyEndpointCount']=int(np.count_nonzero((ql==0)|(ql==255)))
result['averageCaptureManifestSHA256']=sha(AVG/'capture.json')
result['captureManifestSHA256']=sha(CAP/'capture.json')
(OUT/'report.json').write_text(json.dumps(result,indent=2))
for name,m in ledger.items(): print(name,round(m['snrDb'],6))
for name,m in result['factorial'].items(): print(name,round(m['snrDb'],6))
print('Report:',OUT/'report.json')
