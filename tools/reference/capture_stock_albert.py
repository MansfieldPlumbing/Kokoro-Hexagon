"""Reference-only hooks on pinned stock Kokoro's ALBERT (bert) and bert_encoder; no reimplementation of its math.

Records input_ids and the attention mask, the embeddings, the 128->768 mapping, every repeat of the shared ALBERT layer
(input, q/k/v, attention context and dense, attention LayerNorm, ffn, ffn_output, layer output), bert_dur and d_en, plus every ALBERT
and bert_encoder parameter. Stops at the predictor's text encoder.
"""
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
    # As capture_stock_decoder.py: avoid the package __init__ (KPipeline/misaki); stock modules load unmodified.
    package = types.ModuleType('kokoro')
    package.__path__ = [str(root / 'kokoro')]
    sys.modules['kokoro'] = package
    import torch
    import transformers
    from loguru import logger
    logger.remove()
    logger.add(sys.stderr, level='WARNING')
    torch.set_num_threads(4)
    torch.manual_seed(spec['seed'])
    model = importlib.import_module('kokoro.model').KModel(
        repo_id='hexgrad/Kokoro-82M', config=spec['inputs']['config.json']['path'],
        model=spec['inputs']['kokoro-v1_0.pth']['path']).eval()
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
    output = pathlib.Path(spec['output'])
    tensors = {}

    def save(name, value):
        tensor = value.detach().cpu().contiguous()
        if tensor.dtype in (torch.int64, torch.int32, torch.bool):
            path = output / (name + '.i32')
            tensor.to(torch.int32).numpy().astype('<i4', copy=False).tofile(path)
        else:
            tensor = tensor.to(torch.float32)
            if not bool(torch.isfinite(tensor).all()):
                raise ValueError('Nonfinite captured tensor: ' + name)
            path = output / (name + '.f32')
            tensor.numpy().astype('<f4', copy=False).tofile(path)
        tensors[name] = {'file': path.name, 'shape': list(tensor.shape), 'bytes': path.stat().st_size, 'sha256': digest(path)}

    bert = model.bert
    for name, value in bert.state_dict().items():
        save('bert.' + name, value)
    for name, value in model.bert_encoder.state_dict().items():
        save('bert_encoder.' + name, value)

    layer = bert.encoder.albert_layer_groups[0].albert_layers[0]
    repeat = {'index': -1}
    handles = []

    def on_bert(mod, positional, keywords):
        values = list(positional) + [keywords.get('input_ids'), keywords.get('attention_mask')]
        values = [v for v in values if torch.is_tensor(v)]
        save('bert.input_ids', values[0])
        if len(values) > 1:
            save('bert.attention_mask', values[1])

    handles.append(bert.register_forward_pre_hook(on_bert, with_kwargs=True))
    handles.append(bert.embeddings.register_forward_hook(lambda m, i, o: save('bert.embeddings.output', o)))
    handles.append(bert.encoder.embedding_hidden_mapping_in.register_forward_hook(lambda m, i, o: save('bert.encoder.embedding_hidden_mapping_in.output', o)))

    def on_layer_input(mod, positional, keywords):
        repeat['index'] += 1
        hidden = positional[0] if positional else keywords['hidden_states']
        save('bert.layer.%d.input' % repeat['index'], hidden)

    def on_layer_output(mod, positional, keywords, result):
        save('bert.layer.%d.output' % repeat['index'], result[0] if isinstance(result, (tuple, list)) else result)

    handles.append(layer.register_forward_pre_hook(on_layer_input, with_kwargs=True))
    handles.append(layer.register_forward_hook(on_layer_output, with_kwargs=True))
    names = {'attention.query': layer.attention.query, 'attention.key': layer.attention.key, 'attention.value': layer.attention.value,
             'attention.dense': layer.attention.dense, 'attention.LayerNorm': layer.attention.LayerNorm,
             'ffn': layer.ffn, 'activation': layer.activation, 'ffn_output': layer.ffn_output}
    for suffix, module in names.items():
        def hook(m, i, o, suffix=suffix):
            save('bert.layer.%d.%s.output' % (repeat['index'], suffix), o[0] if isinstance(o, (tuple, list)) else o)
        handles.append(module.register_forward_hook(hook))
    handles.append(layer.attention.dense.register_forward_pre_hook(lambda m, i: save('bert.layer.%d.attention.dense.input' % repeat['index'], i[0])))
    handles.append(bert.register_forward_hook(lambda m, i, o: save('bert_dur', o)))

    class CaptureComplete(Exception):
        pass

    def at_bert_encoder(mod, inputs, result):
        save('d_en', result.transpose(-1, -2))
        raise CaptureComplete()

    handles.append(model.bert_encoder.register_forward_hook(at_bert_encoder))
    try:
        with torch.inference_mode():
            model(phonemes, style, speed=1)
    except CaptureComplete:
        pass
    finally:
        for handle in handles:
            handle.remove()
    if 'd_en' not in tensors or repeat['index'] != bert.config.num_hidden_layers - 1:
        raise RuntimeError('Stock model did not complete ALBERT and bert_encoder')
    config = bert.config
    capture = {'schema': 1, 'sourceCommit': spec['sourceCommit'], 'checkpointSha256': spec['inputs']['kokoro-v1_0.pth']['sha256'],
               'torchVersion': torch.__version__, 'transformersVersion': transformers.__version__, 'block': 'albert',
               'attentionImplementation': config._attn_implementation, 'hiddenAct': config.hidden_act, 'layerNormEps': config.layer_norm_eps,
               'embeddingSize': config.embedding_size, 'verifiedCheckpointTensors': verified_parameters, 'captureToolSha256': digest(__file__),
               'exportToolSha256': spec['exportToolSha256'], 'phonemes': phonemes, 'styleEntry': len(phonemes) - 1,
               'voice': spec['voice'], 'seed': spec['seed'], 'speed': 1, 'tensors': tensors}
    (output / 'capture.json').write_text(json.dumps(capture, indent=2), encoding='utf-8')
    print(json.dumps({'capturedTensors': len(tensors), 'bertDur': tensors['bert_dur']['shape'], 'dEn': tensors['d_en']['shape'],
                      'torch': torch.__version__, 'transformers': transformers.__version__}))


if __name__ == '__main__':
    main()
