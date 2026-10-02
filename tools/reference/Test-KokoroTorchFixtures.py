"""Pinned original-source CPU oracle; never imported by the product build."""
import argparse
import array
import ast
import base64
import hashlib
import importlib.metadata
import importlib.util
import inspect
import json
import math
import pathlib
import sys
import types
import typing
import zipfile


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest().upper()


def source_nodes(archive, member, blob, names, namespace, nested=False):
    with zipfile.ZipFile(archive) as package:
        data = package.read(member)
    identity = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
    if identity != blob:
        raise ValueError("Original source blob differs from its immutable pin")
    tree = ast.parse(data, filename=member)
    nodes = ast.walk(tree) if nested else tree.body
    selected = [node for node in nodes if isinstance(node, (ast.ClassDef, ast.FunctionDef)) and node.name in names]
    if len(selected) != len(names) or {node.name for node in selected} != set(names):
        raise ValueError("Original-source oracle definitions are incomplete")
    # Execute only the unchanged, pinned numerical definitions. Module imports,
    # package initialization, and unrelated model classes are excluded.
    exec(compile(ast.Module(body=selected, type_ignores=[]), member, "exec"), namespace)


def read_floats(path, count):
    data = array.array("f")
    data.frombytes(path.read_bytes())
    if sys.byteorder != "little" or len(data) != count:
        raise ValueError("FP32 fixture layout differs")
    return data


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--site", required=True, type=pathlib.Path)
    parser.add_argument("--directory", required=True, type=pathlib.Path)
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[2]
    build = (root / "build").resolve()
    directory = args.directory.resolve()
    site = args.site.resolve()
    if not directory.is_relative_to(build) or not site.is_relative_to(build):
        raise ValueError("Oracle inputs must remain under this repository build directory")
    sys.path.insert(0, str(site))
    resolution = json.loads((directory / "resolution.json").read_text(encoding="utf-8"))
    verified_files = 0
    for package in resolution["install"]:
        distribution = importlib.metadata.distribution(package["metadata"]["name"])
        if distribution.version != package["metadata"]["version"]:
            raise ValueError("Installed oracle dependency version differs")
        for entry in distribution.files or ():
            path = pathlib.Path(distribution.locate_file(entry)).resolve()
            if not path.is_relative_to(site) or entry.hash is None:
                continue
            if entry.hash.mode != "sha256":
                raise ValueError("Oracle dependency uses an unadmitted digest")
            with path.open("rb") as stream:
                actual = base64.urlsafe_b64encode(hashlib.file_digest(stream, "sha256").digest()).decode().rstrip("=")
            if actual != entry.hash.value:
                raise ValueError("Installed oracle dependency integrity differs")
            verified_files += 1
    import torch
    import torch.nn as nn
    from torch.nn.utils.parametrizations import weight_norm

    manifest = json.loads((root / "lib/manifest.json").read_text(encoding="utf-8"))
    if manifest["kokoroSource"]["commit"] != "dfb907a02bba8152ca444717ca5d78747ccb4bec":
        raise ValueError("Kokoro original source revision differs")
    if torch.__version__ != manifest["pythonEnv"]["torch"]:
        raise ValueError("Torch oracle version differs from its repository pin")
    model_root = build / "inputs/kokoro" / manifest["model"]["revision"]
    for pin in manifest["model"]["files"]:
        if pin["path"] not in ("kokoro-v1_0.pth", "config.json", "voices\\af_heart.pt"):
            continue
        path = model_root / pin["path"].replace("\\", "/")
        if path.stat().st_size != pin["bytes"] or digest(path) != pin["sha256"]:
            raise ValueError("Stock input digest or length differs")
    checkpoint = torch.load(model_root / "kokoro-v1_0.pth", map_location="cpu", weights_only=True)
    voice = torch.load(model_root / "voices/af_heart.pt", map_location="cpu", weights_only=True)
    stock_config = json.loads((model_root / "config.json").read_text(encoding="utf-8"))
    torch.set_num_threads(1)
    torch.manual_seed(0)
    torch.use_deterministic_algorithms(True)
    namespace = dict(torch=torch, nn=nn, F=torch.nn.functional, math=math, weight_norm=weight_norm,
                     Optional=typing.Optional, Union=typing.Union, AlbertConfig=object)
    source_nodes(directory / "kokoro-source.zip", "kokoro/istftnet.py",
                 "f1c536e16e9d19986c599726e3b4d09813f250d1",
                 {"init_weights", "get_padding", "AdaIN1d", "AdaINResBlock1", "TorchSTFT"}, namespace)
    source_nodes(directory / "transformers-source.zip", "src/transformers/models/albert/modeling_albert.py",
                 "4cc129366baea19b78ab5e7335fa21c5a371326b", {"AlbertAttention"}, namespace)
    results = []
    diagnostics = []

    def compare(name, actual, expected_path, max_error=1e-4, min_snr=80, diagnostic=False):
        expected = torch.tensor(read_floats(expected_path, actual.numel()), dtype=torch.float32).reshape(actual.shape)
        error = actual.double() - expected.double()
        maximum = error.abs().max().item()
        noise = error.square().sum().item()
        signal = expected.double().square().sum().item()
        snr = 999.0 if noise == 0 else 10 * math.log10(max(signal, 1e-300) / noise)
        if diagnostic:
            diagnostics.append(dict(Name=name, Values=actual.numel(), MaxAbsError=maximum, SNRdB=snr,
                                    Scope="float64_original_source_precision_diagnostic"))
            return
        passed = bool(torch.isfinite(actual).all()) and maximum <= max_error and snr >= min_snr
        results.append(dict(Name=name, Values=actual.numel(), MaxAbsError=maximum, SNRdB=snr,
                            MaxAbsErrorLimit=max_error, MinimumSNRdB=min_snr, Passed=passed))

    with torch.inference_mode():
        qkv_dir = directory.parent / "fixtures/albert-qkv"
        qkv_manifest = json.loads((qkv_dir / "fixture.json").read_text())
        for key in ("Input", "Expected"):
            record = qkv_manifest[key]
            if digest(qkv_dir / record["Name"]) != record["SHA256"]:
                raise ValueError("ALBERT fixture hash differs")
        hidden = torch.tensor(read_floats(qkv_dir / "input.f32", 2304)).reshape(1, 3, 768)
        prefix = "module.encoder.albert_layer_groups.0.albert_layers.0.attention."
        state = {name[len(prefix):]: value for name, value in checkpoint["bert"].items() if name.startswith(prefix)}
        config = types.SimpleNamespace(hidden_size=768, num_attention_heads=12, attention_probs_dropout_prob=0,
                                       hidden_dropout_prob=0, layer_norm_eps=1e-12, position_embedding_type="absolute")
        attention = namespace["AlbertAttention"](config).eval()
        attention.load_state_dict(state, strict=True)
        q, k, v = [getattr(attention, name)(hidden) for name in ("query", "key", "value")]
        compare("albert_qkv_stock_linear", torch.cat((q, k, v), dim=-1), qkv_dir / "expected.f32")
        compare("albert_attention_stock_full", attention(hidden)[0], directory / "albert-attention.reference.f32")
        encoder_reference = directory / "albert-encoder.reference.f32"
        if encoder_reference.exists():
            if importlib.util.find_spec("kernels") is not None:
                raise ValueError("The oracle requires the stock no-kernels fallback")
            source_nodes(directory / "transformers-kernel-fallback.zip", "src/transformers/integrations/hub_kernels.py",
                         "6bf8dbcc021962b7ef8049ee52557286836219c3", {"use_kernel_forward_from_hub"}, namespace, nested=True)
            source_nodes(directory / "transformers-helpers.zip", "src/transformers/activations.py",
                         "7642e8aa238a6df701da95f0a58bef3156baf0e0", {"NewGELUActivation"}, namespace)
            namespace["inspect"] = inspect
            source_nodes(directory / "transformers-helpers.zip", "src/transformers/pytorch_utils.py",
                         "b1f41117d4cfeb5242a83197ea4e2b04b2d8e9a7", {"apply_chunking_to_forward"}, namespace)
            namespace["ACT2FN"] = {"gelu_new": namespace["NewGELUActivation"]()}
            namespace["ALBERT_ATTENTION_CLASSES"] = {"eager": namespace["AlbertAttention"]}
            source_nodes(directory / "transformers-source.zip", "src/transformers/models/albert/modeling_albert.py",
                         "4cc129366baea19b78ab5e7335fa21c5a371326b",
                         {"AlbertEmbeddings", "AlbertLayer", "AlbertLayerGroup", "AlbertTransformer"}, namespace)
            config = types.SimpleNamespace(**vars(config), embedding_size=128, vocab_size=178,
                                           pad_token_id=0, max_position_embeddings=512, type_vocab_size=2,
                                           chunk_size_feed_forward=0, intermediate_size=2048,
                                           _attn_implementation="eager", hidden_act="gelu_new",
                                           num_hidden_groups=1, num_hidden_layers=12, inner_group_num=1)
            embeddings = namespace["AlbertEmbeddings"](config).eval()
            encoder = namespace["AlbertTransformer"](config).eval()
            for module, prefix in ((embeddings, "module.embeddings."), (encoder, "module.encoder.")):
                state = {name[len(prefix):]: value for name, value in checkpoint["bert"].items() if name.startswith(prefix)}
                module.load_state_dict(state, strict=True)
            encoded = encoder(embeddings(torch.tensor([[0, 43, 0]])), return_dict=False)[0]
            compare("albert_encoder_stock_12_repeats", encoded, encoder_reference)

        block = namespace["AdaINResBlock1"](128, kernel_size=3, dilation=(1, 3, 5), style_dim=128).eval()
        prefix = "module.generator.resblocks.3."
        state = {name[len(prefix):]: value for name, value in checkpoint["decoder"].items() if name.startswith(prefix)}
        loaded = block.load_state_dict(state, strict=False)
        missing = {f"adain{side}.{index}.norm.{suffix}" for side in (1, 2) for index in range(3) for suffix in ("weight", "bias")}
        if set(loaded.missing_keys) != missing or loaded.unexpected_keys:
            raise ValueError("Original residual block stock state differs")
        style = voice[6].reshape(1, 256)[:, :128]
        for frames in (8, 16, 64):
            base = directory / f"adain-{frames}"
            x = torch.tensor(read_floats(base.with_suffix(".input.f32"), 128 * frames)).reshape(1, 128, frames)
            compare(f"adain_resblock_stock_{frames}", block(x, style), base.with_suffix(".reference.f32"))
        for frames in (8, 16):
            historical = directory / f"r0-{frames}"
            if not historical.exists():
                continue
            x = torch.tensor(read_floats(historical / "in_z.f32", 128 * frames)).reshape(1, 128, frames)
            zero_style = torch.tensor(read_floats(historical / "in_style.f32", 128)).reshape(1, 128)
            compare(f"adain_r0_historical_fixture_{frames}", block(x, zero_style), historical / "oracle_r0.f32")
        spectral = namespace["TorchSTFT"](filter_length=20, hop_length=5, win_length=20)
        for length in (40, 41, 45):
            prefix = directory / f"stft-{length}"
            if not prefix.with_suffix(".input.f32").exists():
                continue
            signal = torch.tensor(read_floats(prefix.with_suffix(".input.f32"), length)).reshape(1, length)
            magnitude, phase = spectral.transform(signal)
            compare(f"stft_real_{length}", magnitude * torch.cos(phase), prefix.with_suffix(".real.f32"))
            compare(f"stft_imaginary_{length}", magnitude * torch.sin(phase), prefix.with_suffix(".imaginary.f32"))
            inverse = spectral.inverse(magnitude, phase)
            compare(f"stft_roundtrip_{length}", inverse, prefix.with_suffix(".inverse.f32"))
            count = magnitude.numel()
            prepared_magnitude = torch.tensor(read_floats(prefix.with_suffix(".magnitude.f32"), count)).reshape(magnitude.shape)
            prepared_phase = torch.tensor(read_floats(prefix.with_suffix(".phase.f32"), count)).reshape(phase.shape)
            compare(f"istft_same_spectrum_{length}", spectral.inverse(prepared_magnitude, prepared_phase), prefix.with_suffix(".inverse.f32"))
        if (directory / "decoder.core.f32").exists():
            class GeneratorBoundary(nn.Module):
                """Observe the decoder's output before the untested generator."""
                def __init__(self, *args, **kwargs):
                    super().__init__()

                def forward(self, features, style, f0):
                    return features

            namespace["Generator"] = GeneratorBoundary
            source_nodes(directory / "kokoro-source.zip", "kokoro/istftnet.py",
                         "f1c536e16e9d19986c599726e3b4d09813f250d1",
                         {"UpSample1d", "AdainResBlk1d", "Decoder"}, namespace)
            decoder = namespace["Decoder"](dim_in=stock_config["hidden_dim"], style_dim=stock_config["style_dim"],
                                            dim_out=stock_config["n_mels"], **stock_config["istftnet"]).eval()
            state = {name[len("module."):]: value for name, value in checkpoint["decoder"].items()
                     if name.startswith("module.") and not name.startswith("module.generator.")}
            loaded = decoder.load_state_dict(state, strict=False)
            blocks = ["encode"] + [f"decode.{index}" for index in range(4)]
            missing = {f"{prefix}.norm{norm}.norm.{suffix}" for prefix in blocks for norm in (1, 2) for suffix in ("weight", "bias")}
            if set(loaded.missing_keys) != missing or loaded.unexpected_keys:
                raise ValueError("Original decoder boundary stock state differs")
            text = torch.tensor(read_floats(directory / "decoder.text.f32", 1024)).reshape(1, 512, 2)
            f0 = torch.tensor(read_floats(directory / "decoder.f0.f32", 4)).reshape(1, 4)
            noise = torch.tensor(read_floats(directory / "decoder.noise.f32", 4)).reshape(1, 4)
            encoded_input = torch.cat((text, decoder.F0_conv(f0.unsqueeze(1)), decoder.N_conv(noise.unsqueeze(1))), dim=1)
            compare("decoder_prelude_stock_encode", encoded_input, directory / "decoder.encode.f32")
            compare("decoder_prelude_stock_asr", decoder.asr_res(text), directory / "decoder.asr.f32")
            propagated = {}
            observed = [("encode", decoder.encode)] + [(f"decode-{index}", decoder.decode[index]) for index in range(4)]
            hooks = [module.register_forward_hook(
                lambda module, inputs, output, label=name: propagated.update({label: output.detach().clone()})
            ) for name, module in observed]
            try:
                compare("decoder_core_stock_before_generator", decoder(text, f0, noise, style), directory / "decoder.core.f32")
            finally:
                for hook in hooks:
                    hook.remove()
            trace = directory / "decoder-trace"
            if trace.exists():
                for name, _ in observed:
                    compare(f"decoder_propagated_{name}", propagated[name], trace / f"{name}-output.f32")
                for name, module, channels in [("encode", decoder.encode, 514)] + [
                        (f"decode-{index}", decoder.decode[index], 1090) for index in range(4)]:
                    prepared = torch.tensor(read_floats(trace / f"{name}-input.f32", channels * 2)).reshape(1, channels, 2)
                    compare(f"decoder_same_input_{name}", module(prepared, style), trace / f"{name}-output.f32")
                decoder.double()
                compare("decoder_connected_float64", decoder(text.double(), f0.double(), noise.double(), style.double()),
                        directory / "decoder.core.f32", diagnostic=True)
                for name, module, channels in [("encode", decoder.encode, 514)] + [
                        (f"decode-{index}", decoder.decode[index], 1090) for index in range(4)]:
                    prepared = torch.tensor(read_floats(trace / f"{name}-input.f32", channels * 2), dtype=torch.float64).reshape(1, channels, 2)
                    compare(f"decoder_same_input_float64_{name}", module(prepared, style.double()),
                            trace / f"{name}-output.f32", diagnostic=True)
    receipt = dict(Schema=1, Scope="bounded_original_source_torch_differential", Passed=all(r["Passed"] for r in results),
                   TorchVersion=torch.__version__, TorchSourceCommit=torch.version.git_version,
                   PythonVersion=sys.version.split()[0], DeviceExecuted=False, FullModelVerified=False, Gates=results)
    receipt["DependencyLockSHA256"] = digest(directory / "requirements.txt")
    receipt["VerifiedDependencyFiles"] = verified_files
    receipt["KokoroSourceCommit"] = manifest["kokoroSource"]["commit"]
    receipt["TransformersSourceCommit"] = "8ac2b916b042b1f78b75c9eb941c0f5d2cdd8e10"
    receipt["ModelRevision"] = manifest["model"]["revision"]
    receipt["CheckpointSHA256"] = digest(model_root / "kokoro-v1_0.pth")
    receipt["VoiceSHA256"] = digest(model_root / "voices/af_heart.pt")
    receipt["ConfigSHA256"] = digest(model_root / "config.json")
    receipt["OracleScriptSHA256"] = digest(pathlib.Path(__file__).resolve())
    receipt["VoiceRow"] = 6
    receipt["DecoderStyleHalf"] = "first_128"
    receipt["PrecisionDiagnostics"] = diagnostics
    native_sources = directory / "native-source/sources.json"
    if native_sources.exists():
        records = json.loads(native_sources.read_text(encoding="utf-8-sig"))
        for record in records:
            path = directory / "native-source" / pathlib.PurePosixPath(record["Path"]).name
            if record["Commit"] != torch.version.git_version or digest(path) != record["SHA256"]:
                raise ValueError("Native Torch source provenance differs")
        receipt["NativeSourceContracts"] = records
    target = directory / "torch-differential.json"
    if target.exists():
        raise ValueError("Oracle receipt already exists")
    target.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: receipt[k] for k in ("Passed", "TorchVersion", "DeviceExecuted", "FullModelVerified")}))
    if not receipt["Passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
