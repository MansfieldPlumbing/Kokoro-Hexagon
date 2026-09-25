# Host receipt: predicted generator AdaIN statistics for the Kokoro decoder

Date: 2026-09-25
Target: host CPU only (cloud container, 4 threads). No device, no Hexagon; nothing here
is a device capability claim.
Script: `src/export/norm_calibration.py` (reuses the model, statistics code path, SineGen
sharing and metrics of `src/export/causal_norm.py`; regenerates every number and, with
`--wav`, every holdout WAV).
Follows: `docs/receipts/causal-norm-host-20260925.md`.
Model: Kokoro-82M at `f3ff3571791e39611d31c381e3a41a3af07b4987`; `kokoro-v1_0.pth`,
`config.json` and `voices/af_heart.pt` match `lib/manifest.json` byte for byte
(`496DBA11…`, `5ABB01E2…`, `0AB5709B…`).
Stack: `kokoro` 0.9.4 (manifest pin), torch 2.14.0+cpu (manifest pin), numpy 2.4.6,
scipy 1.17.1, Python 3.11.15 (manifest names 3.14), `misaki` 0.9.4 with spaCy 3.8.16 and
`en_core_web_sm` 3.8.0 (not in the manifest; see Deviations). Wall time 2171 s.

## Question

Can per-channel whole-phrase statistics for every generator AdaIN layer (48 norms: 12
`noise_res`, 18 in stage 1, 18 in stage 2) be supplied from features known before the first
generator sample, at ≤ 1 dB log-mel from the whole-phrase reference? The gate: overall holdout
mean ≤ 1.0 dB log-mel and every length-bucket mean ≤ 1.5 dB.

Stage numbering here is 1-based: stage 1 is resblocks 0–2 at 800 Hz (PR #1's "stage 0",
`gen0`), and stage 2 is resblocks 3–5 at 4800 Hz (PR #1's "stage 1", `gen1`).

## Verdict

**The gate as written fails, and the only failure is the < 1 s bucket, which holds a single
non-lexical item.** The best predictor is ridge regression from the scalar features plus 32 PCA
components of the decoder-front output moments (`ridge+pca`):

- Overall holdout mean 0.59 dB log-mel (gate ≤ 1.0): pass.
- 1–2.5 s 0.62, 2.5–5 s 0.58, > 5 s 0.48 dB (gate ≤ 1.5 each): pass. The worst
  lexical phrase is 0.93 dB.
- < 1 s: 2.31 dB (gate ≤ 1.5): fail. This bucket contains one phrase, `breath-h` (`h…`,
  0.57 s, 91 % silence tokens) from `bench/paralinguistic.json`. No lexical utterance in the
  corpus is shorter than 1.2 s (see Corpus).
- The named short utterances are in the holdout and pass: "Hello." 0.31 dB, "Yes." 0.80 dB,
  "Okay, thanks." 0.53 dB, against a SineGen reseed floor of 0.20–0.25 dB.

Over the 61 lexical holdout phrases (1.25–9.97 s), `ridge+pca` averages 0.56 dB and never
exceeds 0.93 dB. For comparison, PR #1's fixed statistics gave 3.5 dB and 10.7 dB on "hello".
Mean waveform SNR is 18.2 dB, against a 22.1 dB reseed floor.

The other predictors fail:

- Fixed statistics: 4.18 dB, and 7.34 dB in the 1–2.5 s bucket.
- Two-class mixture: 2.49 dB.
- Ridge on scalar features only: 1.14 dB overall; the bucket means (0.91–1.26 dB) pass, but
  the overall mean does not.
- Deterministic moment propagation (predictor 4): non-finite output on all 62 holdout
  phrases.

This is a metric result on the host. Nobody has listened to the WAVs, and no device run has
been done. The payload is 73,728 bytes per phrase in fp32 or 36,864 in fp16. Supplying the
exact statistics through the fp16 payload costs 0.011 dB log-mel at most (48.6 dB waveform
SNR minimum).

## Method

- **Inputs.** Per phrase, one `forward_with_tokens` (seed 0) captures `asr`, `F0`, `N`,
  the style vector and per-token durations. `SineGen` runs once per phrase (seed 0), and the
  same `har_source` feeds every run. This is the `causal_norm.py` `prepare`/`run` path, unchanged.
- **Front.** `encode`/`decode` use the original `InstanceNorm1d` (exact whole-phrase
  statistics). The 48 generator AdaINs run through `causal_norm.py`'s replacement path in
  mode `given`: supplied per-channel (mean, var) in float64. Predictors emit (mean, log std),
  and var = exp(2 · log std).
- **Reference statistics.** Per-channel whole-phrase mean and biased variance of every
  generator AdaIN input in the reference run, in float64, two-pass. That is 9216 channels:
  6144 at 256 channels (noise_res 0, stage 1) and 3072 at 128 (noise_res 1, stage 2).
- **Features.** All are computed before the first generator sample:
  - frames T and log T
  - silence fraction: frames on the boundary pad and the punctuation tokens `;:,.!?—…"()“”`
    (vocab ids 0–15; spaces excluded), from the duration predictor
  - voiced fraction (F0 > 10 Hz, the SineGen threshold)
  - log-F0 mean and std over voiced frames
  - N mean and std
  - for `ridge+pca`, the per-channel mean and log std of the decoder-front output (512
    channels, so 1024 values), standardized and reduced by PCA fitted on train only
- **Predictors**, fitted on the 246 train phrases only:
  0. `fixed`: frame-pooled mean and E[x²] over train. This is `causal_norm.py`'s `fixed`.
  1. `mixture`: per layer and channel, frame-pooled first and second moments over speech
     frames and over silence frames (the token mask repeated to each layer's rate), mixed by the
     phrase's silence fraction. Closed form.
  2. `ridge`: multi-output ridge on the 8 standardized scalar features.
  3. `ridge+pca`: the same plus k PCA scores.
  4. `moments`: no fitting. The exact whole-phrase moments of the generator inputs (front
     output, 512 channels; the 22 STFT channels of the harmonic source that feed `noise_convs`)
     are propagated per channel:
     - `Conv1d`: mean ΣW·m + b and variance ΣW²·v, assuming channel and sample independence
       (stride, dilation and padding ignored).
     - `ConvTranspose1d`: the same per output phase, then pooled as mean of phase means, and
       mean of phase variances plus the variance of the phase means.
     - Leaky ReLU (slope 0.1, before each upsample): Gaussian closed form.
     - Snake x + sin²(ax)/a: E[sin²(aX)] = (1 − e^(−2a²v)·cos 2am)/2, with the variance from
       E[sin⁴] and Cov(X, sin²aX) = a·v·e^(−2a²v)·sin 2am (Stein's lemma). The closed forms were
       checked against 4·10⁶-sample Monte Carlo.
     - AdaIN outputs: mean (1+γ)·β_norm + β, variance (1+γ)²·w²·v̂/(v̂+ε), where v̂ is the
       supplied input variance.
     - Residual sums: independent. The three parallel resblocks share their input x, so the
       average is x plus the mean of the branch deltas, with the delta variances divided by 9.
- **Hyperparameters.** 5-fold CV inside train (fold seed 20260925). The loss is the mean
  over the 18,432 targets of MSE divided by the target's train variance. The grid: alpha
  10^-3…10^4 in half decades, and k ∈ {2, 4, 8, 16, 32}. PCA is refit inside each fold.
- **Evaluation**, on the 62 holdout phrases:
  1. Exactness check first: the reference statistics pass through the same (mean, log std) →
     `given` path. The run stops if any phrase falls below 100 dB.
  2. Each predictor end to end, plus the SineGen reseed floor.
  3. Attribution for the best predictor: predicted statistics in one stage, exact statistics
     in the others.
  - Metrics are `causal_norm.py`'s: waveform SNR and mean |log-mel| over 80 HTK bands, 1024/256
    STFT, floored at reference max − 80 dB. A non-finite decoder output is recorded as such
    and never averaged.

## Corpus

308 phrases, 0.57–9.97 s, voice `af_heart`. The script builds the candidate list from the
repository, phonemizes it with Misaki, computes each candidate's length from the duration
predictor, and draws up to 110 phrases per bucket (seed 20260925). Candidates:

- `bench/corpus.json` (10) and `bench/phrases.json` (3), with their phonemes verbatim
- `bench/paralinguistic.json` (13, deduplicated by phonemes)
- `bench/long-form.json`: sentences, lyric lines, comma clauses, and windows of 2–6
  consecutive sentences
- sentences, 2-sentence windows and headings from `README.md`, `BRIEF.md` and
  `docs/{DESIGN,APPLIANCE,FIRST-LIGHT,SMA-SPEECH,MODEL-ASSEMBLY,WINDOWS-COMPUTE-NODE}.md`
  (plain prose only)
- 18 short utterances added for this task (`Hello.`, `Yes.`, `Okay, thanks.`, `No.`,
  `Thanks.`, …)

`bench/` alone gives about 200 phrases after deduplication, so the repository prose was
needed to reach 300. The split is 80/20 per bucket. `Hello.`, `Yes.`, `Okay, thanks.` and
`breath-h` were forced into the holdout; the rest of the holdout is random. No holdout
phrase was used for fitting or for any hyperparameter choice.

**Limit: < 1 s is not reachable with lexical speech.** The duration predictor gives the
leading boundary token about 18 frames (0.45 s) and the last phoneme before final punctuation
about 14 frames. A single word therefore lasts 1.2–1.4 s: "Yes." 1.35 s, "Hi." 1.23 s,
"hm." 1.20 s. The one candidate under 1 s is `breath-h` (`h…`, 0.57 s). The < 1 s bucket
therefore has 0 train phrases and 1 holdout phrase. Its bucket result is a single-sample
observation, not a bucket mean. The shortest bucket that holds real speech is 1–2.5 s, and
the named short utterances are in it.

**Known overlap:** long-form sentences also occur inside multi-sentence windows and clauses.
A holdout phrase can share words with a train phrase. The predictors see only
phrase-level aggregates, not text.

## Deviations from the manifest and the task

- **G2P is Misaki 0.9.4, not the manifest's `phonemizer` 1.2.1.** Misaki is Kokoro's own
  G2P, and the README names it as the text frontend. The pinned `phonemizer` 1.2.1
  (tarball SHA-256 `12F9F358…`, verified) drops punctuation. The silence-fraction feature
  needs punctuation tokens. Neither tool reproduces the `bench/corpus.json` strings exactly.
  Misaki emits Kokoro v1.0's single-letter diphthongs (`O`, `A`, `I`, `W`), while the bench
  strings spell them out. The bench and paralinguistic entries keep their phonemes verbatim.
  Misaki, spaCy and `en_core_web_sm` are not in `lib/manifest.json`.
- **Python is 3.11.15, not 3.14.** Same as PR #1.
- **The < 1 s bucket is populated by one non-lexical item** (see Corpus).
- **Predictor 4 assumes sample independence inside convolutions.** This is my addition;
  the task specified channel independence only. Exact propagation through a convolution
  would also need each channel's temporal autocorrelation, which whole-phrase moments do not
  carry.

## Reading the numbers

- **Front-output moments carry most of the phrase dependence.** The PCA features cut the
  ridge CV loss from 0.327 to 0.188, against 1.006 for the train mean. End to end, overall
  log-mel falls from 1.14 to 0.59 dB. They also cut the per-layer log-std error by about
  a third (stage 1: 0.020 → 0.013).
- **Error is shared between the two stages, and `noise_res` is negligible.** With
  `ridge+pca` predicted in one stage and exact statistics elsewhere: stage 1 0.38 dB,
  stage 2 0.33 dB, `noise_res` 0.06 dB. The sum (0.77 dB) is above the 0.59 dB total, so
  the errors partly cancel.
- **Length and silence were what fixed statistics missed.** Fixed statistics give 7.3 dB
  on 1–2.5 s phrases (worst 15.1 dB, a paralinguistic item), and the mixture 3.2 dB.
  Regression on length, silence, F0 and N closes most of the gap.
- **Predictor 4 (moment program) diverges.** Its mean error is small, 0.02–0.08 of the
  reference std per group. But it under-predicts the variance almost everywhere: the
  signed log-std error is −0.32 (noise_res), −0.41 (stage 1) and −0.58 (stage 2) nats
  on average, and −1.54 at the first norm after the stage-2 transposed convolution (std
  4.7× too small). Supplying variances that small makes the normalized activations too
  large. These compound over 48 norms, and `exp()` in `conv_post` overflows: all 62
  holdout outputs contain inf/NaN.
  - The most likely cause is the sample-independence assumption. The generator's signals
    are upsampled and strongly autocorrelated, so same-sign taps add coherently rather than
    in power. This is an inference from where the bias is largest. The run does not test it.
  - The program takes 249 ms per phrase (numpy float64), against 1.57 s for one decoder run.

## Dataset export

For offline search, the run writes `dataset/` next to `results.json`, outside the
repository:

- `index.json` records, per phrase: row, id, split (exactly as used here), length bucket,
  source, text and phonemes. It also holds all 30 frontend features, 22 of them unused by
  predictors 0–4. Examples: token count, style row, tokens per second, pause-token count,
  space fraction, lead and tail frames, per-token durations, F0 and N percentiles, and the
  frame-to-frame log-F0 std.
- It also records each file's dtype, shape, layout and SHA-256, and each generator layer's
  name, group, channel count and channel offset.

All binary files are raw little-endian float32, row-major, with phrase as the first axis in
`index.json` row order:

| file | shape | contents | SHA-256 |
| --- | --- | --- | --- |
| `index.json` | — | index, split, features, layouts | `C9B2F4434149C8C66B9A20C45DCA761CA8846DFDCFF7326A87D3864C72E29F24` |
| `front_moments.f32` | [308, 2, 512] | decoder-front output (generator input) mean, log std | `140387BC3C70FD938A5753D4671859D30905C62C2C52E153F4500F1333D0D25F` |
| `har_moments.f32` | [308, 2, 22] | harmonic-source STFT features (11 magnitude, 11 phase) mean, log std | `64979AA8B9CD47938F3B734FCD28F36EBA28626EE4076556FBF0176431DE2F44` |
| `har_source_moments.f32` | [308, 2] | 24 kHz harmonic source waveform mean, log std | `E5797E567191E82473557D30E837E5AAB2FBB29FB928AC1019D174AAEBE66C15` |
| `gen_adain_ref.f32` | [308, 2, 9216] | every generator AdaIN input: reference mean, log std | `ACC5752ABBD7DCFAF9074A12CEA28875FE2D71A68F94FBBB3A2BEF02E5F28779` |
| `style.f32` | [308, 128] | decoder style vector | `DEDA27243FF64D342817314F1E0825864DB2E83F64DF8F360D217540E50590CF` |
| `scalar_features.f32` | [308, 8] | the predictor feature matrix | `6DCBA3C7AC238554C47A89116172641FCCED0751F07917B15C99CF80670C1774` |

Other generated outputs:

| file | SHA-256 |
| --- | --- |
| `coefficients.npz` (fitted table: fixed, mixture, ridge, ridge+pca incl. PCA basis; 8.1 MB) | `D05EE17CC90C16105E4B7313FB591A7A27141201676669284C167D4C67B2BED8` |
| `phrase_stats.npz` | `F292E8D6F47C7331CAD0EF4CC179A60053A915A5ABAA742E973FDBAB61CB762F` |
| `candidates.json` (Misaki output, cached) | `CB48D0A8BC1D6E9018A023909BBDB8A714EE01EF7FD7C3E472DBA7697A54E2C5` |

`holdout_predictions.npz` holds every predictor's holdout (mean, log std). `.npz` hashes
change between runs because the zip entries carry timestamps; the `.f32` files and the
numbers do not.

## Reproduction

```
KOKORO_MODEL_DIR=<dir with kokoro-v1_0.pth, config.json, voices/af_heart.pt> \
  python -u src/export/norm_calibration.py ../Build/Kokoro-QNN/norm-calibration --wav
python src/export/norm_calibration.py ../Build/Kokoro-QNN/norm-calibration --summarize
```

`--wav` writes `<id>_reference.wav`, `<id>_reseed.wav` and `<id>_<predictor>.wav` for every
holdout phrase next to `results.json`. The numbers above come from the same command without
`--wav`. Nothing it writes is committed. Misaki needs `pip install "misaki[en]"` and
`en_core_web_sm`.

## Tables

Generated by `--summarize` from `results.json`.

### Corpus and split

| bucket | train | holdout | seconds (min-max) | sources |
| --- | ---: | ---: | --- | --- |
| <1 s | 0 | 1 | 0.57-0.57 | bench 1 |
| 1-2.5 s | 88 | 22 | 1.00-2.48 | bench 60, prose 32, short 18 |
| 2.5-5 s | 70 | 17 | 2.50-4.97 | bench 47, prose 40 |
| >5 s | 88 | 22 | 5.03-9.97 | bench 48, prose 62 |
| all | 246 | 62 | 0.57-9.97 | |

### Exactness check (holdout, exact reference statistics through the supplied-statistics path)

| payload | min waveform SNR dB | mean waveform SNR dB | max log-mel dB |
| --- | ---: | ---: | ---: |
| fp32 (mean, log std) | 117.7 | 119.2 | 0.0000 |
| fp16 (mean, log std) | 48.6 | 54.9 | 0.0113 |

Gate for the check: >= 100 dB. Result: PASS.

### End to end on the holdout: log-mel distance dB, mean / worst

| run | <1 s | 1-2.5 s | 2.5-5 s | >5 s | overall | gate |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| reseed | 0.31 / 0.31 | 0.27 / 0.33 | 0.35 / 0.40 | 0.38 / 0.41 | 0.33 / 0.41 |  |
| fixed | 15.89 / 15.89 | 7.34 / 15.13 | 1.75 / 3.62 | 2.36 / 3.32 | 4.18 / 15.89 | FAIL |
| mixture | 12.68 / 12.68 | 3.19 / 5.14 | 1.57 / 2.35 | 2.04 / 3.20 | 2.49 / 12.68 | FAIL |
| ridge | 2.74 / 2.74 | 1.26 / 1.87 | 1.19 / 2.00 | 0.91 / 1.67 | 1.14 / 2.74 | FAIL |
| ridge+pca | 2.31 / 2.31 | 0.62 / 0.93 | 0.58 / 0.78 | 0.48 / 0.74 | 0.59 / 2.31 | FAIL |
| moments | non-finite 1/1 | non-finite 22/22 | non-finite 17/17 | non-finite 22/22 | non-finite 62/62 | FAIL |

### End to end on the holdout: waveform SNR dB, mean / worst

| run | <1 s | 1-2.5 s | 2.5-5 s | >5 s | overall |
| --- | ---: | ---: | ---: | ---: | ---: |
| reseed | 18.8 / 18.8 | 22.7 / 21.4 | 21.9 / 20.1 | 21.8 / 20.4 | 22.1 / 18.8 |
| fixed | 0.0 / 0.0 | 4.7 / 0.0 | 13.5 / 8.6 | 11.8 / 7.9 | 9.5 / 0.0 |
| mixture | -2.2 / -2.2 | 4.7 / 2.3 | 11.7 / 6.9 | 6.3 / 1.8 | 7.1 / -2.2 |
| ridge | 3.9 / 3.9 | 10.4 / 5.2 | 14.5 / 11.6 | 17.1 / 13.2 | 13.8 / 3.9 |
| ridge+pca | 3.3 / 3.3 | 15.9 / 11.2 | 18.7 / 14.8 | 20.8 / 17.9 | 18.2 / 3.3 |
| moments | non-finite 1/1 | non-finite 22/22 | non-finite 17/17 | non-finite 22/22 | non-finite 62/62 |

### Hyperparameters (5-fold CV inside train; loss = mean over targets of MSE / target variance)

| predictor | choice | CV loss | train-mean baseline CV loss |
| --- | --- | ---: | ---: |
| ridge | alpha=1 | 0.327 | 1.006 |
| ridge+pca | alpha=10, PCA k=32 | 0.188 | 1.006 |

### Per-layer prediction error on the holdout (mean over phrases and channels)

|mean error| / reference std, then |log-std error| (natural log). Reference statistics are those of the reference run; the error is measured before any propagation.

The last column is the signed log-std error of `moments` (negative: variance under-predicted).

| layer | ch | fixed mean | mixture mean | ridge mean | ridge+pca mean | moments mean | fixed logstd | mixture logstd | ridge logstd | ridge+pca logstd | moments logstd | moments logstd bias |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| noise_res.0.adain1.0 | 256 | 0.052 | 0.025 | 0.014 | 0.015 | 0.011 | 0.028 | 0.019 | 0.013 | 0.014 | 0.256 | -0.242 |
| noise_res.0.adain1.1 | 256 | 0.068 | 0.046 | 0.017 | 0.018 | 0.014 | 0.034 | 0.022 | 0.014 | 0.015 | 0.391 | -0.042 |
| noise_res.0.adain1.2 | 256 | 0.082 | 0.061 | 0.020 | 0.021 | 0.024 | 0.034 | 0.025 | 0.016 | 0.018 | 0.339 | +0.075 |
| noise_res.0.adain2.0 | 256 | 0.019 | 0.038 | 0.003 | 0.003 | 0.012 | 0.026 | 0.022 | 0.014 | 0.015 | 0.365 | -0.353 |
| noise_res.0.adain2.1 | 256 | 0.037 | 0.033 | 0.003 | 0.003 | 0.017 | 0.055 | 0.046 | 0.031 | 0.033 | 0.844 | -0.840 |
| noise_res.0.adain2.2 | 256 | 0.056 | 0.056 | 0.005 | 0.005 | 0.019 | 0.067 | 0.047 | 0.031 | 0.033 | 0.657 | -0.657 |
| noise_res.1.adain1.0 | 128 | 0.057 | 0.021 | 0.008 | 0.009 | 0.000 | 0.034 | 0.018 | 0.008 | 0.008 | 0.180 | +0.134 |
| noise_res.1.adain1.1 | 128 | 0.099 | 0.080 | 0.014 | 0.015 | 0.031 | 0.030 | 0.022 | 0.008 | 0.009 | 0.653 | +0.637 |
| noise_res.1.adain1.2 | 128 | 0.114 | 0.106 | 0.015 | 0.017 | 0.042 | 0.034 | 0.027 | 0.009 | 0.009 | 0.734 | +0.596 |
| noise_res.1.adain2.0 | 128 | 0.025 | 0.030 | 0.002 | 0.002 | 0.013 | 0.032 | 0.021 | 0.008 | 0.008 | 1.370 | -1.370 |
| noise_res.1.adain2.1 | 128 | 0.037 | 0.048 | 0.002 | 0.002 | 0.026 | 0.030 | 0.025 | 0.009 | 0.010 | 0.983 | -0.978 |
| noise_res.1.adain2.2 | 128 | 0.051 | 0.035 | 0.003 | 0.003 | 0.024 | 0.039 | 0.027 | 0.013 | 0.014 | 0.815 | -0.814 |
| resblocks.0.adain1.0 | 256 | 0.040 | 0.026 | 0.015 | 0.007 | 0.013 | 0.043 | 0.048 | 0.020 | 0.013 | 0.636 | -0.636 |
| resblocks.0.adain1.1 | 256 | 0.036 | 0.025 | 0.013 | 0.007 | 0.017 | 0.036 | 0.046 | 0.020 | 0.012 | 0.435 | -0.434 |
| resblocks.0.adain1.2 | 256 | 0.035 | 0.028 | 0.014 | 0.008 | 0.023 | 0.035 | 0.049 | 0.020 | 0.012 | 0.305 | -0.302 |
| resblocks.0.adain2.0 | 256 | 0.023 | 0.028 | 0.006 | 0.004 | 0.027 | 0.035 | 0.050 | 0.021 | 0.013 | 0.171 | -0.168 |
| resblocks.0.adain2.1 | 256 | 0.022 | 0.024 | 0.007 | 0.005 | 0.026 | 0.033 | 0.047 | 0.021 | 0.013 | 0.156 | -0.150 |
| resblocks.0.adain2.2 | 256 | 0.028 | 0.036 | 0.009 | 0.007 | 0.037 | 0.028 | 0.060 | 0.019 | 0.014 | 0.159 | -0.154 |
| resblocks.1.adain1.0 | 256 | 0.040 | 0.026 | 0.015 | 0.007 | 0.013 | 0.043 | 0.048 | 0.020 | 0.013 | 0.636 | -0.636 |
| resblocks.1.adain1.1 | 256 | 0.038 | 0.029 | 0.014 | 0.008 | 0.023 | 0.038 | 0.052 | 0.019 | 0.012 | 0.582 | -0.582 |
| resblocks.1.adain1.2 | 256 | 0.039 | 0.036 | 0.014 | 0.008 | 0.037 | 0.035 | 0.068 | 0.018 | 0.012 | 0.533 | -0.533 |
| resblocks.1.adain2.0 | 256 | 0.023 | 0.028 | 0.008 | 0.006 | 0.037 | 0.033 | 0.051 | 0.020 | 0.012 | 0.365 | -0.365 |
| resblocks.1.adain2.1 | 256 | 0.030 | 0.033 | 0.009 | 0.006 | 0.040 | 0.030 | 0.060 | 0.019 | 0.012 | 0.264 | -0.262 |
| resblocks.1.adain2.2 | 256 | 0.030 | 0.038 | 0.010 | 0.007 | 0.044 | 0.029 | 0.087 | 0.018 | 0.013 | 0.367 | -0.364 |
| resblocks.2.adain1.0 | 256 | 0.040 | 0.026 | 0.015 | 0.007 | 0.013 | 0.043 | 0.048 | 0.020 | 0.013 | 0.636 | -0.636 |
| resblocks.2.adain1.1 | 256 | 0.045 | 0.030 | 0.015 | 0.009 | 0.028 | 0.041 | 0.047 | 0.019 | 0.012 | 0.572 | -0.572 |
| resblocks.2.adain1.2 | 256 | 0.046 | 0.034 | 0.016 | 0.009 | 0.037 | 0.038 | 0.051 | 0.021 | 0.013 | 0.532 | -0.532 |
| resblocks.2.adain2.0 | 256 | 0.032 | 0.030 | 0.009 | 0.006 | 0.040 | 0.040 | 0.049 | 0.022 | 0.012 | 0.422 | -0.422 |
| resblocks.2.adain2.1 | 256 | 0.045 | 0.043 | 0.011 | 0.008 | 0.054 | 0.039 | 0.052 | 0.023 | 0.015 | 0.245 | -0.240 |
| resblocks.2.adain2.2 | 256 | 0.046 | 0.035 | 0.012 | 0.008 | 0.045 | 0.040 | 0.060 | 0.026 | 0.019 | 0.447 | -0.447 |
| resblocks.3.adain1.0 | 128 | 0.036 | 0.023 | 0.012 | 0.007 | 0.110 | 0.047 | 0.116 | 0.011 | 0.008 | 1.551 | -1.539 |
| resblocks.3.adain1.1 | 128 | 0.044 | 0.040 | 0.011 | 0.006 | 0.089 | 0.043 | 0.099 | 0.014 | 0.009 | 0.482 | -0.453 |
| resblocks.3.adain1.2 | 128 | 0.073 | 0.042 | 0.011 | 0.007 | 0.076 | 0.040 | 0.089 | 0.018 | 0.012 | 0.610 | -0.604 |
| resblocks.3.adain2.0 | 128 | 0.041 | 0.033 | 0.006 | 0.005 | 0.059 | 0.047 | 0.096 | 0.010 | 0.007 | 0.146 | -0.074 |
| resblocks.3.adain2.1 | 128 | 0.061 | 0.051 | 0.010 | 0.007 | 0.069 | 0.038 | 0.096 | 0.017 | 0.013 | 0.307 | -0.293 |
| resblocks.3.adain2.2 | 128 | 0.072 | 0.055 | 0.009 | 0.007 | 0.062 | 0.047 | 0.077 | 0.022 | 0.017 | 0.428 | -0.399 |
| resblocks.4.adain1.0 | 128 | 0.036 | 0.023 | 0.012 | 0.007 | 0.110 | 0.047 | 0.116 | 0.011 | 0.008 | 1.551 | -1.539 |
| resblocks.4.adain1.1 | 128 | 0.037 | 0.026 | 0.012 | 0.006 | 0.119 | 0.037 | 0.105 | 0.011 | 0.008 | 0.576 | -0.562 |
| resblocks.4.adain1.2 | 128 | 0.038 | 0.030 | 0.011 | 0.006 | 0.120 | 0.032 | 0.108 | 0.015 | 0.011 | 0.426 | -0.403 |
| resblocks.4.adain2.0 | 128 | 0.027 | 0.020 | 0.007 | 0.005 | 0.078 | 0.034 | 0.090 | 0.011 | 0.007 | 0.218 | -0.115 |
| resblocks.4.adain2.1 | 128 | 0.021 | 0.023 | 0.007 | 0.004 | 0.068 | 0.024 | 0.108 | 0.012 | 0.009 | 0.195 | -0.184 |
| resblocks.4.adain2.2 | 128 | 0.059 | 0.034 | 0.008 | 0.006 | 0.057 | 0.030 | 0.096 | 0.018 | 0.013 | 0.337 | -0.331 |
| resblocks.5.adain1.0 | 128 | 0.036 | 0.023 | 0.012 | 0.007 | 0.110 | 0.047 | 0.116 | 0.011 | 0.008 | 1.551 | -1.539 |
| resblocks.5.adain1.1 | 128 | 0.040 | 0.030 | 0.011 | 0.007 | 0.103 | 0.032 | 0.095 | 0.014 | 0.010 | 0.757 | -0.743 |
| resblocks.5.adain1.2 | 128 | 0.044 | 0.028 | 0.011 | 0.007 | 0.098 | 0.032 | 0.086 | 0.017 | 0.013 | 0.586 | -0.544 |
| resblocks.5.adain2.0 | 128 | 0.038 | 0.039 | 0.009 | 0.006 | 0.091 | 0.030 | 0.092 | 0.015 | 0.011 | 0.300 | -0.184 |
| resblocks.5.adain2.1 | 128 | 0.040 | 0.034 | 0.008 | 0.006 | 0.050 | 0.023 | 0.086 | 0.016 | 0.013 | 0.378 | -0.378 |
| resblocks.5.adain2.2 | 128 | 0.067 | 0.038 | 0.009 | 0.007 | 0.052 | 0.033 | 0.070 | 0.022 | 0.016 | 0.537 | -0.536 |
| **noise_res mean** | | 0.058 | 0.048 | 0.009 | 0.009 | 0.019 | 0.037 | 0.027 | 0.014 | 0.015 | 0.632 | -0.321 |
| **stage 1 mean** | | 0.035 | 0.031 | 0.012 | 0.007 | 0.031 | 0.037 | 0.054 | 0.020 | 0.013 | 0.415 | -0.413 |
| **stage 2 mean** | | 0.045 | 0.033 | 0.010 | 0.006 | 0.084 | 0.037 | 0.097 | 0.015 | 0.011 | 0.608 | -0.579 |

### Attribution for ridge+pca: predicted statistics in one stage, exact elsewhere (holdout)

| stage predicted | log-mel dB mean / worst | waveform SNR dB mean / worst | <1 s log-mel mean | 1-2.5 s log-mel mean | 2.5-5 s log-mel mean | >5 s log-mel mean |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| stage 1 (resblocks 0-2, 800 Hz) | 0.38 / 1.62 | 21.0 / 2.4 | 1.62 | 0.40 | 0.38 | 0.30 |
| stage 2 (resblocks 3-5, 4800 Hz) | 0.33 / 1.61 | 24.9 / 11.5 | 1.61 | 0.34 | 0.33 | 0.26 |
| noise_res (both stages) | 0.06 / 0.19 | 33.0 / 21.9 | 0.19 | 0.06 | 0.06 | 0.05 |
| all generator norms | 0.59 / 2.31 | 18.2 / 3.3 | 2.31 | 0.62 | 0.58 | 0.48 |

### Sizes

Statistics payload per phrase: 9216 generator channels x 2 values (mean, log std) = 73728 bytes fp32, 36864 bytes fp16.

| predictor | coefficients | bytes fp32 |
| --- | ---: | ---: |
| fixed | 18432 | 73728 |
| mixture | 36864 | 147456 |
| ridge | 165904 | 663616 |
| ridge+pca | 790608 | 3162432 |
| moments | 0 (model weights only) | 0 |

Runtime: 2171 s total; 990 decoder runs at 1.57 s each on average (0.361 s per second of audio); fitting 48.0 s; moment program 248.9 ms per phrase (numpy, float64, holdout mean).

### Holdout phrases, log-mel dB per run

| id | bucket | s | frames | silence | reseed | fixed | mixture | ridge | ridge+pca | moments | phonemes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| c000 | <1 s | 0.57 | 23 | 0.91 | 0.31 | 15.89 | 12.68 | 2.74 | 2.31 | nan | `h…` |
| c023 | 1-2.5 s | 1.25 | 50 | 0.58 | 0.25 | 14.95 | 4.65 | 1.09 | 0.56 | nan | `hˈɛh.` |
| c026 | 1-2.5 s | 1.25 | 50 | 0.54 | 0.22 | 15.13 | 4.15 | 1.21 | 0.65 | nan | `ʔhˈɑ!` |
| c109 | 1-2.5 s | 1.30 | 52 | 0.56 | 0.23 | 14.56 | 5.14 | 1.79 | 0.93 | nan | `ɡˈOl` |
| c001 | 1-2.5 s | 1.35 | 54 | 0.52 | 0.25 | 12.75 | 4.63 | 1.07 | 0.31 | nan | `həlˈO.` |
| c002 | 1-2.5 s | 1.35 | 54 | 0.52 | 0.20 | 13.15 | 3.63 | 1.66 | 0.80 | nan | `jˈɛs.` |
| c010 | 1-2.5 s | 1.38 | 55 | 0.47 | 0.25 | 9.58 | 4.10 | 0.69 | 0.59 | nan | `ɡˌɑt ɪt.` |
| c050 | 1-2.5 s | 1.57 | 63 | 0.41 | 0.25 | 7.36 | 3.77 | 1.16 | 0.53 | nan | `fˈInd ðə wˈI,` |
| c028 | 1-2.5 s | 1.60 | 64 | 0.41 | 0.30 | 8.71 | 3.77 | 1.69 | 0.60 | nan | `kˈɑʔ, kˈɑʔ!` |
| c003 | 1-2.5 s | 1.73 | 69 | 0.38 | 0.24 | 6.68 | 3.10 | 1.10 | 0.53 | nan | `ˌOkˈA, θˈæŋks.` |
| c052 | 1-2.5 s | 1.75 | 70 | 0.34 | 0.24 | 6.25 | 3.17 | 1.07 | 0.65 | nan | `pɹˌɛzᵊntˈAʃən,` |
| c041 | 1-2.5 s | 1.77 | 71 | 0.35 | 0.26 | 6.52 | 3.13 | 1.59 | 0.57 | nan | `bˈɪld fɹʌm sˈɔɹs` |
| c060 | 1-2.5 s | 1.77 | 71 | 0.30 | 0.31 | 4.55 | 2.93 | 1.47 | 0.69 | nan | `wˌi kˈɔl ɪt ɐ vˈɛɹiəbᵊl,` |
| c084 | 1-2.5 s | 1.77 | 71 | 0.34 | 0.28 | 4.69 | 2.72 | 1.02 | 0.57 | nan | `ˈIsəlˌAt ðə lˈɛTəɹ,` |
| c099 | 1-2.5 s | 1.80 | 72 | 0.28 | 0.29 | 4.65 | 2.58 | 1.30 | 0.52 | nan | `ˌɪts ˈɔl əbˈWt bˈæləns,` |
| c089 | 1-2.5 s | 1.90 | 76 | 0.32 | 0.26 | 6.63 | 3.38 | 1.76 | 0.78 | nan | `mˈʌltəpᵊl spˈikəɹz` |
| c066 | 1-2.5 s | 1.93 | 77 | 0.29 | 0.30 | 4.88 | 2.53 | 0.96 | 0.57 | nan | `vˈɛɹəfˌI ˌɔn wˈɪndOz` |
| c092 | 1-2.5 s | 1.95 | 78 | 0.27 | 0.31 | 3.55 | 2.37 | 1.54 | 0.71 | nan | `hˌi lˈɛt ˈWt ɐ lˈO wˈɪsᵊl,` |
| c044 | 1-2.5 s | 1.98 | 79 | 0.27 | 0.33 | 4.14 | 2.56 | 1.14 | 0.48 | nan | `ðə mˈAn lˈIts wɜɹ dˈɪmd,` |
| c049 | 1-2.5 s | 2.08 | 83 | 0.24 | 0.33 | 4.31 | 2.71 | 1.87 | 0.67 | nan | `kəkˈɔɹO mˈɑdᵊl əsˈɛmbli` |
| c075 | 1-2.5 s | 2.33 | 93 | 0.23 | 0.30 | 3.09 | 1.84 | 0.70 | 0.80 | nan | `ˌʌndəɹstˈændɪŋ dˈɔnɪŋ slˈOli.` |
| c106 | 1-2.5 s | 2.40 | 96 | 0.24 | 0.30 | 3.16 | 1.84 | 0.90 | 0.61 | nan | `hˌi nˈOz. ˌɪt wˈʌzᵊnt ɐ kwˈɛsʧᵊn.` |
| c070 | 1-2.5 s | 2.42 | 97 | 0.22 | 0.32 | 2.24 | 1.58 | 1.04 | 0.65 | nan | `dˈOnt lˈɛt ðə lˈɛTəɹz mˌAk ju fɹˈWn.` |
| c184 | 2.5-5 s | 2.65 | 106 | 0.23 | 0.31 | 3.62 | 2.14 | 1.17 | 0.58 | nan | `wˌʌts ɹˈɔŋ? tˈuvɑk. tˈɑm fɹˈOz.` |
| c159 | 2.5-5 s | 2.83 | 113 | 0.19 | 0.31 | 2.29 | 1.53 | 0.96 | 0.55 | nan | `dˈu ɪt tə ðə ɹˈIt ænd jʊɹ dˈuɪŋ ʤˈʌst fˈIn!` |
| c136 | 2.5-5 s | 2.92 | 117 | 0.17 | 0.36 | 2.46 | 2.02 | 1.63 | 0.66 | nan | `ðə nˈɛkst tˈɛst kˈips ðə kjˌuˌɛnˈɛn kˈɑntɛksts,` |
| c163 | 2.5-5 s | 2.98 | 119 | 0.17 | 0.35 | 1.75 | 1.38 | 1.02 | 0.52 | nan | `ði ˈɛɹ smˈɛld ʌv ˈOzˌOn ænd ˈɛnʤən kˈulənt.` |
| c128 | 2.5-5 s | 3.12 | 125 | 0.18 | 0.32 | 2.58 | 1.85 | 1.02 | 0.57 | nan | `nˈiðəɹ ɹəpˈɑzətˌɔɹi pɹˈuvz ɐ spˈiʧ mˈɑdᵊl.` |
| c174 | 2.5-5 s | 3.20 | 128 | 0.17 | 0.38 | 2.60 | 2.24 | 1.86 | 0.51 | nan | `fˈɑlO ðə ɡˈOldən ɹˈul ænd ju wɪl nˈɛvəɹ fˈAl.` |
| c194 | 2.5-5 s | 3.45 | 138 | 0.18 | 0.35 | 1.62 | 1.24 | 1.44 | 0.78 | nan | `fˈɜɹst vˌOkəlˌIzˈAʃən (pˈWəɹʃˌɛl ˌIˌɛstˌiˌɛftˈi)` |
| c173 | 2.5-5 s | 3.55 | 142 | 0.17 | 0.33 | 1.45 | 1.04 | 0.88 | 0.73 | nan | `fˈɜɹst lˈIt — twˈɛnti twˈɛnti sˈɪkszˈɪɹO nˈIntwˌɛnti tˌu` |
| c137 | 2.5-5 s | 3.73 | 149 | 0.13 | 0.35 | 1.13 | 1.33 | 0.97 | 0.52 | nan | `hˌɜɹ fˈʊtstˌɛps ˌɔn ðə dˈɛk plˈATɪŋ wɜɹ ˌʌnnˈæʧəɹəli lˈWd.` |
| c117 | 2.5-5 s | 4.15 | 166 | 0.12 | 0.36 | 1.07 | 1.75 | 0.99 | 0.44 | nan | `ði ˈɛndpYnt nˈɛvəɹ əvˈæljʊˌAts sˈɔɹs ɹəsˈivd fɹʌm jˌuˌɛsbˈi.` |
| c161 | 2.5-5 s | 4.15 | 166 | 0.13 | 0.38 | 1.15 | 1.46 | 0.94 | 0.64 | nan | `mˈɛʒəɹ ðə fˈɪzəkᵊl dəvˈIs ænd plˈA ðə ɹəzˈʌlt θɹu ðə spˈikəɹ.` |
| c125 | 2.5-5 s | 4.17 | 167 | 0.13 | 0.35 | 2.00 | 2.35 | 2.00 | 0.52 | nan | `ðˌiz sˈɔɹsᵻz ʤˈʌstəfˌI kˈændədˌAt fˈiʧəɹz ænd tˈɛst dəzˈIn.` |
| c120 | 2.5-5 s | 4.33 | 173 | 0.14 | 0.34 | 1.21 | 1.22 | 1.18 | 0.52 | nan | `tˈɑm fɹˈOz. hˌi sˈɜɹʧt hɜɹ fˈAs, ˌʌndəɹstˈændɪŋ dˈɔnɪŋ slˈOli.` |
| c169 | 2.5-5 s | 4.60 | 184 | 0.11 | 0.37 | 1.34 | 1.61 | 1.29 | 0.67 | nan | `bˈɪld ˈWtpˌʊt ænd sˈInɪŋ mətˈɪɹiəl ɹəmˈAn ˌWtsˈId ðə ɹəpˈɑzətˌɔɹi.` |
| c152 | 2.5-5 s | 4.72 | 189 | 0.12 | 0.40 | 0.99 | 1.13 | 1.01 | 0.58 | nan | `nˈO pˈIθˌɑn ənvˈIɹənmᵊnt ɪz ɪnvˈɑlvd ɪn ðɪs mˈænɪʤd əsˈɛmbli bˈɪld.` |
| c180 | 2.5-5 s | 4.83 | 193 | 0.12 | 0.37 | 1.16 | 1.04 | 0.92 | 0.54 | nan | `hˌɜɹ fˈʊtstˌɛps ˌɔn ðə dˈɛk plˈATɪŋ wɜɹ ˌʌnnˈæʧəɹəli lˈWd. ðə wˈɛldɪŋ stˈɑpt.` |
| c188 | 2.5-5 s | 4.88 | 195 | 0.15 | 0.39 | 1.27 | 1.42 | 0.87 | 0.62 | nan | `jˈɛə, lˈʊk æt ðə bˈɔɹd, lˈɛts bɹˈAk ɪt dˌWn, dˈOnt lˈɛt ðə lˈɛTəɹz mˌAk ju fɹˈWn.` |
| c251 | >5 s | 5.12 | 205 | 0.14 | 0.37 | 1.42 | 1.31 | 1.05 | 0.35 | nan | `ðə ɡˈOl ʌv ðə ɡˈAm ɪz tə lˈiv ɪt əlˈOn, ˈIsəlˌAt ðə lˈɛTəɹ, pˌʊt ɪt ˌɔn ɐ θɹˈOn.` |
| c204 | >5 s | 5.35 | 214 | 0.09 | 0.39 | 1.60 | 1.63 | 0.64 | 0.49 | nan | `ðə mˈɑdᵊl sˈɜɹfəs kæn bi lˈOdᵻd ænd ʧˈɛkt bəfˈɔɹ ɐn ˈændɹˌYd əplˈIəns ɪz ɪnstˈɔld:` |
| c230 | >5 s | 5.40 | 216 | 0.13 | 0.35 | 1.25 | 1.28 | 1.13 | 0.55 | nan | `hˌi ʃˈildᵻd hɪz ˈIz əɡˈɛnst hɪz ˈOn lˈIt, skwˈɪntɪŋ tə sˈi hˌu wʌz ðˈɛɹ. kˈæptᵊn?` |
| c298 | >5 s | 5.67 | 227 | 0.12 | 0.35 | 1.25 | 1.15 | 0.85 | 0.41 | nan | `wˌʌts ɹˈɔŋ? tˈuvɑk. tˈɑm fɹˈOz. hˌi sˈɜɹʧt hɜɹ fˈAs, ˌʌndəɹstˈændɪŋ dˈɔnɪŋ slˈOli.` |
| c206 | >5 s | 6.15 | 246 | 0.09 | 0.37 | 1.60 | 1.74 | 0.63 | 0.43 | nan | `ðə pɹˈɑdˌʌkt ɪz ɐ spˈiʧ ˌæpləkˈAʃən wɪð ɐn əmbˈɛdᵻd, dəlˈɪbəɹətli ɹədˈust pˈWəɹʃˌɛl ɹˈʌntIm.` |
| c264 | >5 s | 6.35 | 254 | 0.11 | 0.38 | 1.61 | 1.45 | 0.90 | 0.49 | nan | `hˌi lˈɛt ˈWt ɐ lˈO wˈɪsᵊl, ɐ sˈWnd ðæt wʌz ˈikwᵊl pˈɑɹts ʃˈɑk ænd ɡɹˈʌʤɪŋ ˌædməɹˈAʃən. hˌi nˈOz.` |
| c211 | >5 s | 6.78 | 271 | 0.10 | 0.37 | 1.64 | 1.62 | 0.91 | 0.46 | nan | `nˈiðəɹ ɹəpˈɑzətˌɔɹi pɹˈuvz ɐ spˈiʧ mˈɑdᵊl. ðˌɛɹ sˈɜɹʧ ænd ədmˈɪʃən pˈæTəɹnz ɑɹ ðə ɹijˈuzəbᵊl pˈɑɹts.` |
| c216 | >5 s | 6.95 | 278 | 0.09 | 0.36 | 2.56 | 2.11 | 1.01 | 0.74 | nan | `ðə nˈɛkst tˈɛst kˈips ðə kjˌuˌɛnˈɛn kˈɑntɛksts, tˈɛnsəɹ bˈʌfəɹz, ænd ˈɔdiO stɹˈim əlˈIv fɔɹ ɐ kəmplˈit pˈæsɪʤ.` |
| c269 | >5 s | 6.97 | 279 | 0.09 | 0.36 | 2.03 | 1.83 | 0.55 | 0.43 | nan | `ɐ spˈikəɹ ʧˈAnʤ səlˈɛkts ɐ stˈIl ˈɪnpˌʊt; ɪt dˈʌz nˌɑt ɹilˈOd ði ˈATi tˈu ˈɛm mˈɑdᵊl ɔɹ ðə kəmpˈIld ɡɹˈæfz.` |
| c307 | >5 s | 7.00 | 280 | 0.09 | 0.37 | 2.23 | 2.17 | 1.42 | 0.46 | nan | `kˈæptᵊn? hˌi stˈʊd, hɪz ɪkspɹˈɛʃən ʃˈɪftɪŋ fɹʌm səɹpɹˈIz tʊ ɪmˈidiət kənsˈɜɹn æz ʃi stˈɛpt ˈɪntu ðə lˈIt.` |
| c255 | >5 s | 7.28 | 291 | 0.10 | 0.40 | 2.00 | 1.61 | 0.85 | 0.59 | nan | `ˈɛɹəɹ əɡˈɛnst ðə fˌʊllˈɛŋθ mˈɑdᵊl: twˈɛnti fˈɔɹ pYnt tˈu dˌibˈi ˌɛsˌɛnˈɑɹ, zˈɪɹO pYnt sˈɪks tˈu dˌibˈi lˈɔɡmˈɛl.` |
| c274 | >5 s | 7.47 | 299 | 0.07 | 0.41 | 2.68 | 2.65 | 0.86 | 0.45 | nan | `kjˌuˌɛnˈɛn stˈɪl jˈuzᵻz ðə dəvˈIsᵻz pˈɪnd ˌAʧtˌipˈi ɹˈʌntIm ænd ɪts plˈætfˌɔɹm dˌiˌɛspˈi tɹˈænspˌɔɹt ɪntˈɜɹnəli.` |
| c252 | >5 s | 7.62 | 305 | 0.11 | 0.38 | 2.45 | 1.81 | 0.82 | 0.42 | nan | `jˈɛə, lˈʊk æt ðə bˈɔɹd, lˈɛts bɹˈAk ɪt dˌWn, dˈOnt lˈɛt ðə lˈɛTəɹz mˌAk ju fɹˈWn. sˈi ɐn ˈɛks ɔɹ ɐ wˈI ɪn ðə mˈɪdᵊl ʌv ðə mˈæθ?` |
| c302 | >5 s | 9.15 | 366 | 0.09 | 0.39 | 3.00 | 2.41 | 1.05 | 0.50 | nan | `zˈɪɹOkˌɑpi ʃˈɛɹd mˈɛməɹi (diɛmˌAbˌijˌuˈɛf ɹˈɛʤəstəɹd wɪð kjˌuˌɛnˈɛn), dˌʌbᵊlbˈʌfəɹd bətwˈin sˌipˌijˈu ænd ˌAʧtˌipˈi wɪð kəmplˈiʃən fˈɛnsᵻz.` |
| c203 | >5 s | 9.18 | 367 | 0.07 | 0.40 | 3.06 | 2.35 | 0.69 | 0.42 | nan | `bɹˌɛθɡɹˈup dʊɹˈAʃən ˈævəɹɪʤd əbˈWt θɹˈi pYnt fˈIv sˈɛkəndz, ænd ˌɪnhəlˈAʃən dˈɛpθ ænd dʊɹˈAʃən vˈɛɹid wɪð ˌʌpkˈʌmɪŋ klˈɔz tˈIp ænd ɡɹˈup lˈɛŋθ.` |
| c282 | >5 s | 9.18 | 367 | 0.07 | 0.37 | 3.32 | 3.20 | 1.67 | 0.68 | nan | `jˈuzd kəntˈɛksʧəwəl tˈɛkst ænd pˈɑɹstɹˌi fˈiʧəɹz tə sˈæmpᵊl pɹəsˈɑdɪk ɹˌɛpɹəzˌɛntˈAʃənz fɔɹ nˈʊɹᵊl tˌitˌiˈɛs, wɪð kəntɹˈOld lˈɪsənɪŋ tˈɛsts.` |
| c200 | >5 s | 9.32 | 373 | 0.09 | 0.37 | 3.00 | 2.39 | 1.07 | 0.34 | nan | `hˌi stˈʊd, hɪz ɪkspɹˈɛʃən ʃˈɪftɪŋ fɹʌm səɹpɹˈIz tʊ ɪmˈidiət kənsˈɜɹn æz ʃi stˈɛpt ˈɪntu ðə lˈIt. hˌi sˈɔ ɪt ˌɔn hɜɹ fˈAs ˈɪnstəntli. wˌʌts ɹˈɔŋ?` |
| c254 | >5 s | 9.40 | 376 | 0.09 | 0.40 | 2.97 | 2.13 | 0.72 | 0.44 | nan | `pɹədˈus spˈiʧˌækt, bˈWndəɹi, stˈAt, ænd pɹˈɑmənᵊns kˈændədˌAts wɪðˈWt ʧˈAnʤɪŋ ˈɔθəɹd tˈɛkst. lˈOəɹ wˈʌn kˈændədˌAt θɹu ɐ ɹəvˈɜɹsəbᵊl mjutˈAʃən.` |
| c248 | >5 s | 9.55 | 382 | 0.09 | 0.40 | 3.10 | 2.40 | 0.80 | 0.51 | nan | `dˈʌbᵊlju ˈAt ˈA sˌɪkstˈin (ˈɪnt ˈAt wˈAts, ˈɪnt sˈɪkstin ˌæktəvˈAʃənz) dˈʌz nˌɑt fˈInᵊlˌIz jˈɛt, ɪnklˈudɪŋ ɐ kˌɑnvˈOnli vˈɛɹiənt ˈʌndəɹ tˈɛst.` |
| c296 | >5 s | 9.60 | 384 | 0.09 | 0.38 | 3.10 | 2.30 | 0.72 | 0.34 | nan | `hˌi sˈɜɹʧt hɜɹ fˈAs, ˌʌndəɹstˈændɪŋ dˈɔnɪŋ slˈOli. hˌi lˈɛt ˈWt ɐ lˈO wˈɪsᵊl, ɐ sˈWnd ðæt wʌz ˈikwᵊl pˈɑɹts ʃˈɑk ænd ɡɹˈʌʤɪŋ ˌædməɹˈAʃən. hˌi nˈOz.` |
| c280 | >5 s | 9.62 | 385 | 0.05 | 0.39 | 2.92 | 2.97 | 0.62 | 0.62 | nan | `ði ɪntˈɛndᵻd dˈɛmO təpˈɑləʤi ɪz ɐ wˈɪndOz pˈWəɹʃˌɛl klˈIənt wɪð ɐ kəmpˈæTəbᵊl ˈændɹˌYd fˈOn ˈæktɪŋ æz ɐ pəɹsˈɪstənt spˈiʧ kəmpjˈut əplˈIəns.` |
| c205 | >5 s | 9.85 | 394 | 0.09 | 0.36 | 3.10 | 2.35 | 1.07 | 0.34 | nan | `hˌi stˈʊd, hɪz ɪkspɹˈɛʃən ʃˈɪftɪŋ fɹʌm səɹpɹˈIz tʊ ɪmˈidiət kənsˈɜɹn æz ʃi stˈɛpt ˈɪntu ðə lˈIt. hˌi sˈɔ ɪt ˌɔn hɜɹ fˈAs ˈɪnstəntli. wˌʌts ɹˈɔŋ? tˈuvɑk.` |

<details><summary>Full corpus (id, split, seconds, frames, tokens, source, text, phonemes)</summary>

| id | split | s | frames | tokens | source | text | phonemes |
| --- | --- | ---: | ---: | ---: | --- | --- | --- |
| c000 | holdout | 0.57 | 23 | 4 | bench/paralinguistic | breath-h | `h…` |
| c032 | train | 1.00 | 40 | 7 | bench/paralinguistic | breath-hh | `h, h…` |
| c031 | train | 1.23 | 49 | 6 | bench/paralinguistic | breath-soft | `hɑː…` |
| c007 | train | 1.25 | 50 | 6 | short | Hi. | `hˈI.` |
| c023 | holdout | 1.25 | 50 | 7 | bench/paralinguistic | heh-short | `hˈɛh.` |
| c026 | holdout | 1.25 | 50 | 7 | bench/paralinguistic | gasp-initial-stop | `ʔhˈɑ!` |
| c014 | train | 1.27 | 51 | 7 | short | Wait. | `wˈAt.` |
| c004 | train | 1.30 | 52 | 6 | short | No. | `nˈO.` |
| c008 | train | 1.30 | 52 | 7 | short | Sure. | `ʃˈʊɹ.` |
| c009 | train | 1.30 | 52 | 7 | short | Right. | `ɹˈIt.` |
| c109 | holdout | 1.30 | 52 | 6 | prose/BRIEF.md | Goal | `ɡˈOl` |
| c001 | holdout | 1.35 | 54 | 8 | short | Hello. | `həlˈO.` |
| c002 | holdout | 1.35 | 54 | 7 | short | Yes. | `jˈɛs.` |
| c006 | train | 1.35 | 54 | 9 | short | Thanks. | `θˈæŋks.` |
| c015 | train | 1.35 | 54 | 8 | short | Hello? | `həlˈO?` |
| c025 | train | 1.35 | 54 | 8 | bench/paralinguistic | sigh-falling | `hˈɑː↘…` |
| c010 | holdout | 1.38 | 55 | 10 | short | Got it. | `ɡˌɑt ɪt.` |
| c016 | train | 1.38 | 55 | 8 | short | Sorry? | `sˈɔɹi?` |
| c027 | train | 1.38 | 55 | 8 | bench/paralinguistic | cough-single | `kʰˈɑʔ!` |
| c046 | train | 1.38 | 55 | 7 | bench/long-form/meter-algebra | Yeah, | `jˈɛə,` |
| c101 | train | 1.38 | 55 | 9 | bench/long-form/narrative-accomplice | Tuvok. | `tˈuvɑk.` |
| c019 | train | 1.40 | 56 | 9 | bench/phrases | hello | `həlˈoʊ.` |
| c024 | train | 1.40 | 56 | 9 | bench/paralinguistic | laugh-open | `hə hˈɑ!` |
| c030 | train | 1.40 | 56 | 13 | bench/paralinguistic | wheeze-long | `hˈiː… hˈiː…` |
| c043 | train | 1.40 | 56 | 8 | prose/README.md | Layout | `lˈAˌWt` |
| c045 | train | 1.40 | 56 | 7 | prose/docs/DESIGN.md | Open | `ˈOpᵊn` |
| c005 | train | 1.43 | 57 | 8 | short | Okay. | `ˌOkˈA.` |
| c011 | train | 1.43 | 57 | 11 | short | Thank you. | `θˈæŋk ju.` |
| c082 | train | 1.45 | 58 | 8 | bench/long-form/technical-current-state | mono, | `mˈɑnO,` |
| c088 | train | 1.45 | 58 | 10 | bench/long-form/narrative-accomplice | Captain? | `kˈæptᵊn?` |
| c034 | train | 1.48 | 59 | 12 | bench/long-form/narrative-accomplice | He stood, | `hˌi stˈʊd,` |
| c065 | train | 1.48 | 59 | 10 | prose/README.md | Pipeline | `pˈIplˌIn` |
| c018 | train | 1.50 | 60 | 12 | short | Not yet. | `nˌɑt jˈɛt.` |
| c087 | train | 1.50 | 60 | 9 | prose/README.md | Status | `stˈATəs` |
| c017 | train | 1.52 | 61 | 12 | short | Of course. | `ˌʌv kˈɔɹs.` |
| c083 | train | 1.52 | 61 | 11 | bench/long-form/narrative-accomplice | He knows. | `hˌi nˈOz.` |
| c110 | train | 1.52 | 61 | 17 | prose/BRIEF.md | Where it stands | `wˌɛɹ ɪt stˈændz` |
| c055 | train | 1.55 | 62 | 18 | bench/long-form/narrative-accomplice | and he sat up, | `ænd hi sˈæt ˌʌp,` |
| c064 | train | 1.55 | 62 | 9 | prose/docs/DESIGN.md | Runtime | `ɹˈʌntIm` |
| c068 | train | 1.55 | 62 | 12 | bench/long-form/technical-current-state | submission, | `səbmˈɪʃən,` |
| c074 | train | 1.55 | 62 | 13 | bench/long-form/narrative-accomplice | What's wrong? | `wˌʌts ɹˈɔŋ?` |
| c013 | train | 1.57 | 63 | 15 | short | Good morning. | `ɡˈʊd mˈɔɹnɪŋ.` |
| c029 | train | 1.57 | 63 | 13 | bench/paralinguistic | clear-throat | `ʔˈəm, ʔˈəm.` |
| c050 | holdout | 1.57 | 63 | 15 | bench/long-form/meter-algebra | find the Y, | `fˈInd ðə wˈI,` |
| c051 | train | 1.57 | 63 | 16 | prose/docs/SMA-SPEECH.md | Wang et al. | `wˈæŋɡ ˈɛt ˈæl.` |
| c076 | train | 1.57 | 63 | 13 | bench/long-form/technical-current-state | completion, | `kəmplˈiʃən,` |
| c098 | train | 1.57 | 63 | 19 | bench/long-form/meter-algebra | look at the board, | `lˈʊk æt ðə bˈɔɹd,` |
| c028 | holdout | 1.60 | 64 | 13 | bench/paralinguistic | cough-double | `kˈɑʔ, kˈɑʔ!` |
| c078 | train | 1.62 | 65 | 11 | prose/README.md | Licensing | `lˈIsᵊnsɪŋ` |
| c091 | train | 1.62 | 65 | 21 | prose/BRIEF.md | What should be added? | `wˌʌt ʃˌʊd bi ˈædᵻd?` |
| c107 | train | 1.62 | 65 | 13 | bench/long-form/narrative-accomplice | Tom froze. | `tˈɑm fɹˈOz.` |
| c033 | train | 1.65 | 66 | 16 | bench/long-form/meter-algebra | Find the X, | `fˈInd ði ˈɛks,` |
| c059 | train | 1.65 | 66 | 19 | prose/README.md | Kokoro-QNN | `kəkˈɔɹOkjˌuˌɛnˈɛn` |
| c012 | train | 1.68 | 67 | 14 | short | Yes, please. | `jˈɛs, plˈiz.` |
| c056 | train | 1.68 | 67 | 16 | bench/long-form/technical-current-state | floating point. | `flˈOTɪŋ pˈYnt.` |
| c095 | train | 1.68 | 67 | 18 | bench/long-form/meter-algebra | keeping the scale, | `kˈipɪŋ ðə skˈAl,` |
| c096 | train | 1.70 | 68 | 17 | bench/long-form/meter-algebra | Step by step, | `stˈɛp bI stˈɛp,` |
| c003 | holdout | 1.73 | 69 | 16 | short | Okay, thanks. | `ˌOkˈA, θˈæŋks.` |
| c063 | train | 1.73 | 69 | 18 | bench/long-form/narrative-accomplice | unspoken hell. | `ˌʌnspˈOkən hˈɛl.` |
| c097 | train | 1.73 | 69 | 22 | bench/long-form/meter-algebra | put it on a throne. | `pˌʊt ɪt ˌɔn ɐ θɹˈOn.` |
| c102 | train | 1.73 | 69 | 17 | prose/README.md | Configuration | `kənfˌɪɡjəɹˈAʃən` |
| c035 | train | 1.75 | 70 | 16 | prose/docs/DESIGN.md | Android host | `ˈændɹˌYd hˈOst` |
| c052 | holdout | 1.75 | 70 | 16 | bench/long-form/technical-current-state | presentation, | `pɹˌɛzᵊntˈAʃən,` |
| c085 | train | 1.75 | 70 | 18 | bench/long-form/technical-current-state | tensor buffers, | `tˈɛnsəɹ bˈʌfəɹz,` |
| c104 | train | 1.75 | 70 | 20 | bench/long-form/narrative-accomplice | The welding stopped. | `ðə wˈɛldɪŋ stˈɑpt.` |
| c105 | train | 1.75 | 70 | 15 | bench/long-form/meter-algebra | line by line, | `lˈIn bI lˈIn,` |
| c041 | holdout | 1.77 | 71 | 18 | prose/docs/MODEL-ASSEMBLY.md | Build from source | `bˈɪld fɹʌm sˈɔɹs` |
| c060 | holdout | 1.77 | 71 | 26 | bench/long-form/meter-algebra | We call it a variable, | `wˌi kˈɔl ɪt ɐ vˈɛɹiəbᵊl,` |
| c067 | train | 1.77 | 71 | 19 | bench/long-form/meter-algebra | solve the unknown, | `sˈɑlv ði ˌʌnnˈOn,` |
| c072 | train | 1.77 | 71 | 17 | prose/docs/APPLIANCE.md | Model boundary | `mˈɑdᵊl bˈWndəɹi` |
| c084 | holdout | 1.77 | 71 | 21 | bench/long-form/meter-algebra | Isolate the letter, | `ˈIsəlˌAt ðə lˈɛTəɹ,` |
| c086 | train | 1.80 | 72 | 19 | prose/docs/APPLIANCE.md | Evidence boundary | `ˈɛvədᵊns bˈWndəɹi` |
| c099 | holdout | 1.80 | 72 | 25 | bench/long-form/meter-algebra | It's all about balance, | `ˌɪts ˈɔl əbˈWt bˈæləns,` |
| c103 | train | 1.80 | 72 | 22 | bench/long-form/meter-algebra | let's break it down, | `lˈɛts bɹˈAk ɪt dˌWn,` |
| c077 | train | 1.85 | 74 | 25 | bench/long-form/narrative-accomplice | It wasn't a question. | `ˌɪt wˈʌzᵊnt ɐ kwˈɛsʧᵊn.` |
| c094 | train | 1.85 | 74 | 19 | prose/docs/SMA-SPEECH.md | Admission sequence | `ədmˈɪʃən sˈikwəns` |
| c054 | train | 1.88 | 75 | 25 | bench/long-form/narrative-accomplice | It was the same shuttle. | `ˌɪt wʌz ðə sˈAm ʃˈʌTᵊl.` |
| c061 | train | 1.88 | 75 | 24 | bench/long-form/technical-current-state | It measures synthesis, | `ˌɪt mˈɛʒəɹz sˈɪnθəsɪs,` |
| c021 | train | 1.90 | 76 | 18 | bench/corpus | yes, exactly. | `jˈɛs, ɪɡzˈæktli.` |
| c089 | holdout | 1.90 | 76 | 20 | prose/docs/SMA-SPEECH.md | Multiple speakers | `mˈʌltəpᵊl spˈikəɹz` |
| c048 | train | 1.93 | 77 | 20 | bench/long-form/meter-algebra | a mystery inside, | `ɐ mˈɪstəɹi ɪnsˈId,` |
| c066 | holdout | 1.93 | 77 | 22 | prose/docs/MODEL-ASSEMBLY.md | Verify on Windows | `vˈɛɹəfˌI ˌɔn wˈɪndOz` |
| c081 | train | 1.93 | 77 | 25 | prose/README.md | Android appliance build | `ˈændɹˌYd əplˈIəns bˈɪld` |
| c053 | train | 1.95 | 78 | 25 | prose/BRIEF.md | Questions for reviewers | `kwˈɛsʧᵊnz fɔɹ ɹəvjˈuəɹz` |
| c090 | train | 1.95 | 78 | 25 | bench/long-form/meter-algebra | till the answer is shown. | `tˈɪl ði ˈænsəɹ ɪz ʃˈOn.` |
| c092 | holdout | 1.95 | 78 | 28 | bench/long-form/narrative-accomplice | He let out a low whistle, | `hˌi lˈɛt ˈWt ɐ lˈO wˈɪsᵊl,` |
| c022 | train | 1.98 | 79 | 25 | bench/corpus | the benchmark is running. | `ðə bˈɛnʧmɑɹk ɪz ɹˈʌnɪŋ.` |
| c044 | holdout | 1.98 | 79 | 26 | bench/long-form/narrative-accomplice | The main lights were dimmed, | `ðə mˈAn lˈIts wɜɹ dˈɪmd,` |
| c062 | train | 2.02 | 81 | 21 | bench/long-form/narrative-accomplice | What's wrong? Tuvok. | `wˌʌts ɹˈɔŋ? tˈuvɑk.` |
| c108 | train | 2.05 | 82 | 21 | bench/long-form/narrative-accomplice | Tuvok. Tom froze. | `tˈuvɑk. tˈɑm fɹˈOz.` |
| c049 | holdout | 2.08 | 83 | 25 | prose/docs/MODEL-ASSEMBLY.md | Kokoro model assembly | `kəkˈɔɹO mˈɑdᵊl əsˈɛmbli` |
| c100 | train | 2.08 | 83 | 26 | prose/docs/WINDOWS-COMPUTE-NODE.md | Compatibility boundary | `kəmpˌæTəbˈɪləTi bˈWndəɹi` |
| c071 | train | 2.10 | 84 | 27 | prose/docs/APPLIANCE.md | Kokoro Android appliance | `kəkˈɔɹO ˈændɹˌYd əplˈIəns` |
| c036 | train | 2.12 | 85 | 32 | bench/long-form/narrative-accomplice | squinting to see who was there. | `skwˈɪntɪŋ tə sˈi hˌu wʌz ðˈɛɹ.` |
| c040 | train | 2.15 | 86 | 30 | bench/long-form/technical-current-state | and peak memory separately. | `ænd pˈik mˈɛməɹi sˈɛpəɹətli.` |
| c093 | train | 2.23 | 89 | 28 | prose/docs/SMA-SPEECH.md | Evidence admitted so far | `ˈɛvədᵊns ədmˈɪTᵻd sˌO fˈɑɹ` |
| c058 | train | 2.25 | 90 | 25 | prose/docs/WINDOWS-COMPUTE-NODE.md | Residency and latency | `ɹˈɛzədᵊnsi ænd lˈAtᵊnsi` |
| c020 | train | 2.30 | 92 | 32 | bench/phrases | hexagon | `ðɪs ɪz kˈoʊkəɹoʊ ɑn hɛksəɡˌɑn.` |
| c039 | train | 2.30 | 92 | 29 | prose/docs/SMA-SPEECH.md | SMA owns realization. | `ˌɛsˌɛmˈA ˈOnz ɹˌiᵊləzˈAʃən.` |
| c075 | holdout | 2.33 | 93 | 31 | bench/long-form/narrative-accomplice | understanding dawning slowly. | `ˌʌndəɹstˈændɪŋ dˈɔnɪŋ slˈOli.` |
| c037 | train | 2.38 | 95 | 34 | prose/BRIEF.md | Kokoro-QNN — review brief | `kəkˈɔɹOkjˌuˌɛnˈɛn — ɹəvjˈu bɹˈif` |
| c080 | train | 2.38 | 95 | 32 | prose/docs/APPLIANCE.md | Resident provider contract | `ɹˈɛzədᵊnt pɹəvˈIdəɹ kˈɑntɹˌækt` |
| c042 | train | 2.40 | 96 | 31 | prose/docs/DESIGN.md | Design and HTP findings | `dəzˈIn ænd ˌAʧtˌipˈi fˈIndɪŋz` |
| c047 | train | 2.40 | 96 | 40 | bench/long-form/narrative-accomplice | Of course he was still working on it. | `ˌʌv kˈɔɹs hi wʌz stˈɪl wˈɜɹkɪŋ ˌɔn ɪt.` |
| c106 | holdout | 2.40 | 96 | 35 | bench/long-form/narrative-accomplice | He knows. It wasn't a question. | `hˌi nˈOz. ˌɪt wˈʌzᵊnt ɐ kwˈɛsʧᵊn.` |
| c038 | train | 2.42 | 97 | 33 | prose/docs/SMA-SPEECH.md | SMA speech planning boundary | `ˌɛsˌɛmˈA spˈiʧ plˈænɪŋ bˈWndəɹi` |
| c069 | train | 2.42 | 97 | 33 | prose/BRIEF.md | Is VTCM sharing needed? | `ˌɪz vˌitˌisˌiˈɛm ʃˈɛɹɪŋ nˈidᵻd?` |
| c070 | holdout | 2.42 | 97 | 38 | bench/long-form/meter-algebra | Don't let the letters make you frown. | `dˈOnt lˈɛt ðə lˈɛTəɹz mˌAk ju fɹˈWn.` |
| c079 | train | 2.42 | 97 | 40 | bench/long-form/narrative-accomplice | The one he had used to kidnap her, | `ðə wˈʌn hi hæd jˈuzd tə kˈɪdnˌæp hˌɜɹ,` |
| c057 | train | 2.45 | 98 | 38 | bench/long-form/meter-algebra | A guest at the party trying to hide. | `ɐ ɡˈɛst æt ðə pˈɑɹTi tɹˈIɪŋ tə hˈId.` |
| c073 | train | 2.48 | 99 | 37 | bench/long-form/narrative-accomplice | He saw it on her face instantly. | `hˌi sˈɔ ɪt ˌɔn hɜɹ fˈAs ˈɪnstəntli.` |
| c134 | train | 2.50 | 100 | 34 | prose/README.md | Not yet done, stated plainly: | `nˌɑt jˈɛt dˈʌn, stˈATᵻd plˈAnli:` |
| c190 | train | 2.50 | 100 | 35 | prose/docs/WINDOWS-COMPUTE-NODE.md | Windows to Android compute node | `wˈɪndOz tʊ ˈændɹˌYd kəmpjˈut nˈOd` |
| c113 | train | 2.52 | 101 | 36 | bench/corpus | speech synthesis without the cloud. | `spˈiʧ sˈɪnθəsɪs wɪðˈaʊt ðə klˈaʊd.` |
| c114 | train | 2.58 | 103 | 38 | bench/corpus | every phrase is measured on the phone. | `ˈɛvɹi fɹˈeɪz ɪz mˈɛʒəɹd ɑn ðə fˈoʊn.` |
| c123 | train | 2.58 | 103 | 41 | bench/long-form/meter-algebra | Whatever you do to the left of the sign, | `wəTˈɛvəɹ ju dˈu tə ðə lˈɛft ʌv ðə sˈIn,` |
| c166 | train | 2.65 | 106 | 42 | bench/long-form/meter-algebra | It's all about balance, keeping the scale, | `ˌɪts ˈɔl əbˈWt bˈæləns, kˈipɪŋ ðə skˈAl,` |
| c176 | train | 2.65 | 106 | 35 | prose/BRIEF.md | Design decisions and their evidence | `dəzˈIn dəsˈɪʒᵊnz ænd ðɛɹ ˈɛvədᵊns` |
| c184 | holdout | 2.65 | 106 | 33 | bench/long-form/narrative-accomplice | What's wrong? Tuvok. Tom froze. | `wˌʌts ɹˈɔŋ? tˈuvɑk. tˈɑm fɹˈOz.` |
| c112 | train | 2.70 | 108 | 41 | bench/corpus | the decoder runs on the neural engine. | `ðə dɪkˈoʊdəɹ ɹˈʌnz ɑn ðə nˈʊɹəl ˈɛnʤɪn.` |
| c141 | train | 2.70 | 108 | 41 | prose/README.md | Hexagon portability expectation | `hˈɛksəɡˌɑn pˌɔɹTəbˈɪləTi ˌɛkspˌɛktˈAʃən` |
| c118 | train | 2.73 | 109 | 40 | prose/docs/DESIGN.md | Harmonic source on the host (for now) | `hɑɹmˈɑnɪk sˈɔɹs ˌɔn ðə hˈOst (fɔɹ nˈW)` |
| c121 | train | 2.73 | 109 | 42 | bench/long-form/meter-algebra | Isolate the letter, put it on a throne. | `ˈIsəlˌAt ðə lˈɛTəɹ, pˌʊt ɪt ˌɔn ɐ θɹˈOn.` |
| c193 | train | 2.75 | 110 | 41 | bench/long-form/meter-algebra | The goal of the game is to leave it alone, | `ðə ɡˈOl ʌv ðə ɡˈAm ɪz tə lˈiv ɪt əlˈOn,` |
| c150 | train | 2.83 | 113 | 41 | prose/README.md | No ONNX Runtime on the device. | `nˈO ˌOˌɛnˌɛnˈɛks ɹˈʌntIm ˌɔn ðə dəvˈIs.` |
| c159 | holdout | 2.83 | 113 | 45 | bench/long-form/meter-algebra | Do it to the right and you're doing just fine! | `dˈu ɪt tə ðə ɹˈIt ænd jʊɹ dˈuɪŋ ʤˈʌst fˈIn!` |
| c182 | train | 2.85 | 114 | 43 | bench/long-form/narrative-accomplice | He shielded his eyes against his own light, | `hˌi ʃˈildᵻd hɪz ˈIz əɡˈɛnst hɪz ˈOn lˈIt,` |
| c195 | train | 2.85 | 114 | 40 | prose/README.md | The generator is not yet real-time. | `ðə ʤˈɛnəɹˌATəɹ ɪz nˌɑt jˈɛt ɹˌiᵊltˈIm.` |
| c132 | train | 2.88 | 115 | 47 | bench/long-form/meter-algebra | See an X or a Y in the middle of the math? | `sˈi ɐn ˈɛks ɔɹ ɐ wˈI ɪn ðə mˈɪdᵊl ʌv ðə mˈæθ?` |
| c138 | train | 2.90 | 116 | 47 | bench/long-form/narrative-accomplice | He was on his back on a mechanic's creeper, | `hˌi wʌz ˌɔn hɪz bˈæk ˌɔn ɐ məkˈænɪks kɹˈipəɹ,` |
| c136 | holdout | 2.92 | 117 | 49 | bench/long-form/technical-current-state | The next test keeps the QNN contexts, | `ðə nˈɛkst tˈɛst kˈips ðə kjˌuˌɛnˈɛn kˈɑntɛksts,` |
| c170 | train | 2.95 | 118 | 46 | bench/long-form/meter-algebra | Yeah, look at the board, let's break it down, | `jˈɛə, lˈʊk æt ðə bˈɔɹd, lˈɛts bɹˈAk ɪt dˌWn,` |
| c124 | train | 2.98 | 119 | 49 | bench/long-form/meter-algebra | It's just a hidden number waiting on the path. | `ˌɪts ʤˈʌst ɐ hˈɪdᵊn nˈʌmbəɹ wˈATɪŋ ˌɔn ðə pˈæθ.` |
| c163 | holdout | 2.98 | 119 | 45 | bench/long-form/narrative-accomplice | The air smelled of ozone and engine coolant. | `ði ˈɛɹ smˈɛld ʌv ˈOzˌOn ænd ˈɛnʤən kˈulənt.` |
| c171 | train | 3.08 | 123 | 47 | prose/docs/SMA-SPEECH.md | They never enter visible or spoken text. | `ðˌA nˈɛvəɹ ˈɛntəɹ vˈɪzəbᵊl ɔɹ spˈOkən tˈɛkst.` |
| c139 | train | 3.10 | 124 | 45 | bench/long-form/meter-algebra | We call it a variable, a mystery inside, | `wˌi kˈɔl ɪt ɐ vˈɛɹiəbᵊl, ɐ mˈɪstəɹi ɪnsˈId,` |
| c165 | train | 3.10 | 124 | 47 | bench/long-form/technical-current-state | and audio stream alive for a complete passage. | `ænd ˈɔdiO stɹˈim əlˈIv fɔɹ ɐ kəmplˈit pˈæsɪʤ.` |
| c116 | train | 3.12 | 125 | 50 | bench/corpus | it speaks its own benchmark result out loud. | `ɪt spˈiks ɪts ˈoʊn bˈɛnʧmɑɹk ɹɪzˈʌlt ˈaʊt lˈaʊd.` |
| c128 | holdout | 3.12 | 125 | 44 | prose/docs/SMA-SPEECH.md | Neither repository proves a speech model. | `nˈiðəɹ ɹəpˈɑzətˌɔɹi pɹˈuvz ɐ spˈiʧ mˈɑdᵊl.` |
| c174 | holdout | 3.20 | 128 | 47 | bench/long-form/meter-algebra | Follow the golden rule and you will never fail. | `fˈɑlO ðə ɡˈOldən ɹˈul ænd ju wɪl nˈɛvəɹ fˈAl.` |
| c115 | train | 3.25 | 130 | 53 | bench/corpus | the quick brown fox jumps over the lazy dog. | `ðə kwˈɪk bɹˈaʊn fˈɑks ʤˈʌmps ˈoʊvəɹ ðə lˈeɪzi dˈɔɡ.` |
| c130 | train | 3.25 | 130 | 49 | bench/long-form/narrative-accomplice | He saw it on her face instantly. What's wrong? | `hˌi sˈɔ ɪt ˌɔn hɜɹ fˈAs ˈɪnstəntli. wˌʌts ɹˈɔŋ?` |
| c146 | train | 3.25 | 130 | 47 | bench/long-form/narrative-accomplice | wiping his hands on an already-filthy rag. | `wˈIpɪŋ hɪz hˈændz ˌɔn ɐn ˌɔlɹˈɛdifˌɪlθi ɹˈæɡ.` |
| c177 | train | 3.25 | 130 | 48 | bench/long-form/meter-algebra | Find the X, find the Y, solve the unknown, | `fˈInd ði ˈɛks, fˈInd ðə wˈI, sˈɑlv ði ˌʌnnˈOn,` |
| c111 | train | 3.27 | 131 | 47 | bench/phrases | baseline | `həlˈoʊ wˈɜɹld. ðɪs ɪz kˈoʊkəɹoʊ ɑn hɛksəɡˌɑn.` |
| c156 | train | 3.27 | 131 | 45 | prose/docs/SMA-SPEECH.md | Verify pronunciation and tensor bounds. | `vˈɛɹəfˌI pɹənˌʌnsiˈAʃən ænd tˈɛnsəɹ bˈWndz.` |
| c143 | train | 3.33 | 133 | 54 | bench/long-form/technical-current-state | it does not yet prove a quantized Kokoro model. | `ɪt dˈʌz nˌɑt jˈɛt pɹˈuv ɐ kwˈɑntˌIzd kəkˈɔɹO mˈɑdᵊl.` |
| c162 | train | 3.33 | 133 | 45 | prose/docs/DESIGN.md | Static capacity with masked normalization | `stˈæTɪk kəpˈæsəTi wɪð mˈæskt nˌɔɹmələzˈAʃən` |
| c127 | train | 3.42 | 137 | 52 | prose/BRIEF.md | CPU emulation of this design against float: | `sˌipˌijˈu ˌɛmjəlˈAʃən ʌv ðɪs dəzˈIn əɡˈɛnst flˈOt:` |
| c122 | train | 3.45 | 138 | 51 | prose/BRIEF.md | Planned architecture: fused table-lookup kernel | `plˈænd ˈɑɹkətˌɛkʧəɹ: fjˈuzd tˌAbᵊllˈʊkˌʌp kˈɜɹnᵊl` |
| c194 | holdout | 3.45 | 138 | 50 | prose/docs/FIRST-LIGHT.md | First vocalization (PowerShell iSTFT) | `fˈɜɹst vˌOkəlˌIzˈAʃən (pˈWəɹʃˌɛl ˌIˌɛstˌiˌɛftˈi)` |
| c189 | train | 3.48 | 139 | 58 | bench/long-form/narrative-accomplice | She found him in the cavernous quiet of Shuttle Bay 2. | `ʃˌi fˈWnd hˌɪm ɪn ðə kˈævəɹnəs kwˈIət ʌv ʃˈʌTᵊl bˈA tˈu.` |
| c158 | train | 3.52 | 141 | 52 | bench/long-form/narrative-accomplice | He searched her face, understanding dawning slowly. | `hˌi sˈɜɹʧt hɜɹ fˈAs, ˌʌndəɹstˈændɪŋ dˈɔnɪŋ slˈOli.` |
| c179 | train | 3.52 | 141 | 61 | prose/README.md | The front end and harmonic source still run on the host. | `ðə fɹˈʌnt ˈɛnd ænd hɑɹmˈɑnɪk sˈɔɹs stˈɪl ɹˈʌn ˌɔn ðə hˈOst.` |
| c133 | train | 3.55 | 142 | 55 | prose/docs/WINDOWS-COMPUTE-NODE.md | It is not part of the release command or data path. | `ˌɪt ɪz nˌɑt pˈɑɹt ʌv ðə ɹəlˈis kəmˈænd ɔɹ dˈATə pˈæθ.` |
| c173 | holdout | 3.55 | 142 | 58 | prose/docs/FIRST-LIGHT.md | First light — 2026-09-22 | `fˈɜɹst lˈIt — twˈɛnti twˈɛnti sˈɪkszˈɪɹO nˈIntwˌɛnti tˌu` |
| c181 | train | 3.58 | 143 | 55 | bench/long-form/meter-algebra | Step by step, line by line, till the answer is shown. | `stˈɛp bI stˈɛp, lˈIn bI lˈIn, tˈɪl ði ˈænsəɹ ɪz ʃˈOn.` |
| c155 | train | 3.60 | 144 | 52 | prose/README.md | The normal user path is a signed release APK. | `ðə nˈɔɹmᵊl jˈuzəɹ pˈæθ ɪz ɐ sˈInd ɹəlˈis ˌApˌikˈA.` |
| c149 | train | 3.62 | 145 | 52 | prose/docs/SMA-SPEECH.md | Lower one candidate through a reversible mutation. | `lˈOəɹ wˈʌn kˈændədˌAt θɹu ɐ ɹəvˈɜɹsəbᵊl mjutˈAʃən.` |
| c145 | train | 3.70 | 148 | 60 | prose/docs/DESIGN.md | Phrases are split at natural boundaries by the front end. | `fɹˈAzᵻz ɑɹ splˈɪt æt nˈæʧəɹᵊl bˈWndəɹiz bI ðə fɹˈʌnt ˈɛnd.` |
| c131 | train | 3.73 | 149 | 59 | prose/BRIEF.md | Status as of 2026-09-22. | `stˈATəs æz ʌv twˈɛnti twˈɛnti sˈɪkszˈɪɹO nˈIntwˌɛnti tˌu.` |
| c137 | holdout | 3.73 | 149 | 60 | bench/long-form/narrative-accomplice | Her footsteps on the deck plating were unnaturally loud. | `hˌɜɹ fˈʊtstˌɛps ˌɔn ðə dˈɛk plˈATɪŋ wɜɹ ˌʌnnˈæʧəɹəli lˈWd.` |
| c154 | train | 3.73 | 149 | 63 | bench/long-form/narrative-accomplice | She hesitated for a fraction of a second at the threshold. | `ʃˌi hˈɛzətˌATᵻd fɔɹ ɐ fɹˈækʃən ʌv ɐ sˈɛkənd æt ðə θɹˈɛʃhˌOld.` |
| c151 | train | 3.75 | 150 | 54 | prose/README.md | Build output is never written into the repository. | `bˈɪld ˈWtpˌʊt ɪz nˈɛvəɹ ɹˈɪtn ˈɪntu ðə ɹəpˈɑzətˌɔɹi.` |
| c140 | train | 3.77 | 151 | 58 | bench/long-form/narrative-accomplice | the focused hiss of a micro-welder echoing in the silence. | `ðə fˈOkəst hˈɪs ʌv ɐ mˈIkɹOwˌɛldəɹ ˈɛkOɪŋ ɪn ðə sˈIləns.` |
| c164 | train | 3.80 | 152 | 59 | prose/docs/DESIGN.md | 16 generator convs are dilated (3 and 5). | `sˌɪkstˈin ʤˈɛnəɹˌATəɹ kˈɑnvz ɑɹ dIlˈATᵻd (θɹˈi ænd fˈIv).` |
| c183 | train | 3.85 | 154 | 57 | prose/docs/MODEL-ASSEMBLY.md | The current controls are the deployed context boundaries: | `ðə kˈɜɹənt kəntɹˈOlz ɑɹ ðə dəplˈYd kˈɑntɛkst bˈWndəɹiz:` |
| c126 | train | 3.92 | 157 | 57 | bench/long-form/narrative-accomplice | He saw it on her face instantly. What's wrong? Tuvok. | `hˌi sˈɔ ɪt ˌɔn hɜɹ fˈAs ˈɪnstəntli. wˌʌts ɹˈɔŋ? tˈuvɑk.` |
| c135 | train | 3.92 | 157 | 59 | prose/README.md | Kokoro-82M weights and source are Apache-2.0. | `kəkˈɔɹO ˈATi tˈu ˈɛm wˈAts ænd sˈɔɹs ɑɹ əpˈæʧi tˈu zˈɪɹO.` |
| c167 | train | 3.92 | 157 | 57 | bench/long-form/narrative-accomplice | half-submerged beneath the shuttle's impulse engine housing, | `hˌæfsəbmˈɜɹʤd bənˈiθ ðə ʃˈʌTᵊlz ˈɪmpˌʌls ˈɛnʤən hˈWzɪŋ,` |
| c192 | train | 3.95 | 158 | 63 | prose/docs/SMA-SPEECH.md | The current implementation proves only the first two steps. | `ðə kˈɜɹənt ˌɪmpləməntˈAʃən pɹˈuvz ˈOnli ðə fˈɜɹst tˈu stˈɛps.` |
| c129 | train | 3.98 | 159 | 60 | prose/docs/SMA-SPEECH.md | Preserve authored text and reject malformed cue cards. | `pɹəzˈɜɹv ˈɔθəɹd tˈɛkst ænd ɹəʤˈɛkt mˌælfˈɔɹmd kjˈu kˈɑɹdz.` |
| c147 | train | 4.00 | 160 | 61 | bench/long-form/narrative-accomplice | a sound that was equal parts shock and grudging admiration. | `ɐ sˈWnd ðæt wʌz ˈikwᵊl pˈɑɹts ʃˈɑk ænd ɡɹˈʌʤɪŋ ˌædməɹˈAʃən.` |
| c197 | train | 4.00 | 160 | 59 | prose/docs/SMA-SPEECH.md | Their search and admission patterns are the reusable parts. | `ðˌɛɹ sˈɜɹʧ ænd ədmˈɪʃən pˈæTəɹnz ɑɹ ðə ɹijˈuzəbᵊl pˈɑɹts.` |
| c117 | holdout | 4.15 | 166 | 62 | prose/docs/WINDOWS-COMPUTE-NODE.md | The endpoint never evaluates source received from USB. | `ði ˈɛndpYnt nˈɛvəɹ əvˈæljʊˌAts sˈɔɹs ɹəsˈivd fɹʌm jˌuˌɛsbˈi.` |
| c160 | train | 4.15 | 166 | 61 | prose/docs/WINDOWS-COMPUTE-NODE.md | AOA is the control plane, not the DSP transport. | `ˌAˌOˈA ɪz ðə kəntɹˈOl plˈAn, nˌɑt ðə dˌiˌɛspˈi tɹˈænspˌɔɹt.` |
| c161 | holdout | 4.15 | 166 | 63 | prose/docs/SMA-SPEECH.md | Measure the physical device and play the result through the speaker. | `mˈɛʒəɹ ðə fˈɪzəkᵊl dəvˈIs ænd plˈA ðə ɹəzˈʌlt θɹu ðə spˈikəɹ.` |
| c119 | train | 4.17 | 167 | 72 | bench/long-form/narrative-accomplice | the one that had taken them past the known universe and into a shared, | `ðə wˈʌn ðæt hæd tˈAkən ðˌɛm pˈæst ðə nˈOn jˈunəvəɹs ænd ˈɪntu ɐ ʃˈɛɹd,` |
| c125 | holdout | 4.17 | 167 | 61 | prose/docs/SMA-SPEECH.md | These sources justify candidate features and test design. | `ðˌiz sˈɔɹsᵻz ʤˈʌstəfˌI kˈændədˌAt fˈiʧəɹz ænd tˈɛst dəzˈIn.` |
| c120 | holdout | 4.33 | 173 | 64 | bench/long-form/narrative-accomplice | Tom froze. He searched her face, understanding dawning slowly. | `tˈɑm fɹˈOz. hˌi sˈɜɹʧt hɜɹ fˈAs, ˌʌndəɹstˈændɪŋ dˈɔnɪŋ slˈOli.` |
| c187 | train | 4.35 | 174 | 67 | prose/docs/WINDOWS-COMPUTE-NODE.md | Control frames are limited to 256 KiB. | `kəntɹˈOl fɹˈAmz ɑɹ lˈɪməTᵻd tə tˈu hˈʌndɹəd fˈɪfti sˈɪks kˈI bˈi.` |
| c185 | train | 4.42 | 177 | 68 | prose/docs/SMA-SPEECH.md | Asterisks and ordinary square brackets have no special meaning. | `ˈæstəɹˌɪsks ænd ˈɔɹdᵊnˌɛɹi skwˈɛɹ bɹˈækəts hæv nˈO spˈɛʃᵊl mˈinɪŋ.` |
| c169 | holdout | 4.60 | 184 | 68 | prose/README.md | Build output and signing material remain outside the repository. | `bˈɪld ˈWtpˌʊt ænd sˈInɪŋ mətˈɪɹiəl ɹəmˈAn ˌWtsˈId ðə ɹəpˈɑzətˌɔɹi.` |
| c186 | train | 4.65 | 186 | 70 | prose/docs/DESIGN.md | 8 MB VTCM cut it further to 1.57 s. | `ˈAt ˌɛmbˈi vˌitˌisˌiˈɛm kˈʌt ɪt fˈɜɹðəɹ tə wˈʌn pYnt fˈIv sˈɛvən ˈɛs` |
| c168 | train | 4.70 | 188 | 74 | bench/long-form/narrative-accomplice | He shielded his eyes against his own light, squinting to see who was there. | `hˌi ʃˈildᵻd hɪz ˈIz əɡˈɛnst hɪz ˈOn lˈIt, skwˈɪntɪŋ tə sˈi hˌu wʌz ðˈɛɹ.` |
| c144 | train | 4.72 | 189 | 78 | prose/docs/APPLIANCE.md | An optional language or perception model sits in front of this contract. | `ɐn ˈɑpʃənᵊl lˈæŋɡwɪʤ ɔɹ pəɹsˈɛpʃən mˈɑdᵊl sˈɪts ɪn fɹˈʌnt ʌv ðɪs kˈɑntɹˌækt.` |
| c152 | holdout | 4.72 | 189 | 69 | prose/docs/MODEL-ASSEMBLY.md | No Python environment is involved in this managed assembly build. | `nˈO pˈIθˌɑn ənvˈIɹənmᵊnt ɪz ɪnvˈɑlvd ɪn ðɪs mˈænɪʤd əsˈɛmbli bˈɪld.` |
| c196 | train | 4.72 | 189 | 69 | bench/long-form/narrative-accomplice | He saw it on her face instantly. What's wrong? Tuvok. Tom froze. | `hˌi sˈɔ ɪt ˌɔn hɜɹ fˈAs ˈɪnstəntli. wˌʌts ɹˈɔŋ? tˈuvɑk. tˈɑm fɹˈOz.` |
| c180 | holdout | 4.83 | 193 | 79 | bench/long-form/narrative-accomplice | Her footsteps on the deck plating were unnaturally loud. The welding stopped. | `hˌɜɹ fˈʊtstˌɛps ˌɔn ðə dˈɛk plˈATɪŋ wɜɹ ˌʌnnˈæʧəɹəli lˈWd. ðə wˈɛldɪŋ stˈɑpt.` |
| c153 | train | 4.85 | 194 | 78 | bench/long-form/meter-algebra | A guest at the party trying to hide. The goal of the game is to leave it alone, | `ɐ ɡˈɛst æt ðə pˈɑɹTi tɹˈIɪŋ tə hˈId. ðə ɡˈOl ʌv ðə ɡˈAm ɪz tə lˈiv ɪt əlˈOn,` |
| c191 | train | 4.85 | 194 | 73 | bench/long-form/technical-current-state | That proves the instruction encoding and packed layout used by the probe; | `ðˈæt pɹˈuvz ði ɪnstɹˈʌkʃən ɛŋkˈOdɪŋ ænd pˈækt lˈAˌWt jˈuzd bI ðə pɹˈOb;` |
| c188 | holdout | 4.88 | 195 | 83 | bench/long-form/meter-algebra | Yeah, look at the board, let's break it down, Don't let the letters make you frown. | `jˈɛə, lˈʊk æt ðə bˈɔɹd, lˈɛts bɹˈAk ɪt dˌWn, dˈOnt lˈɛt ðə lˈɛTəɹz mˌAk ju fɹˈWn.` |
| c148 | train | 4.90 | 196 | 80 | prose/docs/MODEL-ASSEMBLY.md | From a verified checkout on Windows with PowerShell 7.4 or newer: | `fɹˌʌm ɐ vˈɛɹᵻfˌId ʧˈɛkˌWt ˌɔn wˈɪndOz wɪð pˈWəɹʃˌɛl sˈɛvən pYnt fˈɔɹ ɔɹ nˈuəɹ:` |
| c178 | train | 4.90 | 196 | 72 | bench/long-form/narrative-accomplice | Tuvok. Tom froze. He searched her face, understanding dawning slowly. | `tˈuvɑk. tˈɑm fɹˈOz. hˌi sˈɜɹʧt hɜɹ fˈAs, ˌʌndəɹstˈændɪŋ dˈɔnɪŋ slˈOli.` |
| c172 | train | 4.92 | 197 | 84 | bench/long-form/meter-algebra | Don't let the letters make you frown. See an X or a Y in the middle of the math? | `dˈOnt lˈɛt ðə lˈɛTəɹz mˌAk ju fɹˈWn. sˈi ɐn ˈɛks ɔɹ ɐ wˈI ɪn ðə mˈɪdᵊl ʌv ðə mˈæθ?` |
| c157 | train | 4.95 | 198 | 74 | prose/docs/MODEL-ASSEMBLY.md | These are tensor controls, not yet a stable public prosody API. | `ðˌiz ɑɹ tˈɛnsəɹ kəntɹˈOlz, nˌɑt jˈɛt ɐ stˈAbᵊl pˈʌblɪk pɹˈɑsədi ˌApˌiˈI.` |
| c142 | train | 4.97 | 199 | 82 | bench/long-form/meter-algebra | Isolate the letter, put it on a throne. Whatever you do to the left of the sign, | `ˈIsəlˌAt ðə lˈɛTəɹ, pˌʊt ɪt ˌɔn ɐ θɹˈOn. wəTˈɛvəɹ ju dˈu tə ðə lˈɛft ʌv ðə sˈIn,` |
| c175 | train | 4.97 | 199 | 85 | bench/long-form/meter-algebra | Whatever you do to the left of the sign, Do it to the right and you're doing just fine! | `wəTˈɛvəɹ ju dˈu tə ðə lˈɛft ʌv ðə sˈIn, dˈu ɪt tə ðə ɹˈIt ænd jʊɹ dˈuɪŋ ʤˈʌst fˈIn!` |
| c202 | train | 5.03 | 201 | 78 | bench/long-form/technical-current-state | One stream has accepted consecutive chunks without an observed underrun. | `wˈʌn stɹˈim hæz əksˈɛptᵻd kənsˈɛkjəTɪv ʧˈʌŋks wɪðˈWt ɐn əbzˈɜɹvd ˌʌndəɹɹˈʌn.` |
| c221 | train | 5.03 | 201 | 86 | bench/long-form/meter-algebra | Do it to the right and you're doing just fine! It's all about balance, keeping the scale, | `dˈu ɪt tə ðə ɹˈIt ænd jʊɹ dˈuɪŋ ʤˈʌst fˈIn! ˌɪts ˈɔl əbˈWt bˈæləns, kˈipɪŋ ðə skˈAl,` |
| c251 | holdout | 5.12 | 205 | 82 | bench/long-form/meter-algebra | The goal of the game is to leave it alone, Isolate the letter, put it on a throne. | `ðə ɡˈOl ʌv ðə ɡˈAm ɪz tə lˈiv ɪt əlˈOn, ˈIsəlˌAt ðə lˈɛTəɹ, pˌʊt ɪt ˌɔn ɐ θɹˈOn.` |
| c272 | train | 5.12 | 205 | 77 | prose/README.md | Host tools read these environment variables (no machine-specific defaults): | `hˈOst tˈulz ɹˈɛd ðiz ənvˈIɹənmᵊnt vˈɛɹiəbᵊlz (nˈO məʃˌinspəsˈɪfɪk dəfˈɔlts:` |
| c231 | train | 5.15 | 206 | 74 | prose/docs/SMA-SPEECH.md | Two local research repositories provide useful, bounded mechanisms: | `tˈu lˈOkəl ɹˈisˌɜɹʧ ɹəpˈɑzətˌɔɹiz pɹəvˈId jˈusfᵊl, bˈWndᵻd mˈɛkənˌɪzəmz:` |
| c245 | train | 5.22 | 209 | 87 | bench/long-form/narrative-accomplice | She hesitated for a fraction of a second at the threshold. It was the same shuttle. | `ʃˌi hˈɛzətˌATᵻd fɔɹ ɐ fɹˈækʃən ʌv ɐ sˈɛkənd æt ðə θɹˈɛʃhˌOld. ˌɪt wʌz ðə sˈAm ʃˈʌTᵊl.` |
| c271 | train | 5.28 | 211 | 83 | prose/docs/SMA-SPEECH.md | measured breathing and audio from 16 healthy North American English speakers. | `mˈɛʒəɹd bɹˈiðɪŋ ænd ˈɔdiO fɹʌm sˌɪkstˈin hˈɛlθi nˈɔɹθ əmˈɛɹəkᵊn ˈɪŋɡlɪʃ spˈikəɹz.` |
| c283 | train | 5.28 | 211 | 76 | prose/docs/APPLIANCE.md | Those claims remain gated on a signed APK and physical-device receipts. | `ðˌOz klˈAmz ɹəmˈAn ɡˈATᵻd ˌɔn ɐ sˈInd ˌApˌikˈA ænd fˈɪzəkᵊldəvˌIs ɹəsˈits.` |
| c303 | train | 5.28 | 211 | 82 | bench/long-form/meter-algebra | We call it a variable, a mystery inside, A guest at the party trying to hide. | `wˌi kˈɔl ɪt ɐ vˈɛɹiəbᵊl, ɐ mˈɪstəɹi ɪnsˈId, ɐ ɡˈɛst æt ðə pˈɑɹTi tɹˈIɪŋ tə hˈId.` |
| c293 | train | 5.30 | 212 | 86 | bench/long-form/narrative-accomplice | The creeper slid out, and he sat up, wiping his hands on an already-filthy rag. | `ðə kɹˈipəɹ slˈɪd ˈWt, ænd hi sˈæt ˌʌp, wˈIpɪŋ hɪz hˈændz ˌɔn ɐn ˌɔlɹˈɛdifˌɪlθi ɹˈæɡ.` |
| c204 | holdout | 5.35 | 214 | 84 | prose/docs/MODEL-ASSEMBLY.md | The model surface can be loaded and checked before an Android appliance is installed: | `ðə mˈɑdᵊl sˈɜɹfəs kæn bi lˈOdᵻd ænd ʧˈɛkt bəfˈɔɹ ɐn ˈændɹˌYd əplˈIəns ɪz ɪnstˈɔld:` |
| c276 | train | 5.35 | 214 | 83 | prose/docs/MODEL-ASSEMBLY.md | The current assembly proves a portable, source-identified model control surface. | `ðə kˈɜɹənt əsˈɛmbli pɹˈuvz ɐ pˈɔɹTəbᵊl, sˌɔɹsIdˈɛntəfˌId mˈɑdᵊl kəntɹˈOl sˈɜɹfəs.` |
| c279 | train | 5.35 | 214 | 80 | prose/docs/APPLIANCE.md | The current runtime consumes the pinned upstream Kokoro-82M checkpoint. | `ðə kˈɜɹənt ɹˈʌntIm kənsˈumz ðə pˈɪnd ˌʌpstɹˈim kəkˈɔɹO ˈATi tˈu ˈɛm ʧˈɛkpˌYnt.` |
| c230 | holdout | 5.40 | 216 | 83 | bench/long-form/narrative-accomplice | He shielded his eyes against his own light, squinting to see who was there. Captain? | `hˌi ʃˈildᵻd hɪz ˈIz əɡˈɛnst hɪz ˈOn lˈIt, skwˈɪntɪŋ tə sˈi hˌu wʌz ðˈɛɹ. kˈæptᵊn?` |
| c285 | train | 5.40 | 216 | 87 | prose/docs/SMA-SPEECH.md | They are explicit overrides and debug fixtures, not the normal authoring language. | `ðˌA ɑɹ ɪksplˈɪsət ˈOvəɹɹˌIdz ænd dˌibˈʌɡ fˈɪksʧəɹz, nˌɑt ðə nˈɔɹmᵊl ˈɔθəɹɪŋ lˈæŋɡwɪʤ.` |
| c217 | train | 5.50 | 220 | 88 | bench/long-form/meter-algebra | It's all about balance, keeping the scale, Follow the golden rule and you will never fail. | `ˌɪts ˈɔl əbˈWt bˈæləns, kˈipɪŋ ðə skˈAl, fˈɑlO ðə ɡˈOldən ɹˈul ænd ju wɪl nˈɛvəɹ fˈAl.` |
| c210 | train | 5.55 | 222 | 88 | bench/long-form/narrative-accomplice | He let out a low whistle, a sound that was equal parts shock and grudging admiration. | `hˌi lˈɛt ˈWt ɐ lˈO wˈɪsᵊl, ɐ sˈWnd ðæt wʌz ˈikwᵊl pˈɑɹts ʃˈɑk ænd ɡɹˈʌʤɪŋ ˌædməɹˈAʃən.` |
| c259 | train | 5.55 | 222 | 95 | bench/long-form/meter-algebra | See an X or a Y in the middle of the math? It's just a hidden number waiting on the path. | `sˈi ɐn ˈɛks ɔɹ ɐ wˈI ɪn ðə mˈɪdᵊl ʌv ðə mˈæθ? ˌɪts ʤˈʌst ɐ hˈɪdᵊn nˈʌmbəɹ wˈATɪŋ ˌɔn ðə pˈæθ.` |
| c290 | train | 5.55 | 222 | 84 | prose/docs/SMA-SPEECH.md | Pauses require an explicit duration from 20 to 5000 milliseconds. | `pˈɔzᵻz ɹəkwˈIəɹ ɐn ɪksplˈɪsət dʊɹˈAʃən fɹʌm twˈɛnti tə fˈIv θˈWzᵊnd mˈɪləsˌɛkəndz.` |
| c224 | train | 5.58 | 223 | 83 | prose/docs/WINDOWS-COMPUTE-NODE.md | The release APK still needs two gates before the Windows demo is ADB-free: | `ðə ɹəlˈis ˌApˌikˈA stˈɪl nˈidz tˈu ɡˈAts bəfˈɔɹ ðə wˈɪndOz dˈɛmO ɪz ˌAdˌibˈifɹˌi:` |
| c286 | train | 5.62 | 225 | 93 | prose/docs/SMA-SPEECH.md | Primary studies support the architecture, but not a universal fixed syllable limit: | `pɹˈImˌɛɹi stˈʌdiz səpˈɔɹt ði ˈɑɹkətˌɛkʧəɹ, bˌʌt nˌɑt ɐ jˌunəvˈɜɹsᵊl fˈɪkst sˈɪləbᵊl lˈɪmət:` |
| c288 | train | 5.62 | 225 | 87 | bench/long-form/narrative-accomplice | his expression shifting from surprise to immediate concern as she stepped into the light. | `hɪz ɪkspɹˈɛʃən ʃˈɪftɪŋ fɹʌm səɹpɹˈIz tʊ ɪmˈidiət kənsˈɜɹn æz ʃi stˈɛpt ˈɪntu ðə lˈIt.` |
| c213 | train | 5.67 | 227 | 93 | bench/long-form/meter-algebra | It's just a hidden number waiting on the path. We call it a variable, a mystery inside, | `ˌɪts ʤˈʌst ɐ hˈɪdᵊn nˈʌmbəɹ wˈATɪŋ ˌɔn ðə pˈæθ. wˌi kˈɔl ɪt ɐ vˈɛɹiəbᵊl, ɐ mˈɪstəɹi ɪnsˈId,` |
| c260 | train | 5.67 | 227 | 94 | bench/long-form/narrative-accomplice | but a portable floodlight cast a harsh glare on the sleek hull of the shuttlecraft Cochrane. | `bˌʌt ɐ pˈɔɹTəbᵊl flˈʌdlˌIt kˈæst ɐ hˈɑɹʃ ɡlˈɛɹ ˌɔn ðə slˈik hˈʌl ʌv ðə ʃˈʌTᵊlkɹˌæft kˈɑkɹAn.` |
| c298 | holdout | 5.67 | 227 | 84 | bench/long-form/narrative-accomplice | What's wrong? Tuvok. Tom froze. He searched her face, understanding dawning slowly. | `wˌʌts ɹˈɔŋ? tˈuvɑk. tˈɑm fɹˈOz. hˌi sˈɜɹʧt hɜɹ fˈAs, ˌʌndəɹstˈændɪŋ dˈɔnɪŋ slˈOli.` |
| c220 | train | 5.70 | 228 | 86 | prose/docs/MODEL-ASSEMBLY.md | Python remains host-only export tooling when weights or tensor graph shapes change. | `pˈIθˌɑn ɹəmˈAnz hˌOstˈOnli ˈɛkspˌɔɹt tˈulɪŋ wˌɛn wˈAts ɔɹ tˈɛnsəɹ ɡɹˈæf ʃˈAps ʧˈAnʤ.` |
| c273 | train | 5.72 | 229 | 91 | prose/docs/SMA-SPEECH.md | This supports planning a recharge from both remaining state and upcoming linguistic load. | `ðˌɪs səpˈɔɹts plˈænɪŋ ɐ ɹˈiʧˌɑɹʤ fɹʌm bˈOθ ɹəmˈAnɪŋ stˈAt ænd ˌʌpkˈʌmɪŋ lɪŋɡwˈɪstɪk lˈOd.` |
| c256 | train | 5.88 | 235 | 94 | prose/docs/SMA-SPEECH.md | Produce speech-act, boundary, state, and prominence candidates without changing authored text. | `pɹədˈus spˈiʧˌækt, bˈWndəɹi, stˈAt, ænd pɹˈɑmənᵊns kˈændədˌAts wɪðˈWt ʧˈAnʤɪŋ ˈɔθəɹd tˈɛkst.` |
| c226 | train | 6.00 | 240 | 94 | bench/long-form/meter-algebra | Follow the golden rule and you will never fail. Find the X, find the Y, solve the unknown, | `fˈɑlO ðə ɡˈOldən ɹˈul ænd ju wɪl nˈɛvəɹ fˈAl. fˈInd ði ˈɛks, fˈInd ðə wˈI, sˈɑlv ði ˌʌnnˈOn,` |
| c222 | train | 6.03 | 241 | 97 | prose/BRIEF.md | For int16 storage, index by the high 8 bits and interpolate with the low 8 bits. | `fˌɔɹ ˈɪnt sˈɪkstin stˈɔɹɪʤ, ˈɪndˌɛks bI ðə hˈI ˈAt bˈɪts ænd ɪntˈɜɹpəlˌAt wɪð ðə lˈO ˈAt bˈɪts.` |
| c206 | holdout | 6.15 | 246 | 94 | prose/docs/APPLIANCE.md | The product is a speech application with an embedded, deliberately reduced PowerShell runtime. | `ðə pɹˈɑdˌʌkt ɪz ɐ spˈiʧ ˌæpləkˈAʃən wɪð ɐn əmbˈɛdᵻd, dəlˈɪbəɹətli ɹədˈust pˈWəɹʃˌɛl ɹˈʌntIm.` |
| c243 | train | 6.15 | 246 | 94 | bench/long-form/technical-current-state | The PowerShell runspace binds Android's native AAudio interface at twenty-four kilohertz, | `ðə pˈWəɹʃˌɛl ɹˈʌnspAs bˈIndz ˈændɹˌYdz nˈATɪv ˈAˌɔdiO ˈɪntəɹfˌAs æt twˈɛntifˌɔɹ kˈɪləhˌɜɹts,` |
| c225 | train | 6.17 | 247 | 100 | prose/README.md | The front end and harmonic source still run on the host. The generator is not yet real-time. | `ðə fɹˈʌnt ˈɛnd ænd hɑɹmˈɑnɪk sˈɔɹs stˈɪl ɹˈʌn ˌɔn ðə hˈOst. ðə ʤˈɛnəɹˌATəɹ ɪz nˌɑt jˈɛt ɹˌiᵊltˈIm.` |
| c297 | train | 6.25 | 250 | 94 | prose/docs/WINDOWS-COMPUTE-NODE.md | V73 compatibility is not inferred from a marketing name or Android version. | `vˈi sˈɛvənti θɹˈi kəmpˌæTəbˈɪləTi ɪz nˌɑt ɪnfˈɜɹd fɹʌm ɐ mˈɑɹkəTɪŋ nˈAm ɔɹ ˈændɹˌYd vˈɜɹʒən.` |
| c264 | holdout | 6.35 | 254 | 98 | bench/long-form/narrative-accomplice | He let out a low whistle, a sound that was equal parts shock and grudging admiration. He knows. | `hˌi lˈɛt ˈWt ɐ lˈO wˈɪsᵊl, ɐ sˈWnd ðæt wʌz ˈikwᵊl pˈɑɹts ʃˈɑk ænd ɡɹˈʌʤɪŋ ˌædməɹˈAʃən. hˌi nˈOz.` |
| c265 | train | 6.35 | 254 | 98 | bench/long-form/narrative-accomplice | He stood, his expression shifting from surprise to immediate concern as she stepped into the light. | `hˌi stˈʊd, hɪz ɪkspɹˈɛʃən ʃˈɪftɪŋ fɹʌm səɹpɹˈIz tʊ ɪmˈidiət kənsˈɜɹn æz ʃi stˈɛpt ˈɪntu ðə lˈIt.` |
| c281 | train | 6.40 | 256 | 97 | prose/docs/SMA-SPEECH.md | Wang et al. measured breathing and audio from 16 healthy North American English speakers. | `wˈæŋɡ ˈɛt ˈæl mˈɛʒəɹd bɹˈiðɪŋ ænd ˈɔdiO fɹʌm sˌɪkstˈin hˈɛlθi nˈɔɹθ əmˈɛɹəkᵊn ˈɪŋɡlɪʃ spˈikəɹz.` |
| c232 | train | 6.45 | 258 | 104 | prose/docs/SMA-SPEECH.md | Contour labels and word-count planning budgets are explicitly provisional until later gates pass. | `kˈɑntˌʊɹ lˈAbəlz ænd wˌɜɹdkˈWnt plˈænɪŋ bˈʌʤəts ɑɹ ɪksplˈɪsətli pɹəvˈɪʒᵊnəl ˌʌntˈɪl lˈATəɹ ɡˈAts pˈæs.` |
| c240 | train | 6.55 | 262 | 104 | prose/docs/APPLIANCE.md | PowerShell is an implementation substrate, not a permission boundary or a USB command language. | `pˈWəɹʃˌɛl ɪz ɐn ˌɪmpləməntˈAʃən sˈʌbstɹˌAt, nˌɑt ɐ pəɹmˈɪʃən bˈWndəɹi ɔɹ ɐ jˌuˌɛsbˈi kəmˈænd lˈæŋɡwɪʤ.` |
| c262 | train | 6.55 | 262 | 105 | bench/long-form/narrative-accomplice | The welding stopped. The creeper slid out, and he sat up, wiping his hands on an already-filthy rag. | `ðə wˈɛldɪŋ stˈɑpt. ðə kɹˈipəɹ slˈɪd ˈWt, ænd hi sˈæt ˌʌp, wˈIpɪŋ hɪz hˈændz ˌɔn ɐn ˌɔlɹˈɛdifˌɪlθi ɹˈæɡ.` |
| c208 | train | 6.62 | 265 | 108 | prose/README.md | The script is the reproducible builder path and prints its complete write plan before creating anything. | `ðə skɹˈɪpt ɪz ðə ɹˌipɹədˈusəbᵊl bˈɪldəɹ pˈæθ ænd pɹˈɪnts ɪts kəmplˈit ɹˈIt plˈæn bəfˈɔɹ kɹiˈATɪŋ ˈɛniθˌɪŋ.` |
| c212 | train | 6.70 | 268 | 108 | prose/README.md | The emitted kernels deliberately target the V73 scalar and HVX instruction subset. | `ði əmˈɪTᵻd kˈɜɹnᵊlz dəlˈɪbəɹətli tˈɑɹɡət ðə vˈi sˈɛvənti θɹˈi skˈAləɹ ænd ˌAʧvˌiˈɛks ɪnstɹˈʌkʃən sˈʌbsˌɛt.` |
| c211 | holdout | 6.78 | 271 | 102 | prose/docs/SMA-SPEECH.md | Neither repository proves a speech model. Their search and admission patterns are the reusable parts. | `nˈiðəɹ ɹəpˈɑzətˌɔɹi pɹˈuvz ɐ spˈiʧ mˈɑdᵊl. ðˌɛɹ sˈɜɹʧ ænd ədmˈɪʃən pˈæTəɹnz ɑɹ ðə ɹijˈuzəbᵊl pˈɑɹts.` |
| c228 | train | 6.78 | 271 | 104 | prose/BRIEF.md | Per-op int8 costs 12.5 dB log-mel; per-op int16 2.28 dB. | `pˌɜɹˈɑp ˈɪnt ˈAt kˈɔsts twˈɛlv pYnt fˈIv dˌibˈi lˈɔɡmˈɛl; pɜɹˈɑp ˈɪnt sˈɪkstin tˈu pYnt tˈu ˈAt dˌibˈi` |
| c287 | train | 6.83 | 273 | 102 | prose/README.md | Kokoro's whole decoder ran on HTP, iSTFT included, from the AndroidSMA runspace. | `kəkˈɔɹOz hˈOl dˌikˈOdəɹ ɹˈæn ˌɔn ˌAʧtˌipˈi, ˌIˌɛstˌiˌɛftˈi ɪnklˈudᵻd, fɹʌm ði ˈændɹˌYdsmˌɑ ɹˈʌnspAs.` |
| c216 | holdout | 6.95 | 278 | 112 | bench/long-form/technical-current-state | The next test keeps the QNN contexts, tensor buffers, and audio stream alive for a complete passage. | `ðə nˈɛkst tˈɛst kˈips ðə kjˌuˌɛnˈɛn kˈɑntɛksts, tˈɛnsəɹ bˈʌfəɹz, ænd ˈɔdiO stɹˈim əlˈIv fɔɹ ɐ kəmplˈit pˈæsɪʤ.` |
| c269 | holdout | 6.97 | 279 | 109 | prose/docs/WINDOWS-COMPUTE-NODE.md | A speaker change selects a style input; it does not reload the 82M model or the compiled graphs. | `ɐ spˈikəɹ ʧˈAnʤ səlˈɛkts ɐ stˈIl ˈɪnpˌʊt; ɪt dˈʌz nˌɑt ɹilˈOd ði ˈATi tˈu ˈɛm mˈɑdᵊl ɔɹ ðə kəmpˈIld ɡɹˈæfz.` |
| c307 | holdout | 7.00 | 280 | 107 | bench/long-form/narrative-accomplice | Captain? He stood, his expression shifting from surprise to immediate concern as she stepped into the light. | `kˈæptᵊn? hˌi stˈʊd, hɪz ɪkspɹˈɛʃən ʃˈɪftɪŋ fɹʌm səɹpɹˈIz tʊ ɪmˈidiət kənsˈɜɹn æz ʃi stˈɛpt ˈɪntu ðə lˈIt.` |
| c266 | train | 7.10 | 284 | 119 | bench/long-form/narrative-accomplice | The main lights were dimmed, but a portable floodlight cast a harsh glare on the sleek hull of the shuttlecraft Cochrane. | `ðə mˈAn lˈIts wɜɹ dˈɪmd, bˌʌt ɐ pˈɔɹTəbᵊl flˈʌdlˌIt kˈæst ɐ hˈɑɹʃ ɡlˈɛɹ ˌɔn ðə slˈik hˈʌl ʌv ðə ʃˈʌTᵊlkɹˌæft kˈɑkɹAn.` |
| c219 | train | 7.15 | 286 | 114 | prose/docs/APPLIANCE.md | The build graph separately proves that the admitted operation tree persists into the generated entry assembly. | `ðə bˈɪld ɡɹˈæf sˈɛpəɹətli pɹˈuvz ðæt ði ədmˈɪTᵻd ˌɑpəɹˈAʃən tɹˈi pəɹsˈɪsts ˈɪntu ðə ʤˈɛnəɹˌATᵻd ˈɛntɹi əsˈɛmbli.` |
| c239 | train | 7.15 | 286 | 100 | prose/README.md | LLVM also assigns distinct Hexagon ELF ISA identifiers to later revisions. | `ˌɛlˌɛlvˌiˈɛm ˈɔlsO əsˈInz dəstˈɪŋkt hˈɛksəɡˌɑn ˌiˌɛlˈɛf ˌIˌɛsˈA IdˈɛntəfˌIəɹz tə lˈATəɹ ɹəvˈɪʒᵊnz.` |
| c306 | train | 7.20 | 288 | 106 | bench/long-form/technical-current-state | Kokoro-Hexagon runs the Kokoro eighty-two-million-parameter speech model on a Galaxy S23. | `kəkˈɔɹOhˈɛksæɡən ɹˈʌnz ðə kəkˈɔɹO ˌATitˌumˈɪljᵊnpəɹˈæməTəɹ spˈiʧ mˈɑdᵊl ˌɔn ɐ ɡˈæləksi ˈɛs twˈɛnti θɹˈi.` |
| c270 | train | 7.25 | 290 | 118 | prose/docs/SMA-SPEECH.md | Their results support context-conditioned prosody while also leaving a gap between predicted and oracle prosody. | `ðˌɛɹ ɹəzˈʌlts səpˈɔɹt kˌɑntɛkstkəndˈɪʃənd pɹˈɑsədi wˌIl ˈɔlsO lˈivɪŋ ɐ ɡˈæp bətwˈin pɹidˈɪktᵻd ænd ˈɔɹəkᵊl pɹˈɑsədi.` |
| c255 | holdout | 7.28 | 291 | 114 | prose/docs/DESIGN.md | Error against the full-length model: 24.2 dB SNR, 0.62 dB log-mel. | `ˈɛɹəɹ əɡˈɛnst ðə fˌʊllˈɛŋθ mˈɑdᵊl: twˈɛnti fˈɔɹ pYnt tˈu dˌibˈi ˌɛsˌɛnˈɑɹ, zˈɪɹO pYnt sˈɪks tˈu dˌibˈi lˈɔɡmˈɛl.` |
| c263 | train | 7.28 | 291 | 120 | prose/docs/DESIGN.md | It is computed on the host and passed to the generator as an input, so the HTP graph has no random ops. | `ˌɪt ɪz kəmpjˈuTᵻd ˌɔn ðə hˈOst ænd pˈæst tə ðə ʤˈɛnəɹˌATəɹ æz ɐn ˈɪnpˌʊt, sˌO ði ˌAʧtˌipˈi ɡɹˈæf hæz nˈO ɹˈændəm ˈɑps.` |
| c304 | train | 7.28 | 291 | 128 | bench/long-form/narrative-accomplice | The one he had used to kidnap her, the one that had taken them past the known universe and into a shared, unspoken hell. | `ðə wˈʌn hi hæd jˈuzd tə kˈɪdnˌæp hˌɜɹ, ðə wˈʌn ðæt hæd tˈAkən ðˌɛm pˈæst ðə nˈOn jˈunəvəɹs ænd ˈɪntu ɐ ʃˈɛɹd, ˌʌnspˈOkən hˈɛl.` |
| c235 | train | 7.33 | 293 | 126 | bench/long-form/meter-algebra | Whatever you do to the left of the sign, Do it to the right and you're doing just fine! It's all about balance, keeping the scale, | `wəTˈɛvəɹ ju dˈu tə ðə lˈɛft ʌv ðə sˈIn, dˈu ɪt tə ðə ɹˈIt ænd jʊɹ dˈuɪŋ ʤˈʌst fˈIn! ˌɪts ˈɔl əbˈWt bˈæləns, kˈipɪŋ ðə skˈAl,` |
| c214 | train | 7.35 | 294 | 116 | bench/long-form/technical-current-state | The PowerShell runspace binds Android's native AAudio interface at twenty-four kilohertz, mono, floating point. | `ðə pˈWəɹʃˌɛl ɹˈʌnspAs bˈIndz ˈændɹˌYdz nˈATɪv ˈAˌɔdiO ˈɪntəɹfˌAs æt twˈɛntifˌɔɹ kˈɪləhˌɜɹts, mˈɑnO, flˈOTɪŋ pˈYnt.` |
| c244 | train | 7.35 | 294 | 114 | prose/docs/SMA-SPEECH.md | Compare blinded or paired listening judgments and retain the full outcome ledger, including rejected candidates. | `kəmpˈɛɹ blˈIndᵻd ɔɹ pˈɛɹd lˈɪsənɪŋ ʤˈʌʤmənts ænd ɹətˈAn ðə fˈʊl ˈWtkˌʌm lˈɛʤəɹ, ɪnklˈudɪŋ ɹəʤˈɛktᵻd kˈændədˌAts.` |
| c250 | train | 7.38 | 295 | 112 | prose/docs/SMA-SPEECH.md | Boundary tone and final pitch differed with intended speech act, showing why punctuation alone is insufficient. | `bˈWndəɹi tˈOn ænd fˈInᵊl pˈɪʧ dˈɪfəɹd wɪð ɪntˈɛndᵻd spˈiʧ ˈækt, ʃˈOɪŋ wˌI pˌʌŋkʧəwˈAʃən əlˈOn ɪz ˌɪnsəfˈɪʃənt.` |
| c218 | train | 7.40 | 296 | 106 | prose/docs/SMA-SPEECH.md | Contrastive focus changed F0 excursion, while lively affect also changed duration and amplitude. | `kəntɹˈæstɪv fˈOkəs ʧˈAnʤd ˈɛf zˈɪɹO ɪkskˈɜɹʒən, wˌIl lˈIvli əfˈɛkt ˈɔlsO ʧˈAnʤd dʊɹˈAʃən ænd ˈæmplətˌud.` |
| c295 | train | 7.42 | 297 | 126 | bench/long-form/meter-algebra | Isolate the letter, put it on a throne. Whatever you do to the left of the sign, Do it to the right and you're doing just fine! | `ˈIsəlˌAt ðə lˈɛTəɹ, pˌʊt ɪt ˌɔn ɐ θɹˈOn. wəTˈɛvəɹ ju dˈu tə ðə lˈɛft ʌv ðə sˈIn, dˈu ɪt tə ðə ɹˈIt ænd jʊɹ dˈuɪŋ ʤˈʌst fˈIn!` |
| c274 | holdout | 7.47 | 299 | 114 | prose/docs/WINDOWS-COMPUTE-NODE.md | QNN still uses the device's pinned HTP runtime and its platform DSP transport internally. | `kjˌuˌɛnˈɛn stˈɪl jˈuzᵻz ðə dəvˈIsᵻz pˈɪnd ˌAʧtˌipˈi ɹˈʌntIm ænd ɪts plˈætfˌɔɹm dˌiˌɛspˈi tɹˈænspˌɔɹt ɪntˈɜɹnəli.` |
| c291 | train | 7.47 | 299 | 122 | bench/long-form/meter-algebra | The goal of the game is to leave it alone, Isolate the letter, put it on a throne. Whatever you do to the left of the sign, | `ðə ɡˈOl ʌv ðə ɡˈAm ɪz tə lˈiv ɪt əlˈOn, ˈIsəlˌAt ðə lˈɛTəɹ, pˌʊt ɪt ˌɔn ɐ θɹˈOn. wəTˈɛvəɹ ju dˈu tə ðə lˈɛft ʌv ðə sˈIn,` |
| c207 | train | 7.50 | 300 | 112 | prose/docs/WINDOWS-COMPUTE-NODE.md | Capacity contexts, voice style tables, tensor arenas, and the AAudio stream stay resident across turns. | `kəpˈæsəTi kˈɑntɛksts, vˈYs stˈIl tˈAbᵊlz, tˈɛnsəɹ əɹˈinəz, ænd ði ˈAˌɔdiO stɹˈim stˈA ɹˈɛzədᵊnt əkɹˈɔs tˈɜɹnz.` |
| c299 | train | 7.58 | 303 | 132 | bench/long-form/meter-algebra | Don't let the letters make you frown. See an X or a Y in the middle of the math? It's just a hidden number waiting on the path. | `dˈOnt lˈɛt ðə lˈɛTəɹz mˌAk ju fɹˈWn. sˈi ɐn ˈɛks ɔɹ ɐ wˈI ɪn ðə mˈɪdᵊl ʌv ðə mˈæθ? ˌɪts ʤˈʌst ɐ hˈɪdᵊn nˈʌmbəɹ wˈATɪŋ ˌɔn ðə pˈæθ.` |
| c252 | holdout | 7.62 | 305 | 129 | bench/long-form/meter-algebra | Yeah, look at the board, let's break it down, Don't let the letters make you frown. See an X or a Y in the middle of the math? | `jˈɛə, lˈʊk æt ðə bˈɔɹd, lˈɛts bɹˈAk ɪt dˌWn, dˈOnt lˈɛt ðə lˈɛTəɹz mˌAk ju fɹˈWn. sˈi ɐn ˈɛks ɔɹ ɐ wˈI ɪn ðə mˈɪdᵊl ʌv ðə mˈæθ?` |
| c275 | train | 7.70 | 308 | 123 | bench/long-form/technical-current-state | The current end-to-end speech path uses precompiled FP16 QNN contexts on the Hexagon processor. | `ðə kˈɜɹənt ˈɛndtʊˈɛnd spˈiʧ pˈæθ jˈuzᵻz pɹˌikəmpˈIld ˌɛfpˈi sˌɪkstˈin kjˌuˌɛnˈɛn kˈɑntɛksts ˌɔn ðə hˈɛksəɡˌɑn pɹˈɑsˌɛsəɹ.` |
| c268 | train | 7.83 | 313 | 122 | bench/long-form/meter-algebra | We call it a variable, a mystery inside, A guest at the party trying to hide. The goal of the game is to leave it alone, | `wˌi kˈɔl ɪt ɐ vˈɛɹiəbᵊl, ɐ mˈɪstəɹi ɪnsˈId, ɐ ɡˈɛst æt ðə pˈɑɹTi tɹˈIɪŋ tə hˈId. ðə ɡˈOl ʌv ðə ɡˈAm ɪz tə lˈiv ɪt əlˈOn,` |
| c305 | train | 7.83 | 313 | 123 | prose/docs/MODEL-ASSEMBLY.md | Text-to-phoneme lowering must pass a differential corpus gate before it becomes part of the persisted assembly API. | `tˈɛksttəfˈOnˌim lˈOəɹɪŋ mˈʌst pˈæs ɐ dˌɪfəɹˈɛnʧᵊl kˈɔɹpəs ɡˈAt bəfˈɔɹ ɪt bəkˈʌmz pˈɑɹt ʌv ðə pəɹsˈɪstᵻd əsˈɛmbli ˌApˌiˈI.` |
| c227 | train | 7.85 | 314 | 123 | prose/README.md | Integer (w8a16) compilation does not finalize yet; the fp16 path is the one that runs. | `ˈɪntəʤəɹ (dˈʌbᵊlju ˈAt ˈA sˌɪkstˈin) kˌɑmpəlˈAʃən dˈʌz nˌɑt fˈInᵊlˌIz jˈɛt; ðə ˌɛfpˈi sˈɪkstin pˈæθ ɪz ðə wˈʌn ðæt ɹˈʌnz.` |
| c241 | train | 7.85 | 314 | 121 | prose/docs/WINDOWS-COMPUTE-NODE.md | The interactive Windows loop may look like a REPL, but the wire carries typed operations rather than PowerShell source. | `ði ˌɪntəɹˈæktɪv wˈɪndOz lˈup mˈA lˈʊk lˈIk ɐ ɹˈɛpᵊl, bˌʌt ðə wˈIəɹ kˈɛɹiz tˈIpd ˌɑpəɹˈAʃənz ɹˈæðəɹ ðən pˈWəɹʃˌɛl sˈɔɹs.` |
| c261 | train | 7.85 | 314 | 126 | bench/long-form/technical-current-state | That proves the instruction encoding and packed layout used by the probe; it does not yet prove a quantized Kokoro model. | `ðˈæt pɹˈuvz ði ɪnstɹˈʌkʃən ɛŋkˈOdɪŋ ænd pˈækt lˈAˌWt jˈuzd bI ðə pɹˈOb; ɪt dˈʌz nˌɑt jˈɛt pɹˈuv ɐ kwˈɑntˌIzd kəkˈɔɹO mˈɑdᵊl.` |
| c278 | train | 7.85 | 314 | 120 | prose/docs/WINDOWS-COMPUTE-NODE.md | The Windows client sends only the next plan and required inputs, with one pending audio chunk allowed on device. | `ðə wˈɪndOz klˈIənt sˈɛndz ˈOnli ðə nˈɛkst plˈæn ænd ɹəkwˈIəɹd ˈɪnpˌʊts, wɪð wˈʌn pˈɛndɪŋ ˈɔdiO ʧˈʌŋk əlˈWd ˌɔn dəvˈIs.` |
| c237 | train | 7.97 | 319 | 120 | bench/long-form/narrative-accomplice | He saw it on her face instantly. What's wrong? Tuvok. Tom froze. He searched her face, understanding dawning slowly. | `hˌi sˈɔ ɪt ˌɔn hɜɹ fˈAs ˈɪnstəntli. wˌʌts ɹˈɔŋ? tˈuvɑk. tˈɑm fɹˈOz. hˌi sˈɜɹʧt hɜɹ fˈAs, ˌʌndəɹstˈændɪŋ dˈɔnɪŋ slˈOli.` |
| c209 | train | 8.03 | 321 | 132 | bench/long-form/meter-algebra | Do it to the right and you're doing just fine! It's all about balance, keeping the scale, Follow the golden rule and you will never fail. | `dˈu ɪt tə ðə ɹˈIt ænd jʊɹ dˈuɪŋ ʤˈʌst fˈIn! ˌɪts ˈɔl əbˈWt bˈæləns, kˈipɪŋ ðə skˈAl, fˈɑlO ðə ɡˈOldən ɹˈul ænd ju wɪl nˈɛvəɹ fˈAl.` |
| c258 | train | 8.35 | 334 | 135 | bench/long-form/meter-algebra | It's all about balance, keeping the scale, Follow the golden rule and you will never fail. Find the X, find the Y, solve the unknown, | `ˌɪts ˈɔl əbˈWt bˈæləns, kˈipɪŋ ðə skˈAl, fˈɑlO ðə ɡˈOldən ɹˈul ænd ju wɪl nˈɛvəɹ fˈAl. fˈInd ði ˈɛks, fˈInd ðə wˈI, sˈɑlv ði ˌʌnnˈOn,` |
| c215 | train | 8.38 | 335 | 127 | prose/docs/MODEL-ASSEMBLY.md | The Android appliance remains responsible for the HTP bindings, resident buffers, typed transport, and audio output. | `ði ˈændɹˌYd əplˈIəns ɹəmˈAnz ɹəspˈɑnsəbᵊl fɔɹ ði ˌAʧtˌipˈi bˈIndɪŋz, ɹˈɛzədᵊnt bˈʌfəɹz, tˈIpd tɹˈænspˌɔɹt, ænd ˈɔdiO ˈWtpˌʊt.` |
| c223 | train | 8.40 | 336 | 141 | prose/docs/WINDOWS-COMPUTE-NODE.md | AOA cannot be credited with a latency improvement until those measurements distinguish it from the current ADB development harness. | `ˌAˌOˈA kənˈɑt bi kɹˈɛdəTᵻd wɪð ɐ lˈAtᵊnsi ɪmpɹˈuvmənt ˌʌntˈɪl ðOz mˈɛʒəɹmᵊnts dəstˈɪŋɡwɪʃ ɪt fɹʌm ðə kˈɜɹənt ˌAdˌibˈi dəvˈɛləpmənt hˈɑɹnəs.` |
| c257 | train | 8.43 | 337 | 139 | bench/long-form/meter-algebra | See an X or a Y in the middle of the math? It's just a hidden number waiting on the path. We call it a variable, a mystery inside, | `sˈi ɐn ˈɛks ɔɹ ɐ wˈI ɪn ðə mˈɪdᵊl ʌv ðə mˈæθ? ˌɪts ʤˈʌst ɐ hˈɪdᵊn nˈʌmbəɹ wˈATɪŋ ˌɔn ðə pˈæθ. wˌi kˈɔl ɪt ɐ vˈɛɹiəbᵊl, ɐ mˈɪstəɹi ɪnsˈId,` |
| c292 | train | 8.50 | 340 | 121 | prose/docs/APPLIANCE.md | Neither proves Android startup time, APK size, phone memory use, AOA service behavior or speech TTFT. | `nˈiðəɹ pɹˈuvz ˈændɹˌYd stˈɑɹTʌp tˈIm, ˌApˌikˈA sˈIz, fˈOn mˈɛməɹi jˈus, ˌAˌOˈA sˈɜɹvəs bəhˈAvjəɹ ɔɹ spˈiʧ tˌitˌiˌɛftˈi.` |
| c242 | train | 8.53 | 341 | 134 | prose/docs/SMA-SPEECH.md | They do not establish that Kokoro exposes the corresponding controls or that any proposed mutation sounds better on this device. | `ðˌA dˈu nˌɑt əstˈæblɪʃ ðæt kəkˈɔɹO ɪkspˈOzᵻz ðə kˌɔɹəspˈɑndɪŋ kəntɹˈOlz ɔɹ ðæt ˈɛni pɹəpˈOzd mjutˈAʃən sˈWndz bˈɛTəɹ ˌɔn ðɪs dəvˈIs.` |
| c238 | train | 8.57 | 343 | 126 | prose/docs/DESIGN.md | Rewriting them as dilation-1 convs over interleaved phases is exact and keeps per-channel int8 legal on HTP. | `ɹiɹˈITɪŋ ðˌɛm æz dIlˈAʃən wˈʌn kˈɑnvz ˈOvəɹ ˌɪntəɹlˈivd fˈAzᵻz ɪz ɪɡzˈækt ænd kˈips pɜɹʧˈænᵊl ˈɪnt ˈAt lˈiɡəl ˌɔn ˌAʧtˌipˈi.` |
| c249 | train | 8.57 | 343 | 127 | prose/README.md | Kokoro-82M speech synthesis on Qualcomm Hexagon HTP, driven through the QNN C API from PowerShell. | `kəkˈɔɹO ˈATi tˈu ˈɛm spˈiʧ sˈɪnθəsɪs ˌɔn kwˈɔlkɑm hˈɛksəɡˌɑn ˌAʧtˌipˈi, dɹˈɪvən θɹu ðə kjˌuˌɛnˈɛn sˈi ˌApˌiˈI fɹʌm pˈWəɹʃˌɛl.` |
| c201 | train | 8.60 | 344 | 128 | prose/docs/APPLIANCE.md | The APK still consumes the mapped XABA store; the archive exists for diffing, reuse, trimming and release artifacts. | `ði ˌApˌikˈA stˈɪl kənsˈumz ðə mˈæpt ˌɛksˌAbˌiˈA stˈɔɹ; ði ˈɑɹkˌIv ɪɡzˈɪsts fɔɹ dˈɪfɪŋ, ɹijˈus, tɹˈɪmɪŋ ænd ɹəlˈis ˈɑɹTəfˌækts.` |
| c289 | train | 8.72 | 349 | 132 | prose/BRIEF.md | Our target device is one generation older: Galaxy S23 (SM8550, Hexagon V73). | `ˌWəɹ tˈɑɹɡət dəvˈIs ɪz wˈʌn ʤˌɛnəɹˈAʃən ˈOldəɹ: ɡˈæləksi ˈɛs twˈɛnti θɹˈi (ˌɛsˈɛm ˈATi fˈIv fˈɪfti, hˈɛksəɡˌɑn vˈi sˈɛvənti θɹˈi).` |
| c234 | train | 8.75 | 350 | 133 | prose/docs/DESIGN.md | Host overhead per call is about 1.5 ms; HTP reports no wait time, so the remaining time is inside the graph. | `hˈOst ˌOvəɹhˈɛd pɜɹ kˈɔl ɪz əbˈWt wˈʌn pYnt fˈIv ˌɛmˈɛs; ˌAʧtˌipˈi ɹəpˈɔɹts nˈO wˈAt tˈIm, sˌO ðə ɹəmˈAnɪŋ tˈIm ɪz ɪnsˈId ðə ɡɹˈæf.` |
| c199 | train | 8.78 | 351 | 136 | prose/docs/WINDOWS-COMPUTE-NODE.md | ADB is a development bootstrap and independent observation tool only. It is not part of the release command or data path. | `ˌAdˌibˈi ɪz ɐ dəvˈɛləpmənt bˈutstɹˌæp ænd ˌɪndəpˈɛndənt ˌɑbzəɹvˈAʃən tˈul ˈOnli. ˌɪt ɪz nˌɑt pˈɑɹt ʌv ðə ɹəlˈis kəmˈænd ɔɹ dˈATə pˈæθ.` |
| c300 | train | 8.78 | 351 | 138 | prose/docs/APPLIANCE.md | It may produce text and speech-planning hints, but it does not own phonemization, audio playback or the measured Kokoro synthesis path. | `ˌɪt mˈA pɹədˈus tˈɛkst ænd spˌiʧplˈænɪŋ hˈɪnts, bˌʌt ɪt dˈʌz nˌɑt ˈOn fˌOnmᵻzˈAʃən, ˈɔdiO plˈAbˌæk ɔɹ ðə mˈɛʒəɹd kəkˈɔɹO sˈɪnθəsɪs pˈæθ.` |
| c301 | train | 8.90 | 356 | 133 | prose/docs/MODEL-ASSEMBLY.md | The build verifies the pinned source specifications and package catalog hashes before producing the assembly outside the repository: | `ðə bˈɪld vˈɛɹəfˌIz ðə pˈɪnd sˈɔɹs spˌɛsəfəkˈAʃənz ænd pˈækɪʤ kˈæTᵊlˌɔɡ hˈæʃᵻz bəfˈɔɹ pɹədˈusɪŋ ði əsˈɛmbli ˌWtsˈId ðə ɹəpˈɑzətˌɔɹi:` |
| c229 | train | 9.03 | 361 | 142 | prose/docs/SMA-SPEECH.md | They are separate on purpose: a character can be recast without changing the dialogue plan, and one voice can serve multiple anonymous roles. | `ðˌA ɑɹ sˈɛpəɹət ˌɔn pˈɜɹpəs: ɐ kˈɛɹəktəɹ kæn bi ɹikˈæst wɪðˈWt ʧˈAnʤɪŋ ðə dˈIəlˌɔɡ plˈæn, ænd wˈʌn vˈYs kæn sˈɜɹv mˈʌltəpᵊl ənˈɑnəməs ɹˈOlz.` |
| c294 | train | 9.05 | 362 | 152 | bench/long-form/narrative-accomplice | It was the same shuttle. The one he had used to kidnap her, the one that had taken them past the known universe and into a shared, unspoken hell. | `ˌɪt wʌz ðə sˈAm ʃˈʌTᵊl. ðə wˈʌn hi hæd jˈuzd tə kˈɪdnˌæp hˌɜɹ, ðə wˈʌn ðæt hæd tˈAkən ðˌɛm pˈæst ðə nˈOn jˈunəvəɹs ænd ˈɪntu ɐ ʃˈɛɹd, ˌʌnspˈOkən hˈɛl.` |
| c302 | holdout | 9.15 | 366 | 141 | prose/BRIEF.md | Zero-copy shared memory (DMA-BUF registered with QNN), double-buffered between CPU and HTP with completion fences. | `zˈɪɹOkˌɑpi ʃˈɛɹd mˈɛməɹi (diɛmˌAbˌijˌuˈɛf ɹˈɛʤəstəɹd wɪð kjˌuˌɛnˈɛn), dˌʌbᵊlbˈʌfəɹd bətwˈin sˌipˌijˈu ænd ˌAʧtˌipˈi wɪð kəmplˈiʃən fˈɛnsᵻz.` |
| c203 | holdout | 9.18 | 367 | 145 | prose/docs/SMA-SPEECH.md | Breath-group duration averaged about 3.5 seconds, and inhalation depth and duration varied with upcoming clause type and group length. | `bɹˌɛθɡɹˈup dʊɹˈAʃən ˈævəɹɪʤd əbˈWt θɹˈi pYnt fˈIv sˈɛkəndz, ænd ˌɪnhəlˈAʃən dˈɛpθ ænd dʊɹˈAʃən vˈɛɹid wɪð ˌʌpkˈʌmɪŋ klˈɔz tˈIp ænd ɡɹˈup lˈɛŋθ.` |
| c282 | holdout | 9.18 | 367 | 142 | prose/docs/SMA-SPEECH.md | used contextual text and parse-tree features to sample prosodic representations for neural TTS, with controlled listening tests. | `jˈuzd kəntˈɛksʧəwəl tˈɛkst ænd pˈɑɹstɹˌi fˈiʧəɹz tə sˈæmpᵊl pɹəsˈɑdɪk ɹˌɛpɹəzˌɛntˈAʃənz fɔɹ nˈʊɹᵊl tˌitˌiˈɛs, wɪð kəntɹˈOld lˈɪsənɪŋ tˈɛsts.` |
| c198 | train | 9.25 | 370 | 143 | bench/long-form/narrative-accomplice | Captain? He stood, his expression shifting from surprise to immediate concern as she stepped into the light. He saw it on her face instantly. | `kˈæptᵊn? hˌi stˈʊd, hɪz ɪkspɹˈɛʃən ʃˈɪftɪŋ fɹʌm səɹpɹˈIz tʊ ɪmˈidiət kənsˈɜɹn æz ʃi stˈɛpt ˈɪntu ðə lˈIt. hˌi sˈɔ ɪt ˌɔn hɜɹ fˈAs ˈɪnstəntli.` |
| c200 | holdout | 9.32 | 373 | 146 | bench/long-form/narrative-accomplice | He stood, his expression shifting from surprise to immediate concern as she stepped into the light. He saw it on her face instantly. What's wrong? | `hˌi stˈʊd, hɪz ɪkspɹˈɛʃən ʃˈɪftɪŋ fɹʌm səɹpɹˈIz tʊ ɪmˈidiət kənsˈɜɹn æz ʃi stˈɛpt ˈɪntu ðə lˈIt. hˌi sˈɔ ɪt ˌɔn hɜɹ fˈAs ˈɪnstəntli. wˌʌts ɹˈɔŋ?` |
| c254 | holdout | 9.40 | 376 | 145 | prose/docs/SMA-SPEECH.md | Produce speech-act, boundary, state, and prominence candidates without changing authored text. Lower one candidate through a reversible mutation. | `pɹədˈus spˈiʧˌækt, bˈWndəɹi, stˈAt, ænd pɹˈɑmənᵊns kˈændədˌAts wɪðˈWt ʧˈAnʤɪŋ ˈɔθəɹd tˈɛkst. lˈOəɹ wˈʌn kˈændədˌAt θɹu ɐ ɹəvˈɜɹsəbᵊl mjutˈAʃən.` |
| c233 | train | 9.50 | 380 | 167 | bench/long-form/narrative-accomplice | The one he had used to kidnap her, the one that had taken them past the known universe and into a shared, unspoken hell. Of course he was still working on it. | `ðə wˈʌn hi hæd jˈuzd tə kˈɪdnˌæp hˌɜɹ, ðə wˈʌn ðæt hæd tˈAkən ðˌɛm pˈæst ðə nˈOn jˈunəvəɹs ænd ˈɪntu ɐ ʃˈɛɹd, ˌʌnspˈOkən hˈɛl. ˌʌv kˈɔɹs hi wʌz stˈɪl wˈɜɹkɪŋ ˌɔn ɪt.` |
| c236 | train | 9.53 | 381 | 146 | prose/docs/DESIGN.md | Residual dropout is not a speed knob for this model: skipping one of 18 generator resblock branches costs about 10 dB log-mel. | `ɹəzˈɪʤəwəl dɹˈɑpˌWt ɪz nˌɑt ɐ spˈid nˈɑb fɔɹ ðɪs mˈɑdᵊl: skˈɪpɪŋ wˈʌn ʌv ˌAtˈin ʤˈɛnəɹˌATəɹ ɹᵻsblˈɑk bɹˈænʧᵻz kˈɔsts əbˈWt tˈɛn dˌibˈi lˈɔɡmˈɛl.` |
| c248 | holdout | 9.55 | 382 | 144 | prose/docs/DESIGN.md | w8a16 (int8 weights, int16 activations) does not finalize yet, including a conv-only variant under test. | `dˈʌbᵊlju ˈAt ˈA sˌɪkstˈin (ˈɪnt ˈAt wˈAts, ˈɪnt sˈɪkstin ˌæktəvˈAʃənz) dˈʌz nˌɑt fˈInᵊlˌIz jˈɛt, ɪnklˈudɪŋ ɐ kˌɑnvˈOnli vˈɛɹiənt ˈʌndəɹ tˈɛst.` |
| c296 | holdout | 9.60 | 384 | 149 | bench/long-form/narrative-accomplice | He searched her face, understanding dawning slowly. He let out a low whistle, a sound that was equal parts shock and grudging admiration. He knows. | `hˌi sˈɜɹʧt hɜɹ fˈAs, ˌʌndəɹstˈændɪŋ dˈɔnɪŋ slˈOli. hˌi lˈɛt ˈWt ɐ lˈO wˈɪsᵊl, ɐ sˈWnd ðæt wʌz ˈikwᵊl pˈɑɹts ʃˈɑk ænd ɡɹˈʌʤɪŋ ˌædməɹˈAʃən. hˌi nˈOz.` |
| c280 | holdout | 9.62 | 385 | 142 | prose/docs/WINDOWS-COMPUTE-NODE.md | The intended demo topology is a Windows PowerShell client with a compatible Android phone acting as a persistent speech compute appliance. | `ði ɪntˈɛndᵻd dˈɛmO təpˈɑləʤi ɪz ɐ wˈɪndOz pˈWəɹʃˌɛl klˈIənt wɪð ɐ kəmpˈæTəbᵊl ˈændɹˌYd fˈOn ˈæktɪŋ æz ɐ pəɹsˈɪstənt spˈiʧ kəmpjˈut əplˈIəns.` |
| c253 | train | 9.68 | 387 | 153 | prose/docs/SMA-SPEECH.md | Preserve authored text and reject malformed cue cards. Produce speech-act, boundary, state, and prominence candidates without changing authored text. | `pɹəzˈɜɹv ˈɔθəɹd tˈɛkst ænd ɹəʤˈɛkt mˌælfˈɔɹmd kjˈu kˈɑɹdz. pɹədˈus spˈiʧˌækt, bˈWndəɹi, stˈAt, ænd pɹˈɑmənᵊns kˈændədˌAts wɪðˈWt ʧˈAnʤɪŋ ˈɔθəɹd tˈɛkst.` |
| c284 | train | 9.82 | 393 | 167 | bench/long-form/meter-algebra | Isolate the letter, put it on a throne. Whatever you do to the left of the sign, Do it to the right and you're doing just fine! It's all about balance, keeping the scale, | `ˈIsəlˌAt ðə lˈɛTəɹ, pˌʊt ɪt ˌɔn ɐ θɹˈOn. wəTˈɛvəɹ ju dˈu tə ðə lˈɛft ʌv ðə sˈIn, dˈu ɪt tə ðə ɹˈIt ænd jʊɹ dˈuɪŋ ʤˈʌst fˈIn! ˌɪts ˈɔl əbˈWt bˈæləns, kˈipɪŋ ðə skˈAl,` |
| c205 | holdout | 9.85 | 394 | 154 | bench/long-form/narrative-accomplice | He stood, his expression shifting from surprise to immediate concern as she stepped into the light. He saw it on her face instantly. What's wrong? Tuvok. | `hˌi stˈʊd, hɪz ɪkspɹˈɛʃən ʃˈɪftɪŋ fɹʌm səɹpɹˈIz tʊ ɪmˈidiət kənsˈɜɹn æz ʃi stˈɛpt ˈɪntu ðə lˈIt. hˌi sˈɔ ɪt ˌɔn hɜɹ fˈAs ˈɪnstəntli. wˌʌts ɹˈɔŋ? tˈuvɑk.` |
| c246 | train | 9.88 | 395 | 151 | bench/long-form/narrative-accomplice | Tom froze. He searched her face, understanding dawning slowly. He let out a low whistle, a sound that was equal parts shock and grudging admiration. | `tˈɑm fɹˈOz. hˌi sˈɜɹʧt hɜɹ fˈAs, ˌʌndəɹstˈændɪŋ dˈɔnɪŋ slˈOli. hˌi lˈɛt ˈWt ɐ lˈO wˈɪsᵊl, ɐ sˈWnd ðæt wʌz ˈikwᵊl pˈɑɹts ʃˈɑk ænd ɡɹˈʌʤɪŋ ˌædməɹˈAʃən.` |
| c267 | train | 9.90 | 396 | 159 | bench/long-form/narrative-accomplice | The creeper slid out, and he sat up, wiping his hands on an already-filthy rag. He shielded his eyes against his own light, squinting to see who was there. | `ðə kɹˈipəɹ slˈɪd ˈWt, ænd hi sˈæt ˌʌp, wˈIpɪŋ hɪz hˈændz ˌɔn ɐn ˌɔlɹˈɛdifˌɪlθi ɹˈæɡ. hˌi ʃˈildᵻd hɪz ˈIz əɡˈɛnst hɪz ˈOn lˈIt, skwˈɪntɪŋ tə sˈi hˌu wʌz ðˈɛɹ.` |
| c277 | train | 9.93 | 397 | 155 | bench/long-form/narrative-accomplice | Captain? He stood, his expression shifting from surprise to immediate concern as she stepped into the light. He saw it on her face instantly. What's wrong? | `kˈæptᵊn? hˌi stˈʊd, hɪz ɪkspɹˈɛʃən ʃˈɪftɪŋ fɹʌm səɹpɹˈIz tʊ ɪmˈidiət kənsˈɜɹn æz ʃi stˈɛpt ˈɪntu ðə lˈIt. hˌi sˈɔ ɪt ˌɔn hɜɹ fˈAs ˈɪnstəntli. wˌʌts ɹˈɔŋ?` |
| c247 | train | 9.97 | 399 | 166 | bench/long-form/meter-algebra | The goal of the game is to leave it alone, Isolate the letter, put it on a throne. Whatever you do to the left of the sign, Do it to the right and you're doing just fine! | `ðə ɡˈOl ʌv ðə ɡˈAm ɪz tə lˈiv ɪt əlˈOn, ˈIsəlˌAt ðə lˈɛTəɹ, pˌʊt ɪt ˌɔn ɐ θɹˈOn. wəTˈɛvəɹ ju dˈu tə ðə lˈɛft ʌv ðə sˈIn, dˈu ɪt tə ðə ɹˈIt ænd jʊɹ dˈuɪŋ ʤˈʌst fˈIn!` |

</details>