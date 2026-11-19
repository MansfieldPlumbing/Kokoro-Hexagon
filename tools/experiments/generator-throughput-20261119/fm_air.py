"""Offline mono 24->48 kHz FM air audition; DSP timing is measured separately."""
from array import array
from math import cos, sin, pi, sqrt, exp
from pathlib import Path
import argparse
import wave
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument("baseband", type=Path, help="24 kHz mono PCM16 WAV")
parser.add_argument("air_reference", type=Path, help="48 kHz mono PCM16 WAV")
parser.add_argument("output_directory", type=Path)
args=parser.parse_args()
root=args.output_directory
root.mkdir(parents=True, exist_ok=True)
def read(path, rate, seconds=None):
    with wave.open(str(path)) as w:
        if w.getsampwidth()!=2 or w.getnchannels()!=1 or w.getframerate()!=rate:
            raise ValueError(f"Expected mono PCM16 at {rate} Hz in {path}")
        data=array('h'); data.frombytes(w.readframes(w.getnframes() if seconds is None else int(seconds*w.getframerate())))
        return data
def kernel(lo, hi, rate, n=65):
    def low(fc,x):
        return 2*fc/rate if not x else sin(2*pi*fc*x/rate)/(pi*x)
    return [(low(hi,i-n//2)-low(lo,i-n//2))*(0.42-0.5*cos(2*pi*i/(n-1))+0.08*cos(4*pi*i/(n-1))) for i in range(n)]
def filtered(data,h):
    m=len(h)//2; pad=array('d',[0])*m+array('d',data)+array('d',[0])*m
    return array('d',(sum(x*y for x,y in zip(h,pad[i:i+len(h)])) for i in range(len(data))))
def rms(x):
    return sqrt(sum(v*v for v in x)/len(x))
def save(name,x):
    with wave.open(str(root/name),'wb') as w:
        w.setparams((1,2,48000,0,'NONE',''))
        w.writeframes(array('h',(max(-32768,min(32767,round(v))) for v in x)).tobytes())
base=read(args.baseband,24000)
# Half-band interpolation preserves original samples at even indices.
up=array('d',[0])*(2*len(base))
up[::2]=array('d',base)
sinc=[sin(pi*(j-.5))/(pi*(j-.5))*(.42+.5*cos(pi*(j-.5)/16)+.08*cos(2*pi*(j-.5)/16)) for j in range(-15,17)]
sinc=[x/sum(sinc) for x in sinc]
pad=array('d',[0])*15+array('d',base)+array('d',[0])*16
up[1::2]=array('d',(sum(x*y for x,y in zip(sinc,pad[i:i+32])) for i in range(len(base))))
# Use measured band RMS ratios of Scott's existing air audition as the level reference.
ref=read(args.air_reference,48000,12)
mid=kernel(8000,11500,48000)
bands=[kernel(12000,16000,48000),kernel(16000,20000,48000)]
ref_mid=rms(filtered(ref,mid)); gains=[rms(filtered(ref,h))/ref_mid for h in bands]
env=filtered(up,mid)
energy=0; decay=exp(-1/(.006*48000)); carrier=array('d')
for i,x in enumerate(env):
    energy=decay*energy+(1-decay)*x*x
    t=2*pi*i/48000
    carrier.append(sqrt(energy)*sin(15137*t+2.4*sin(1321*t)+1.6*sin(1927*t)))
air=array('d',[0])*len(up)
for h,gain in zip(bands,gains):
    band=filtered(carrier,h); scale=gain*rms(env)/rms(band)
    for i,v in enumerate(band): air[i]+=scale*v
mixed=array('d',(x+y for x,y in zip(up,air)))
gain=min(1,32760/max(max(abs(x) for x in up),max(abs(x) for x in mixed)))
save('control-48k.wav',(gain*x for x in up));save('control-fm-air-48k.wav',(gain*x for x in mixed))
print('band RMS ratios',gains,'common gain',gain,'frames',len(up),'air RMS',rms(air))
