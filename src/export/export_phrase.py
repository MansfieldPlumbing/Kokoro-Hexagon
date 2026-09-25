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
speaker = spec.get('speaker', 'narrator')
if not isinstance(speaker, str) or not speaker or len(speaker) > 64:
    raise ValueError('speaker must be a non-empty string of at most 64 characters')

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

# Optional acoustic probe controls. These operate on the decoder's native
# F0/noise/source inputs; they are not text aliases for non-speech sounds.
acoustics = spec.get('acoustics')
variable_length_snr_db = None
if acoustics is not None:
    if not isinstance(acoustics, dict):
        raise ValueError('acoustics must be an object')
    allowed = {'f0Scale', 'nScale', 'sourceGain', 'envelopePower', 'seed'}
    unknown = set(acoustics).difference(allowed)
    if unknown:
        raise ValueError(f'unknown acoustics fields: {sorted(unknown)}')
    f0_scale = float(acoustics.get('f0Scale', 1.0))
    n_scale = float(acoustics.get('nScale', 1.0))
    source_gain = float(acoustics.get('sourceGain', 1.0))
    envelope_power = float(acoustics.get('envelopePower', 0.0))
    seed = int(acoustics.get('seed', 0))
    if not 0.0 <= f0_scale <= 2.0:
        raise ValueError('acoustics.f0Scale must be in [0, 2]')
    if not 0.0 <= n_scale <= 2.0:
        raise ValueError('acoustics.nScale must be in [0, 2]')
    if not 0.0 <= source_gain <= 4.0:
        raise ValueError('acoustics.sourceGain must be in [0, 4]')
    if not 0.0 <= envelope_power <= 4.0:
        raise ValueError('acoustics.envelopePower must be in [0, 4]')
    with torch.no_grad():
        cap['F0'] = cap['F0'] * f0_scale
        cap['N'] = cap['N'] * n_scale
        torch.manual_seed(seed)
        f0_up = gen.f0_upsamp(cap['F0'][:, None]).transpose(1, 2)
        har = gen.m_source(f0_up)[0].transpose(1, 2).squeeze(1)
        if envelope_power > 0:
            phase = torch.linspace(0, torch.pi, har.shape[-1], dtype=har.dtype, device=har.device)
            har = har * torch.sin(phase).clamp_min(0).pow(envelope_power)
        har = har * source_gain
        variable = core(cap['asr'], cap['F0'], cap['N'], cap['s'], har).reshape(-1)[:frames * scope['U']]
        fixed = scope['m'](
            pad(cap['asr'], 1), pad(cap['F0'], 2), pad(cap['N'], 2), cap['s'],
            pad(har, scope['U']), mask).reshape(-1)[:frames * scope['U']]
        error = fixed - variable
        variable_length_snr_db = 10.0 * torch.log10(
            variable.square().sum() / error.square().sum().clamp_min(1e-20)).item()
        # The phone executes this exact fixed-capacity graph, so its execution
        # oracle must be the fixed-capacity output. The manifest separately
        # records its agreement with the variable-length Kokoro decoder.
        scope['full'] = fixed.numpy()

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
    'speaker': speaker,
    'capacity': spec['capacity'],
    'validFrames': frames,
    'validSamples': frames * 600,
    'files': [
        {'name': p.name, 'bytes': p.stat().st_size,
         'sha256': hashlib.sha256(p.read_bytes()).hexdigest().upper()}
        for p in files
    ],
}
if acoustics is not None:
    manifest['acoustics'] = acoustics
    manifest['variableLengthSnrDb'] = round(variable_length_snr_db, 3)
(out / 'phrase.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
print(json.dumps(manifest, indent=2))
