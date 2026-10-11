"""Validated input substitution for Windows stock-reference captures only.

The decoder remains hexgrad/kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec.
PyTorch Module.register_forward_pre_hook returns replacement positional inputs;
prepend=True makes the ordinary capture hooks observe those actual inputs.
"""
import hashlib
import json
import pathlib


def digest(path):
    with open(path, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest().upper()


def install_decoder_input(model, spec, torch):
    replacement = spec.get('decoderInput')
    if replacement is None:
        return [], None
    import numpy as np
    descriptor = pathlib.Path(replacement['path'])
    if digest(descriptor) != replacement['sha256']:
        raise ValueError('Decoder input descriptor integrity mismatch')
    data = json.loads(descriptor.read_text(encoding='utf-8-sig'))
    if data['schema'] != 1 or data['phonemes'] != spec['phonemes'] or data['voice'] != spec['voice']:
        raise ValueError('Decoder input phonemes/voice/schema mismatch')
    frames = data['frames']
    if type(frames) is not int or not 1 <= frames <= 96:
        raise ValueError('Decoder input requires 1..96 frames; chunking is a separate step')
    values = []
    for name, shape in (('asr', [1, 512, frames]), ('F0', [1, 2 * frames]), ('N', [1, 2 * frames])):
        item = data['tensors'][name]
        path = descriptor.parent / item['file']
        if path.resolve().parent != descriptor.parent.resolve() or item['shape'] != shape:
            raise ValueError('Decoder input path/shape mismatch: ' + name)
        size = int(np.prod(shape)) * 4
        if item['bytes'] != size or path.stat().st_size != size or digest(path) != item['sha256']:
            raise ValueError('Decoder input tensor integrity mismatch: ' + name)
        value = np.fromfile(path, dtype='<f4').reshape(shape)
        # Stock F0_proj is unconstrained (modules.py:124-134); preserve unvoiced values, including negative ones.
        if not np.isfinite(value).all():
            raise ValueError('Invalid decoder input values: ' + name)
        values.append(torch.from_numpy(value))

    def replace(module, inputs):
        if len(inputs) != 4:
            raise ValueError('Pinned decoder positional-input contract changed')
        return (*values, inputs[3])  # Keep stock pack[len(phonemes)-1] style.

    handle = model.decoder.register_forward_pre_hook(replace, prepend=True)
    provenance = {'path': str(descriptor), 'sha256': replacement['sha256'],
                  'variant': 'network-free Kokoro', 'frames': frames,
                  'tensors': data['tensors'], 'frontEnd': data['provenance']}
    return [handle], provenance
