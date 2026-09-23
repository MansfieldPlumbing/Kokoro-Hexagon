"""Create a phrase input bundle for already-compiled front and generator contexts.

Usage: export_phrase.py <export_decoder.py> <masked.py> <spec.json> <outdir>
The spec contains id, phonemes, voice and capacity. Text-to-phoneme conversion is
deliberately outside this artifact producer so the exact model input is pinned.
"""
import hashlib, json, os, pathlib, sys
import numpy as np
import torch
import torch.nn.functional as F

args = list(sys.argv)
spec_path = pathlib.Path(args[3])
out = pathlib.Path(args[4])
spec = json.loads(spec_path.read_text(encoding='utf-8'))
required = {'id', 'phonemes', 'voice', 'capacity'}
missing = required.difference(spec)
if missing:
    raise ValueError(f'missing phrase spec fields: {sorted(missing)}')
if not isinstance(spec['capacity'], int) or spec['capacity'] <= 0:
    raise ValueError('capacity must be a positive integer')

old_phonemes = os.environ.get('KOKORO_QNN_PHONEMES')
old_voice = os.environ.get('KOKORO_QNN_VOICE')
os.environ['KOKORO_QNN_PHONEMES'] = spec['phonemes']
os.environ['KOKORO_QNN_VOICE'] = spec['voice']
try:
    sys.argv = ['export_phrase', args[1], str(out), str(spec['capacity'])]
    scope = {'__name__': 'export_phrase_inputs'}
    exec(pathlib.Path(args[2]).read_text(encoding='utf-8'), scope)
finally:
    if old_phonemes is None:
        os.environ.pop('KOKORO_QNN_PHONEMES', None)
    else:
        os.environ['KOKORO_QNN_PHONEMES'] = old_phonemes
    if old_voice is None:
        os.environ.pop('KOKORO_QNN_VOICE', None)
    else:
        os.environ['KOKORO_QNN_VOICE'] = old_voice

out.mkdir(parents=True, exist_ok=True)
core, cap, har = scope['core'], scope['cap'], scope['har']
pad, mask, frames = scope['pad'], scope['mask'], int(scope['L'])
gen = core.d.generator

def write_f32(name, tensor):
    path = out / f'in_{name}.f32'
    np.ascontiguousarray(tensor.detach().numpy(), dtype='<f4').tofile(path)
    return path

with torch.no_grad():
    padded_har = pad(har, scope['U'])
    spectrum, phase = gen.stft.transform(padded_har)
    har_input = torch.cat([spectrum, phase], 1)
    aligned_length = ((har_input.shape[-1] + 7) // 8) * 8
    har8 = F.pad(har_input, (0, aligned_length - har_input.shape[-1]), mode='replicate')
    final_mask = F.interpolate(mask, size=har_input.shape[-1], mode='nearest')
    mask8 = F.pad(final_mask, (0, aligned_length - final_mask.shape[-1]))
    scope['gb_register'](core.d)
    gb = scope['gb_compute'](cap['s'])

files = [
    write_f32('asr', pad(cap['asr'], 1)),
    write_f32('F0_curve', pad(cap['F0'], 2)),
    write_f32('N', pad(cap['N'], 2)),
    write_f32('style', cap['s']),
    write_f32('gb', gb),
    write_f32('har8', har8),
    write_f32('mask', mask),
    write_f32('mask8', mask8),
]
oracle = out / 'oracle_audio.f32'
np.ascontiguousarray(scope['full'], dtype='<f4').tofile(oracle)
files.append(oracle)

manifest = {
    'schema': 1,
    'id': spec['id'],
    'phonemes': spec['phonemes'],
    'voice': spec['voice'],
    'capacity': spec['capacity'],
    'validFrames': frames,
    'validSamples': frames * 600,
    'files': [
        {'name': p.name, 'bytes': p.stat().st_size,
         'sha256': hashlib.sha256(p.read_bytes()).hexdigest().upper()}
        for p in files
    ],
}
(out / 'phrase.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
print(json.dumps(manifest, indent=2))
