# Live AdaIN groundwork: sites, style, training scope, per-token generator levels (2026-11-14)

Branch `live-adain` from Kokoro-Hexagon `679224d`. Host only; no phone. The information tasks of
`docs/fable-codex-tasks-live-adain-20261113.md` (tasks 1 to 4), done ahead of Stage A and Stage B of
`docs/fable-opus-brief-live-adain-20261113.md`. Receipt: `build/live-adain-20261114/` (scripts, CSVs, the emitted
layout, `manifest.csv` of SHA-256s).

## The host port did not compile

`tools/Invoke-KokoroPrecomputedDecoder.ps1` at `679224d` stops before loading: the pinned lowering compiler (PSC
`bb0f67a`, `Export-LoweredAssembly.ps1`) lowers every class in the file, and `OfflineTokenSequenceComparer` (added in
`0b515d1`) implements `IEqualityComparer[int[]]`; only classes deriving from `System.Object` are admitted. Every mode
that compiles the numeric kernels failed from that commit on.

Fixed on this branch:

- The comparer is replaced by `OfflineTokenSequence`, a value class: it keeps its own copy of the tokens, compares whole
  sequences (a hash collision cannot match) and overrides `Equals` and `GetHashCode`. The pinned compiler lowers it, its
  assembly references `System.Private.CoreLib` only, and a dictionary finds an equal sequence and not an unequal one
  (checked on a minimal source before the edit).
- `Invoke-OfflineGenerator` called from Library mode failed under the port's strict mode: three residual diagnostics
  were set only inside `Invoke-OfflineSpeech`. They are now initialized with the other script state.
- `Verify`'s case-pair check failed at `679224d` on this file (`name`/`Name`, from the voice-pin loop added in
  `0b515d1`); the loop variable is renamed. `Verify` now passes every check except `handoff`
  (`handoff-20261101.md has no next steps`), which this branch does not touch.

Not rerun here: the nine-case reference suite and Speech mode with `-ReuseText` (the path the key serves), and the
decoder's `Levels` gate, whose stock captures (`build/score-capture-20261014`) are not on this machine.

## Task 1: every AdaIN site

`adain-sites.csv`: 58 sites. The generator rows are read from the emitted depth-first layout (library `2B11F4C1...`,
130 ticks, kept settings: 256-channel main section Chunked, the other three sections Backward) and the backward
geometry in `src/jobs/Kokoro.Generator60x16Run.ps1`; the decoder rows are inferred from the delayed layout's comments
in `src/jobs/Kokoro.DecoderRun16.ps1` and marked so.

- **Clocks.** Decoder sites run at the frame rate (2 ticks), except `decode.3.norm2` at the tick rate. The 256-channel
  sections run at 10 rows per tick. The 128-channel sections run at 60 rows per tick after the one-row left reflection
  pad, so tick k begins at row 60k + 1.
- **Lag in the depth-first schedule.** Stage st of a branch with kernel K reads, at row R, position R - lag, with
  lag = 32p for adain1 of pair p and 32p + (1 + 2p)(K - 1)/2 for adain2. Every adain2 site therefore sits 1 to 25
  rows inside a tile (1, 3, 5, 9, 15 or 25), and text positions fall mid-tile at every site (every 10 or 60 rows).
- **Load point today.** Every site's K/M/S is loaded once per job: generator from `HostCoefficientsOffset + KmOffset`
  in `$stageSetup`, decoder from `Input.KmDeltas + KmOffset` in Direct mode.
- **The existing controller contact** (`-ControllerContact`, `083ce30`): one 128-channel section, a per-tile rank-1
  term `K = K_base + P_K v`. Each stage reads the word of tile `w - p` for both halves of pair p, so at adain2 sites the
  word is applied r1 = (1 + 2p)(K - 1)/2 rows off its position (column `ContactLagRowsError`). Its proof compares
  outside an 8-tile margin, which hides the offset.

## Task 4: style moves with the voice row

Stock takes the style from `pack[len(phonemes) - 1]`: the whole utterance's phoneme count. For three voices, 19 rows
from 1 to 510, every site's `1 + gamma` and `beta` from the port's own `ApplyLevels` (`style-by-length.csv`). Gain
change per channel about its mean over rows, RMS over channels and rows; offset in units of the channel's mean gain:

| Voice | Decoder (10 sites) | Generator main (36) | Source sections (12) | Offset RMS, decoder / main / source |
| --- | ---: | ---: | ---: | --- |
| af_heart | 2.49 dB | 1.06 dB | 3.23 dB | 0.51 / 0.28 / 0.75 |
| am_michael | 2.52 dB | 1.20 dB | 3.45 dB | 0.46 / 0.23 / 0.57 |
| bm_daniel | 2.23 dB | 1.20 dB | 2.92 dB | 0.31 / 0.18 / 0.66 |

Rows 50 to 400 alone give nearly the same: 2.1 to 2.3, 0.9 to 1.1 and 2.5 to 3.1 dB. The largest single-channel figures
(up to 140 dB) are channels whose gain crosses zero between rows; they are an artifact of measuring in dB.

The style row moves a site's gain as much as or more than the moments move between streams (0.33 to 0.96 dB,
`generator-normalization-sm8550-20261026.md`). Style is a second utterance-level dependency. The DSP folds style and
moments into one K/M per channel, so a transport for K/M/S carries both.

## Task 3: what scope the network was trained on

- `AdaIN1d` in the pinned source (`istftnet.py`, `dfb907a`) is `InstanceNorm1d(num_features, affine=True)`; the source
  comment says affine should be False and is True only for an old ONNX export bug. No running statistics are tracked:
  stock normalizes only by each input's own moments.
- StyleTTS2's public training (`yl4579/StyleTTS2`, `train_second.py`, `Configs/config.yml`) runs the decoder, and with
  it every AdaIN site, on a random crop of `min(shortest utterance in the batch, max_len // 2)` decoder frames from a
  random start; `max_len` is 400 mel frames at hop 300 and 24 kHz, so the crop is at most 200 decoder frames, 5.0 s.
  The style encoders see the whole utterance.
- Kokoro-82M's own training configuration is not published (model card: StyleTTS2 and ISTFTNet, a few hundred hours
  for v1.0). That it used the same crop is not established.

So in StyleTTS2 training each AdaIN site normalized over a window of at most 5 s at a random position, never a whole
long utterance. Whole-utterance moments at inference are not what that training saw.

## Task 2: per-token generator levels in the host port

The decoder's `Levels` path (Live: per-token sums and sums of squares per channel, `MeasureLevels`; Supplied: replay)
now covers the generator's 48 sites:

- `OfflineLevelContext` (a class) names the part it covers, so a decoder context records only decoder sites and a
  generator context only generator sites.
- One rule gives every site's rows per token, `Get-OfflineSiteTokenFrames`: the site's rows per decoder frame times
  each duration (1 or 2 in the decoder, 20 or 120 in the generator); a site with one more row (the 128-channel sites'
  reflection pad) gives it to the first token. The decoder's rows per token are unchanged.
- `Invoke-OfflineGenerator -TokenDurations [-LevelMode] [-SuppliedLevels] [-LevelRecords]`; without `-TokenDurations`
  it is unchanged. With them each site normalizes by the measured levels' mean and variance, as the decoder's Levels
  path does, which is not bit-identical to the plain path's float accumulation.

**Control** (`generator-level-control.csv`), three cached `af_heart` syllabus windows of 196 to 292 ticks:

| Window | Tokens | Ticks | Replay bit-exact | Token sums against totals | One-ulp mean flip changes PCM |
| --- | ---: | ---: | --- | ---: | --- |
| `033CE485` | 43 | 270 | yes | 0 | yes |
| `052C98ED` | 63 | 292 | yes | 0 | yes |
| `058FE89E` | 40 | 196 | yes | 0 | yes |

All 48 sites recorded in each. 3.3 to 6.4 s per Live render with 8 threads. The cache holds 2,720 windows with
phonemes, durations, F0, N and x; the decoder's input (asr) is not cached, so decoder levels need the front end rerun.

## What this changes in the brief

- **Stage A** needs coefficient changes at any row, not at tile edges: adain2 sites lag mid-tile, and text positions
  fall every 10 or 60 rows. The existing contact's adain2 offset is a defect for exact position semantics.
- **Stage A's stream carries K/M/S**, which already combine style and moments, so style streams with no extra mechanism.
- **Stage B** has its data source: generator per-token levels from the cached windows, measured in the host port. It
  should hold the style row fixed, since the row alone moves gains by about 1 dB in the main sections.
- **Scope:** if Kokoro trained like StyleTTS2, scopes of a few seconds are what the network saw; a scope arm (exact
  moments of breath groups or 5 s windows against the whole utterance) is worth its place in Stage B.
