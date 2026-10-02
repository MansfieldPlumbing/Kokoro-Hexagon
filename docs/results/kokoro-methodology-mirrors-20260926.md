# Kokoro methodology study mirrors — 2026-09-26

The supplied comparative report was used only to identify repositories worth
examining. Its performance rankings, latency, footprint, and power figures
are not accepted as cross-system benchmarks: they lack a common model/input,
hardware, warm-up, timing boundary, and measurement protocol.

The following independent trees were cloned to `C:\Dev\.vendor` at the
immutable commits shown. Inspect with `git show <commit>:<path>` or the shared
search index; do not treat their working trees as Kokoro build inputs. No code,
weights, generated models, or binaries from these trees were copied into this
repository or its production closure.

| Mirror | Upstream | Commit | Methodology question |
| --- | --- | --- | --- |
| `Kokoro-FastAPI` | `https://github.com/remsky/Kokoro-FastAPI.git` | `b4ef64b1ce60682debda4fe0a066259e284eb1b4` | How are long requests segmented, queued, and delivered to playback? |
| `kokoro-mlx` | `https://github.com/gabrimatic/kokoro-mlx.git` | `78e0f87eb3f5105a451bb485a46d01a36364358e` | How is the stock graph scheduled against shared memory? |
| `kokoro.cpp` | `https://github.com/simonfxr/kokoro.cpp.git` | `a9e31430838c8bdc3d4beaaab62753681b9f7839` | How are weights mapped and intermediate tensors reused? |
| `kokoro-server` | `https://github.com/marty1885/kokoro-server.git` | `952be751c3c4ee325a8049fa931eae037ef55f3b` | Which operator boundaries are measured on a constrained accelerator? |
| `sherpa-onnx` | `https://github.com/k2-fsa/sherpa-onnx.git` | `040afe360a38e25daaa325ce8889abf93ea02609` | How are embedded TTS requests, cancellation, and audio chunks bounded? |
| `kokoro-onnx` | `https://github.com/thewh1teagle/kokoro-onnx.git` | `3596b26764286a7de9d90c363e988d50578918e5` | Which tensor shapes and model variants need independent parity checks? |
| `kokoro-ios` | `https://github.com/mlalma/kokoro-ios.git` | `4d6d1d8ff8cd012014180c9cd4cf0151e7682354` | How is device playback coordinated with synthesis? |
| `Kokoros` | `https://github.com/lucasjinreal/Kokoros.git` | `29e99ad5a5aa64b97e1e8e963e6d73b0267d796a` | How is first-audio latency separated from sustained throughput? |

These are questions to investigate, not verified findings or implementation
instructions. The original pinned Kokoro source, checkpoint, and config remain
the only model-behavior authority. PowerShell-authored lowering and direct
Hexagon emission remain the independent product path.
