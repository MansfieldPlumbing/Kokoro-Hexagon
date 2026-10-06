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
    block = model.decoder.generator.resblocks[3]
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

    def pre_block(module, inputs):
        save('input', inputs[0])
        save('style', inputs[1])

    handles = [block.register_forward_pre_hook(pre_block)]
    for iteration in range(3):
        for branch, convs, norms in (('1', block.convs1, block.adain1),
                                     ('2', block.convs2, block.adain2)):
            name = 'stage' + str(2*iteration + int(branch)-1)
            conv = convs[iteration]
            norm = norms[iteration]
            handles.append(norm.register_forward_pre_hook(
                lambda module, inputs, key=name: save(key + '.input', inputs[0])))
            handles.append(norm.register_forward_hook(
                lambda module, inputs, result, key=name: save(key + '.adain', result)))
            handles.append(conv.register_forward_pre_hook(
                lambda module, inputs, key=name: save(key + '.snake', inputs[0])))
            handles.append(conv.register_forward_hook(
                lambda module, inputs, result, key=name: save(key + '.conv', result)))
            save(name + '.weight', conv.weight)
            save(name + '.bias', conv.bias)
            for parameter, value in norm.state_dict().items():
                save(name + '.adain.' + parameter, value)
            save(name + '.alpha', (block.alpha1 if branch == '1' else block.alpha2)[iteration])

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
        for handle in handles:
            handle.remove()
    if 'output' not in tensors:
        raise RuntimeError('Stock model did not reach the selected residual block')
    capture = {'schema': 1, 'sourceCommit': spec['sourceCommit'],
               'checkpointSha256': spec['inputs']['kokoro-v1_0.pth']['sha256'],
               'torchVersion': torch.__version__, 'block': spec['block'],
               'verifiedCheckpointTensors': verified_parameters,
               'captureToolSha256': digest(__file__),
               'exportToolSha256': spec['exportToolSha256'],
               'phonemes': phonemes, 'styleEntry': len(phonemes)-1,
               'voice': spec['voice'], 'seed': spec['seed'], 'speed': 1,
               'tensors': tensors}
    (output / 'capture.json').write_text(json.dumps(capture, indent=2), encoding='utf-8')
    print(json.dumps({'capturedTensors': len(tensors), 'inputShape': tensors['input']['shape'],
                      'outputShape': tensors['output']['shape'], 'torchVersion': torch.__version__}))


if __name__ == '__main__':
    main()
