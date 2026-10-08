"""Reference-only hooks on pinned stock Kokoro; no reimplementation of its math."""
import argparse
import hashlib
import importlib
import json
import pathlib
import sys
import types


def digest(path):
    with open(path, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest().upper()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--spec', required=True)
    args = parser.parse_args()
    spec = json.loads(pathlib.Path(args.spec).read_text(encoding='utf-8-sig'))
    root = pathlib.Path(spec['sourceRoot'])
    for item in spec['sourceFiles']:
        path = root / item['path']
        if digest(path) != item['sha256']:
            raise ValueError('Stock source integrity mismatch')
    for item in spec['inputs'].values():
        if digest(item['path']) != item['sha256']:
            raise ValueError('Stock input integrity mismatch')
    # Avoid package __init__ importing KPipeline/misaki. The unmodified stock
    # model and its relative imports still load from the verified source files.
    package = types.ModuleType('kokoro')
    package.__path__ = [str(root / 'kokoro')]
    sys.modules['kokoro'] = package
    import torch
    from loguru import logger
    logger.remove()
    logger.add(sys.stderr, level='WARNING')
    torch.set_num_threads(4)
    torch.manual_seed(spec['seed'])
    model_class = importlib.import_module('kokoro.model').KModel
    model = model_class(repo_id='hexgrad/Kokoro-82M',
                        config=spec['inputs']['config.json']['path'],
                        model=spec['inputs']['kokoro-v1_0.pth']['path']).eval()
    checkpoint = torch.load(spec['inputs']['kokoro-v1_0.pth']['path'],
                            map_location='cpu', weights_only=True)
    verified_parameters = 0
    for component, values in checkpoint.items():
        loaded = getattr(model, component).state_dict()
        for original_key, expected in values.items():
            key = original_key.removeprefix('module.')
            if key not in loaded:
                key = key.replace('weight_g', 'parametrizations.weight.original0').replace(
                    'weight_v', 'parametrizations.weight.original1')
            if key not in loaded or not torch.equal(expected, loaded[key]):
                raise ValueError('Stock checkpoint parameter was not loaded exactly: ' + component + '.' + key)
            verified_parameters += 1
    voice_key = 'voices\\' + spec['voice'] + '.pt'
    pack = torch.load(spec['inputs'][voice_key]['path'], map_location='cpu', weights_only=True)
    phonemes = spec['phonemes']
    if not (1 <= len(phonemes) <= 510) or len(phonemes) > len(pack):
        raise ValueError('Phoneme/style-entry length is out of bounds')
    if any(p not in model.vocab for p in phonemes):
        raise ValueError('Every captured phoneme must occur in the stock vocabulary')
    style = pack[len(phonemes)-1]
    block = model.decoder.generator
    output = pathlib.Path(spec['output'])
    tensors = {}

    def save(name, value):
        tensor = value.detach().cpu().contiguous().to(torch.float32)
        if not bool(torch.isfinite(tensor).all()):
            raise ValueError('Nonfinite captured tensor: ' + name)
        path = output / (name + '.f32')
        tensor.numpy().astype('<f4', copy=False).tofile(path)
        tensors[name] = {'file': path.name, 'shape': list(tensor.shape),
                         'bytes': path.stat().st_size, 'sha256': digest(path)}

    trace_state = {'active': False, 'index': 0}
    original_leaky_relu = torch.nn.functional.leaky_relu
    def trace_leaky_relu(value, *args, **kwargs):
        if not trace_state['active']:
            return original_leaky_relu(value, *args, **kwargs)
        key = 'generator.leaky.' + str(trace_state['index'])
        trace_state['index'] += 1
        save(key + '.input', value)
        result = original_leaky_relu(value, *args, **kwargs)
        save(key + '.output', result)
        return result
    torch.nn.functional.leaky_relu = trace_leaky_relu
    def pre_block(module, inputs):
        trace_state['active'] = True
        save('input', inputs[0])
        save('style', inputs[1])
        save('f0', inputs[2])

    handles = [block.register_forward_pre_hook(pre_block)]
    def save_values(prefix, values):
        if torch.is_tensor(values):
            save(prefix, values)
        elif isinstance(values, (tuple, list)):
            for i, value in enumerate(values):
                save_values(prefix + '.' + str(i), value)

    # Original stock modules execute every operation. Hooks only serialize their
    # inputs/outputs and effective parameters; no alternate generator equations.
    contracts = {}
    for name, module in block.named_modules():
        if not name:
            continue
        selected = (name in ('m_source', 'conv_post', 'reflection_pad') or
                    name.startswith(('ups.', 'noise_convs.')) and name.count('.') == 1 or
                    name.startswith(('resblocks.', 'noise_res.')) and
                    (name.count('.') == 1 or '.convs' in name or '.adain' in name) and
                    not any(part in name for part in ('.fc', '.norm', '.parametrizations')))
        if not selected:
            continue
        key = 'generator.' + name
        contracts[name] = {'type': type(module).__name__}
        for attribute in ('in_channels', 'out_channels', 'kernel_size', 'stride',
                          'padding', 'output_padding', 'dilation', 'groups'):
            if hasattr(module, attribute):
                contracts[name][attribute] = getattr(module, attribute)
        handles.append(module.register_forward_pre_hook(
            lambda mod, values, key=key: save_values(key + '.input', values)))
        handles.append(module.register_forward_hook(
            lambda mod, values, result, key=key: save_values(key + '.output', result)))
        if isinstance(module, (torch.nn.Conv1d, torch.nn.ConvTranspose1d)):
            save(key + '.weight', module.weight)
            if module.bias is not None:
                save(key + '.bias', module.bias)
        if type(module).__name__ == 'AdaIN1d':
            for parameter, value in module.state_dict().items():
                save(key + '.' + parameter, value)
        if type(module).__name__ == 'AdaINResBlock1':
            for kind in ('alpha1', 'alpha2'):
                for i, value in enumerate(getattr(module, kind)):
                    save(key + '.' + kind + '.' + str(i), value)
    # Capture the harmonic STFT inputs/outputs and final iSTFT operands without
    # replacing either stock method; these methods are not nn.Module hooks.
    original_transform = block.stft.transform
    original_inverse = block.stft.inverse
    def trace_transform(*args, **kwargs):
        save_values('generator.stft.transform.input', args)
        result = original_transform(*args, **kwargs)
        save_values('generator.stft.transform.output', result)
        return result
    def trace_inverse(*args, **kwargs):
        save_values('generator.stft.inverse.input', args)
        result = original_inverse(*args, **kwargs)
        save_values('generator.stft.inverse.output', result)
        return result
    block.stft.transform = trace_transform
    block.stft.inverse = trace_inverse

    # Harmonic source internals: SineGen's random draws (torch.rand for the initial phases, torch.randn_like for the
    # noise) are recorded as the stock calls return them, inside l_sin_gen only; its outputs and l_linear's are saved.
    # The calls themselves and their order are unchanged, so the RNG stream is the stock one.
    source = block.m_source
    random_state = {'active': False, 'rand': 0, 'randn': 0}
    original_rand = torch.rand
    original_randn_like = torch.randn_like
    def trace_rand(*args, **kwargs):
        result = original_rand(*args, **kwargs)
        if random_state['active']:
            save('generator.m_source.l_sin_gen.rand.' + str(random_state['rand']), result)
            random_state['rand'] += 1
        return result
    def trace_randn_like(*args, **kwargs):
        result = original_randn_like(*args, **kwargs)
        if random_state['active']:
            save('generator.m_source.l_sin_gen.randn.' + str(random_state['randn']), result)
            random_state['randn'] += 1
        return result
    torch.rand = trace_rand
    torch.randn_like = trace_randn_like
    def sine_pre(module, inputs):
        random_state['active'] = True
        save_values('generator.m_source.l_sin_gen.input', inputs)
    def sine_post(module, inputs, result):
        random_state['active'] = False
        save_values('generator.m_source.l_sin_gen.output', result)
    handles.append(source.l_sin_gen.register_forward_pre_hook(sine_pre))
    handles.append(source.l_sin_gen.register_forward_hook(sine_post))
    handles.append(source.l_linear.register_forward_hook(
        lambda mod, values, result: save('generator.m_source.l_linear.output', result)))
    save('generator.m_source.l_linear.weight', source.l_linear.weight)
    save('generator.m_source.l_linear.bias', source.l_linear.bias)

    class CaptureComplete(Exception):
        pass

    def post_block(module, inputs, result):
        save('output', result)
        raise CaptureComplete()

    handles.append(block.register_forward_hook(post_block))
    try:
        with torch.inference_mode():
            model(phonemes, style, speed=1)
    except CaptureComplete:
        pass
    finally:
        torch.nn.functional.leaky_relu = original_leaky_relu
        torch.rand = original_rand
        torch.randn_like = original_randn_like
        for handle in handles:
            handle.remove()
    if 'output' not in tensors:
        raise RuntimeError('Stock model did not reach the selected generator')
    capture = {'schema': 1, 'sourceCommit': spec['sourceCommit'],
               'checkpointSha256': spec['inputs']['kokoro-v1_0.pth']['sha256'],
               'torchVersion': torch.__version__, 'block': spec['block'],
               'verifiedCheckpointTensors': verified_parameters,
               'captureToolSha256': digest(__file__),
               'exportToolSha256': spec['exportToolSha256'],
               'phonemes': phonemes, 'styleEntry': len(phonemes)-1,
               'voice': spec['voice'], 'seed': spec['seed'], 'speed': 1,
               'tensors': tensors, 'moduleContracts': contracts}
    (output / 'capture.json').write_text(json.dumps(capture, indent=2), encoding='utf-8')
    print(json.dumps({'capturedTensors': len(tensors), 'inputShape': tensors['input']['shape'],
                      'outputShape': tensors['output']['shape'], 'torchVersion': torch.__version__}))


if __name__ == '__main__':
    main()
