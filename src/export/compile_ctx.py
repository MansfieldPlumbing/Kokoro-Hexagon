# Offline QNN HTP context generation (QAIRT 2.46 via onnxruntime-qnn 2.2.0) for SM8550 / V73.
import sys, os, hashlib, pathlib, onnxruntime as ort, onnxruntime_qnn as oq
src = pathlib.Path(sys.argv[1]); tag = os.environ.get('QNN_TAG', ''); out = src.with_name(src.stem + tag + '_ctx.onnx')
for old in src.parent.glob(src.stem + tag + '_ctx*'): old.unlink()          # scratchpad artifacts from a previous compile
ort.register_execution_provider_library(oq.get_ep_name(), oq.get_library_path())
devs = [d for d in ort.get_ep_devices() if d.ep_name == oq.get_ep_name()]
print('ep devices:', [(d.ep_name, str(d.device.type)) for d in devs])
so = ort.SessionOptions()
if os.environ.get('QNN_VERBOSE'): so.log_severity_level = 0; ort.set_default_logger_severity(0)
so.add_session_config_entry('session.disable_cpu_ep_fallback', '1')
so.add_session_config_entry('ep.context_enable', '1')
so.add_session_config_entry('ep.context_embed_mode', '0')
so.add_session_config_entry('ep.context_file_path', str(out))
so.add_provider_for_devices(devs, {
    'backend_path': oq.get_qnn_htp_path() if hasattr(oq, 'get_qnn_htp_path') else 'QnnHtp.dll',
    'htp_arch': '73', 'soc_model': '43',
    'enable_htp_fp16_precision': os.environ.get('QNN_FP16', '1'), **({'vtcm_mb': os.environ['QNN_VTCM_MB']} if os.environ.get('QNN_VTCM_MB') else {}), **({'dump_json_qnn_graph': '1', 'json_qnn_graph_dir': os.environ['QNN_JSON_DIR']} if os.environ.get('QNN_JSON_DIR') else {}), **({'profiling_level': os.environ['QNN_PROFILE'], 'profiling_file_path': str(src.with_name(src.stem + '_compile_profile.csv'))} if os.environ.get('QNN_PROFILE') else {}), 'htp_graph_finalization_optimization_mode': '3',
})
try:
    ort.InferenceSession(str(src), so)
    print('SESSION_CREATED=True')
except Exception as e:
    print('SESSION_CREATED=False'); print('ERROR=' + str(e)[:1500]); sys.exit(1)
for f in sorted(src.parent.glob(src.stem + tag + '_ctx*')):
    print(f.name, f.stat().st_size, hashlib.sha256(f.read_bytes()).hexdigest().upper())
