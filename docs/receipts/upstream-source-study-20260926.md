# Upstream source study inventory — 2026-09-26

These are complete top-level source trees under `C:\Dev\.vendor`, checked out
at the immutable commits below with shallow history. They are read-only study
material. No source or output from these trees was added to the APK, model
assembly, build inputs, or production runtime.

| Tree | Upstream | Commit | Study role |
| --- | --- | --- | --- |
| `pytorch` | `https://github.com/pytorch/pytorch.git` | `2b3ec34829036a65cd9d1398ea72a0167dc37470` | Torch 2.14.0 operator and module semantics; matches the version named in `lib/manifest.json` |
| `transformers` | `https://github.com/huggingface/transformers.git` | `8ac2b916b042b1f78b75c9eb941c0f5d2cdd8e10` | ALBERT and English G2P BART implementation; v4.57.0 study snapshot |
| `numpy` | `https://github.com/numpy/numpy.git` | `a98529dfd92d73fd4d40ebaaf285cf2463bb92b1` | Numerical behavior used by stock STFT construction |
| `spacy` | `https://github.com/explosion/spaCy.git` | `26b4d1dc04a812f426e4bef3e8a1b6f159d6f048` | Misaki English tokenization and linguistic pipeline |
| `num2words` | `https://github.com/savoirfairelinux/num2words.git` | `07814cb114157f582c40a00119c2e9faba8dcee2` | Misaki English number expansion |
| `regex` | `https://github.com/mrabarnett/mrab-regex.git` | `85e568c0e0be620b4ebe50c98ea92415f5995ffc` | Misaki Unicode token splitting |
| `phonemizer` | `https://github.com/bootphon/phonemizer.git` | `ab8e780b302adb4e18f06350db3bc7f4564182c8` | Misaki eSpeak fallback wrapper |
| `espeak-ng` | `https://github.com/espeak-ng/espeak-ng.git` | `ba90c8e9f440ad544f674a790bb5f53878b6ffc5` | Pronunciation engine source and data format |
| `espeakng-loader` | `https://github.com/thewh1teagle/espeakng-loader.git` | `0ddc87adf77e5850d7eeb542ac8a87d421b64daa` | Misaki's eSpeak library/data discovery |
| `spacy-curated-transformers` | `https://github.com/explosion/spacy-curated-transformers.git` | `fe55b96afa1ec86a245c92095cf6559478b159a1` | Misaki English spaCy pipeline configuration |
| `aosp-frameworks-av` | `https://android.googlesource.com/platform/frameworks/av` | `e2f098935447ca4945946de5cb69db843fe3f003` (checkout); `9e7dd63dfff0cc967f025ea9e27a299aaa99fd69` (pinned study commit) | Android AAudio implementation and PCM sink contract |

The already mirrored canonical model sources remain `kokoro` at
`dfb907a02bba8152ca444717ca5d78747ccb4bec` and `misaki` at
`fba1236595f2d2bf21d414ba6e57d25256afada3`. The new snapshots were
selected for source study; except for the Torch version, they are **not yet
asserted to match a version-locked numerical oracle environment**. Before a
parity claim depends on a framework implementation detail, pin the exact
oracle package version and trace that version's source. Historical StyleTTS2,
ONNX, QNN, and LLVM sources are not substitutes for the pinned Kokoro model.

The source chain is visible in `kokoro/kokoro/model.py` (ALBERT and model
assembly), `kokoro/kokoro/modules.py` (`CustomAlbert` derives from upstream
`AlbertModel`), `kokoro/kokoro/istftnet.py` (decoder), and
`misaki/misaki/en.py` (English text path). Their original repositories are
the behavioral source; the listed dependency trees explain referenced
operators and algorithms only.

Submodule completeness is separate from the top-level source pins. NumPy's
seven declared submodules were fetched at their recorded Git links. PyTorch's
top-level tree is clean and all 37 submodule directories were acquired, but
only 15 matched their recorded Git links on the last check. A checkout conflict
in `third_party/cutlass` stopped completion; no forced overwrite or cleanup was
performed. Treat those submodule working trees as incomplete until separately
verified. The top-level PyTorch operator source needed for the current study
remains available at the pinned commit through `git show`.

The PCM boundary is two distinct contracts: Kokoro's decoder and `CustomSTFT`
define the generated waveform, while Android AAudio accepts a stream of
24 kHz mono float samples. The repository has a physical AAudio smoke receipt,
but that did not execute the complete stock model. `aosp-frameworks-av` is
study source only; no AAudio source was copied into the APK. The previously
pinned AAudio commit and header blob are available as Git objects in that
mirror and should be read with `git show` without changing its checkout.
