# VTCM-aware graph tiling

Recorded 2026-10-10 at Scott's request. Deferred design direction; the seven-step
order in `handoff-20261010.md` still governs implementation. Kokoro is the proving
ground for a general capability shared with PSLowering and the DSP execution system.

## Execution model

Complete utterance -> phonemes and full-context acoustic controls -> decoder and
generator graph -> VTCM-aware tile planner -> bounded execution chunks -> contiguous
PCM stream.

Tile the computation. Linguistic words and groups inform acoustic controls;
execution boundaries may occur inside a word. Tiles describe work, and chunks
deliver that work. The listener should not hear DSP job boundaries.

The planner may tile time, channels, convolution windows and intermediate buffers.
Choose dimensions and extents from the graph's dependencies, live-buffer footprint,
alignment constraints and the runtime's reported VTCM capacity. Schedule transfers
between DDR and VTCM, reuse dead buffers and overlap DMA with computation where
dependencies permit. A long utterance must not require all its activations to be
resident simultaneously.

## Semantic invariants

Changing tile size must preserve the mathematical operation being computed.

- Convolutions retain their receptive-field context across adjacent tiles, including
  required lookahead. Context halos do not imply duplicated published audio.
- Channel/reduction tiling retains all contributions and the required accumulation
  and rounding order. Exact integer behavior remains an operator contract.
- AdaIN coefficients remain coherent across tiles. Full-context coefficients,
  learned controls and global-normalization approximations have distinct measured
  error; changing execution tile size must not silently change normalization scope.
- Harmonic generation carries continuous phase and deterministic noise state.
- STFT/iSTFT retains its native windows and overlap-add state. This is separate from
  an arbitrary 400 ms PCM crossfade.
- Every output sample has exactly one owner. Publishing tiles creates no gaps,
  duplicated PCM or inserted pauses.

Keep persistent state and output publication transactional across resource-admission
failure: retrying an uncommitted tile must not consume randomness twice, advance
phase twice or replay audio.

## Memory planning and fallback

Predict peak VTCM bytes from simultaneously live tensors, weights, DMA buffers,
scratch, alignment and HMX page constraints. Query capacity at setup and verify the
actual resource grant. Emit the predicted peak, capacity, selected tile dimensions
and buffer lifetimes into the receipt.

On allocation failure, select a smaller valid plan with a bounded retry. Reduce
internal working sets or change tiled dimensions before changing the linguistic
controls. If the fixed working set still does not fit, report the limiting buffers
and use a checked DDR-streamed schedule. The resource planner should make the
8,650,752-byte request on an 8,388,608-byte grant impossible to dispatch unchanged.

## Acceptance benchmark

Use the same utterance, linguistic context, acoustic controls, voice-style row and
randomness for an uninterrupted reference and progressively smaller execution tiles.
Vary time, channel and window tiles as supported; 96-, 32- and 8-frame jobs and
single-word-sized jobs are useful stress cases, not the definition of the tiling API.

For deterministic operators, exact PCM parity is the target. Report full-output
hashes, sample counts, PCM error, error around tile boundaries and listening, alongside
peak VTCM/DDR, transfer volume, DSP time and time to first audio. Measure quantization,
normalization approximations and learned-control error separately from tiling error.
Keep SM8550 and SM8635 receipts separate and identify the executed artifacts.

## Starting evidence

`results/vtcm-capacity-20261007.md` records the runtime capacity probe: 8 MiB on
SM8550 and 4 MiB on SM8635. The first bank-front-end sentence has 85 decoder frames:
the existing resident job needs 8,650,752 VTCM bytes at 22 convolution batch tiles and
8,126,464 bytes at 14. The first plan stopped at resource acquisition and published
no audio. The second plan's result belongs in `results/bank-front-end-sm8550-20261010.md`.
This establishes a concrete planning regression case, not general tiled execution.
