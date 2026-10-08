"""Reference-only hooks on pinned stock Kokoro's decoder (before the generator); no reimplementation of its math."""
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
        if digest(root / item['path']) != item['sha256']:
            raise ValueError('Stock source integrity mismatch')
    for item in spec['inputs'].values():
        if digest(item['path']) != item['sha256']:
            raise ValueError('Stock input integrity mismatch')
    # As capture_stock_generator.py: avoid the package __init__ (KPipeline/misaki); stock modules load unmodified.
    package = types.ModuleType('kokoro')
    package.__path__ = [str(root / 'kokoro')]
    sys.modules['kokoro'] = package
    import torch
    from loguru import logger
    logger.remove()
    logger.add(sys.stderr, level='WARNING')
    torch.set_num_threads(4)
    torch.manual_seed(spec['seed'])
    model = importlib.import_module('kokoro.model').KModel(
        repo_id='hexgrad/Kokoro-82M', config=spec['inputs']['config.json']['path'],
        model=spec['inputs']['kokoro-v1_0.pth']['path']).eval()
    # Every checkpoint tensor must have loaded exactly (as capture_stock_generator.py).
    checkpoint = torch.load(spec['inputs']['kokoro-v1_0.pth']['path'], map_location='cpu', weights_only=True)
    verified_parameters = 0
    for component, values in checkpoint.items():
        loaded = getattr(model, component).state_dict()
        for original_key, expected in values.items():
            key = original_key.removeprefix('module.')
            if key not in loaded:
                key = key.replace('weight_g', 'parametrizations.weight.original0').replace('weight_v', 'parametrizations.weight.original1')
            if key not in loaded or not torch.equal(expected, loaded[key]):
                raise ValueError('Stock checkpoint parameter was not loaded exactly: ' + component + '.' + key)
            verified_parameters += 1
    pack = torch.load(spec['inputs']['voices\\' + spec['voice'] + '.pt']['path'], map_location='cpu', weights_only=True)
    phonemes = spec['phonemes']
    if not (1 <= len(phonemes) <= 510) or any(p not in model.vocab for p in phonemes):
        raise ValueError('Phonemes out of bounds or outside the stock vocabulary')
    style = pack[len(phonemes) - 1]
    decoder = model.decoder
    output = pathlib.Path(spec['output'])
    tensors = {}

    def save(name, value):
        tensor = value.detach().cpu().contiguous().to(torch.float32)
        if not bool(torch.isfinite(tensor).all()):
            raise ValueError('Nonfinite captured tensor: ' + name)
        path = output / (name + '.f32')
        tensor.numpy().astype('<f4', copy=False).tofile(path)
        tensors[name] = {'file': path.name, 'shape': list(tensor.shape), 'bytes': path.stat().st_size, 'sha256': digest(path)}

    def save_values(prefix, values):
        if torch.is_tensor(values):
            save(prefix, values)
        elif isinstance(values, (tuple, list)):
            for i, value in enumerate(values):
                save_values(prefix + '.' + str(i), value)

    handles = []
    handles.append(decoder.register_forward_pre_hook(lambda mod, values: save_values('decoder.input', values)))
    contracts = {}
    for name, module in decoder.named_modules():
        if not name or name.startswith('generator') or '.parametrizations' in name or name.endswith(('.fc', '.norm')):
            continue
        # Weight-normed convs are ParametrizedConv1d / ParametrizedConvTranspose1d: match the base classes.
        kind = 'ConvTranspose1d' if isinstance(module, torch.nn.ConvTranspose1d) else 'Conv1d' if isinstance(module, torch.nn.Conv1d) else type(module).__name__
        if kind not in ('AdainResBlk1d', 'AdaIN1d', 'Conv1d', 'ConvTranspose1d', 'Sequential', 'LeakyReLU'):
            continue
        key = 'decoder.' + name
        contracts[name] = {'type': kind}
        for attribute in ('in_channels', 'out_channels', 'kernel_size', 'stride', 'padding', 'output_padding', 'dilation', 'groups'):
            if hasattr(module, attribute):
                contracts[name][attribute] = getattr(module, attribute)
        handles.append(module.register_forward_pre_hook(lambda mod, values, key=key: save_values(key + '.input', values)))
        handles.append(module.register_forward_hook(lambda mod, values, result, key=key: save_values(key + '.output', result)))
        if kind in ('Conv1d', 'ConvTranspose1d'):
            save(key + '.weight', module.weight)
            if module.bias is not None:
                save(key + '.bias', module.bias)
        if kind == 'AdaIN1d':
            for parameter, value in module.state_dict().items():
                save(key + '.' + parameter, value)

    class CaptureComplete(Exception):
        pass

    def at_generator(module, inputs):
        save_values('decoder.generator.input', inputs)
        raise CaptureComplete()

    handles.append(decoder.generator.register_forward_pre_hook(at_generator))
    try:
        with torch.inference_mode():
            model(phonemes, style, speed=1)
    except CaptureComplete:
        pass
    finally:
        for handle in handles:
            handle.remove()
    if 'decoder.generator.input.0' not in tensors:
        raise RuntimeError('Stock model did not reach the generator')
    capture = {'schema': 1, 'sourceCommit': spec['sourceCommit'], 'checkpointSha256': spec['inputs']['kokoro-v1_0.pth']['sha256'],
               'torchVersion': torch.__version__, 'block': 'decoder', 'verifiedCheckpointTensors': verified_parameters, 'captureToolSha256': digest(__file__),
               'exportToolSha256': spec['exportToolSha256'], 'phonemes': phonemes, 'styleEntry': len(phonemes) - 1,
               'voice': spec['voice'], 'seed': spec['seed'], 'speed': 1, 'tensors': tensors, 'moduleContracts': contracts}
    (output / 'capture.json').write_text(json.dumps(capture, indent=2), encoding='utf-8')
    print(json.dumps({'capturedTensors': len(tensors), 'generatorInput': tensors['decoder.generator.input.0']['shape'], 'torchVersion': torch.__version__}))


if __name__ == '__main__':
    main()
