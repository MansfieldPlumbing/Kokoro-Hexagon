import sys, numpy as np, torch, torch.nn.functional as F
ARGS=list(sys.argv); sys.argv=['x', ARGS[1], ARGS[3], '160']
g={'__name__':'fp16'}; exec(open(ARGS[2],encoding='utf-8').read(), g)
ist=g['ist']; CUR=g['CUR']; core=g['core']; d=core.d
D=np.load(ARGS[4]); ref=np.load(ARGS[5])
def front(asr,F0c,N,s,mask):
    CUR['mask']=mask; asr=asr*mask
    F0=d.F0_conv(F0c.unsqueeze(1)); Nn=d.N_conv(N.unsqueeze(1))
    x=d.encode(torch.cat([asr,F0,Nn],1),s); ar=d.asr_res(asr); res=True
    for b in d.decode:
        if res: x=torch.cat([x,ar,F0,Nn],1)
        x=b(x,s)
        if b.upsample_type!='none': res=False
    return x
def safe(self,x,s):
    h=self.fc(s).view(s.size(0),-1,1); gm,bt=torch.chunk(h,2,1)
    m=F.interpolate(CUR['mask'],size=x.shape[-1],mode='nearest'); k=x.shape[-1]/m.sum(-1,keepdim=True)
    mu=(x*m).mean(-1,keepdim=True)*k; c=(x-mu)*m
    var=(c*c).mean(-1,keepdim=True)*k
    y=c/torch.sqrt(var+self.norm.eps); y=y*self.norm.weight.view(1,-1,1)+self.norm.bias.view(1,-1,1)
    return ((1+gm)*y+bt)*m
def run(dt):
    t=lambda a: torch.from_numpy(a).to(dt)
    with torch.no_grad(): return front(t(D['asr']),t(D['F0']),t(D['N']),t(D['s']),t(D['mask'])).float().numpy()
def rep(tag,y):
    e=y-ref; fin=np.isfinite(y).all(); print(f'{tag:28s} finite={fin} SNR={10*np.log10((ref**2).sum()/np.nansum(e**2)):.2f} dB max={np.nanmax(np.abs(e)):.4g}')
d.float(); rep('fp32 current', run(torch.float32))
d.half(); rep('fp16 current masked norm', run(torch.float16))
ist.AdaIN1d.forward=safe; rep('fp16 range-safe norm', run(torch.float16))
d.float(); rep('fp32 range-safe norm', run(torch.float32))
