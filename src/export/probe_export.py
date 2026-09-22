import sys, numpy as np, torch
ARGS=list(sys.argv); src=open(ARGS[1],encoding='utf-8').read().split('def run(dt)')[0]
sys.argv=['x',ARGS[2],ARGS[3],ARGS[4],ARGS[5],ARGS[6]]; g={'__name__':'probe'}; exec(src,g)
d,CUR,D,torchF=g['d'],g['CUR'],g['D'],torch.nn.functional
class Probe(torch.nn.Module):
    def __init__(s): super().__init__(); s.d=d
    def forward(s, asr, F0_curve, N, style, mask):
        CUR['mask']=mask; asr=asr*mask
        F0=d.F0_conv(F0_curve.unsqueeze(1)); Nn=d.N_conv(N.unsqueeze(1))
        x=d.encode(torch.cat([asr,F0,Nn],1),style); outs=[F0,Nn,x]
        ar=d.asr_res(asr); res=True
        for b in d.decode:
            if res: x=torch.cat([x,ar,F0,Nn],1)
            x=b(x,style); outs.append(x)
            if b.upsample_type!='none': res=False
        return tuple(outs)
names=['p_F0','p_N','p_enc']+[f'p_dec{i}' for i in range(len(d.decode))]
t=lambda a: torch.from_numpy(a).float(); ins=(t(D['asr']),t(D['F0']),t(D['N']),t(D['s']),t(D['mask']))
with torch.no_grad(): ys=Probe().eval()(*ins)
out=ARGS[4]
torch.onnx.export(Probe().eval(),ins,out+r'\kokoro_frontprobe_c160.onnx',dynamo=False,opset_version=17,input_names=['asr','F0_curve','N','style','mask'],output_names=names)
for n,y in zip(names,ys): y.numpy().astype('<f4').tofile(out+rf'\oracle_{n}.f32'); print(n,tuple(y.shape))
