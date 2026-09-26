# Host receipt: causal AdaIN statistics in the Kokoro decoder

Date: 2026-09-25
Target: host CPU only (cloud container, 4 threads). No device, no Hexagon; nothing here
is a device capability claim.
Script: `src/export/causal_norm.py` (regenerates every number and, with `--wav`, every WAV)
Model: Kokoro-82M at `f3ff3571791e39611d31c381e3a41a3af07b4987`; `kokoro-v1_0.pth`,
`config.json` and `voices/af_heart.pt` match `lib/manifest.json` byte for byte
(`496DBA11…`, `5ABB01E2…`, `0AB5709B…`).
Stack: `kokoro` 0.9.4 (manifest pin), torch 2.14.0+cpu (manifest pin), numpy 2.4.6,
scipy 1.17.1, Python 3.11.15 (manifest names 3.14; the script stubs `misaki` so that it
imports on both). Wall time 760 s.

## Question

Can the decoder front and iSTFTNet generator replace whole-phrase `AdaIN1d` /
`InstanceNorm1d` statistics with causal statistics without unacceptable quality loss? If
not, a resident streaming machine cannot stream inside a phrase with its own statistics.

## Verdict

**No.** Every causal statistic tested (cumulative from phrase start, 4 to 64 frames of
per-layer lookahead, and three EMA time constants) moves the output 12 to 20 dB in mean
log-mel distance from the whole-phrase reference. Reseeding the harmonic source alone
moves it 0.34 dB, and the acceptance line was about 1 dB. Lookahead barely helps: 64
frames at every layer's rate (15.8 s of accumulated latency over all norms, 0.56 s over
the generator's) still leaves 12.3 dB. Waveform SNR is about 0 dB for all of them.

Applied only to the generator, where the streaming machine would need it (the front
takes about 15 ms per phrase on HTP and can keep whole-phrase statistics), the result
is the same: 12.7 to 20 dB. So under the stated rule, the machine processes one phrase at
a time, with the existing QNN path plus AAudio. Intra-phrase streaming would need
statistics supplied from outside the causal stream; see "What is left open".

Metrics only: I have not listened to the WAVs, and a 12 dB log-mel distance is not a
listening verdict. The script writes every variant as a WAV for that check.

## Method

- Corpus: `bench/corpus.json` p01..p10 plus two concatenations (`long1`, `long2`), 12
  phrases, 1.40 s to 9.90 s, voice `af_heart` (pack SHA-256 `0AB5709B…`, row
  `len(tokens) - 2`). The two long phrases run 0.6 s and 1.9 s past the requested 8 s
  ceiling; the shortest predicted duration in the corpus is 1.40 s, not 0.5 s.
- Inputs: one `forward_with_tokens` per phrase (seed 0) captures `asr`, `F0`, `N` and the
  style vector. `SineGen` runs once per phrase (seed 0), and the same `har_source`
  tensor feeds the reference and every variant. No alignment search is done anywhere.
- Norm sites: all 58 decoder `AdaIN1d`: front 10 (encode, decode at 40/80 Hz), `noise_res`
  12, generator stage 0 resblocks 18 (800 Hz), stage 1 resblocks 18 (4800 Hz). The
  prosody predictor's AdaINs are untouched.
- Statistics are computed in float64 per channel; row *t* sees only what its mode allows:
  - `cum`: frames `[0, t]`; `laL`: `[0, min(t+L, T-1)]`, with L frames at that layer's
    own rate;
  - `emaτ`: bias-corrected exponential weights, τ in ms (converted per layer rate);
  - `fixed` (added): per-channel mean and E[x²] pooled over the other 11 phrases'
    reference runs (leave-one-out, BatchNorm-style population statistics);
  - `seeded1000` (added): `cum` seeded with that prior, weighted as 1 s of frames.
  The last two answer the follow-up question "can statistics be supplied from outside?".
- Scopes: `all` = 58 norms; `gen` = the 48 generator norms, with the front on
  whole-phrase statistics.
- Metrics against the reference: waveform SNR (time-aligned, phase-sensitive); mean
  absolute log-mel distance (80 HTK mel bands to 12 kHz, 1024/256 STFT, both sides
  floored at reference max − 80 dB), also split into time quarters; and the SNR of every
  AdaIN output against the reference run's output at the same layer.
- Guards:
  - The replacement code path with whole-phrase statistics reproduces the reference at
    117.7 dB minimum (every layer ≥ 119.5 dB).
  - `cum` with unbounded lookahead gives 119.7 dB (checked on p09).
  - Reseeding `SineGen` gives the model's own run-to-run floor: 0.25 to 0.40 dB log-mel,
    21.8 dB waveform SNR.

## Latency

The norm lookahead accumulates along the serial chain of norms, because a layer's
statistics at *t* need its input up to *t+L*, which needs the previous layer's
statistics up to *t+2L*. The critical-path figures are in the whole-output table below.
Two cases are given:

- **har ahead**: `noise_res` is computed from the full-phrase harmonic source in advance.
- **streamed**: the noise branch is streamed as well.

For `gen`, this is 8.75·L ms (har ahead) and 16.25·L ms (streamed). For `all`, it is
246.25·L ms; the front's nine 40 Hz norms dominate. Separately, the convolutions alone
look ahead 324.6 ms through the whole decoder and 105.6 ms through the generator
(measured by perturbing inputs after mid-phrase with causal norms). Chunked generator
streaming needs at least that much right context, whatever statistics it uses.

## Reading the numbers

- **Stage 1 (4800 Hz) causes it.** Making only the stage-1 resblocks causal costs
  13.3 dB. The front costs 3.9 dB, stage 0 3.0 dB, and `noise_res` 0.42 dB, close to the
  reseed floor. The per-layer table shows it too: activation SNR falls to single digits
  within stage 0 and to 0.7 to 3 dB at the last stage-1 norm.
- **It is not only a start-up transient.** Causal log-mel is about 21 dB in the first
  quarter, 12 to 16 dB in the middle quarters, and still about 4 dB in the last quarter,
  even where the cumulative statistics have almost converged to the phrase statistics.
- **EMA is worse than cumulative.** Shorter time constants are worse (100 ms: about
  20 dB), so the model depends on statistics over the whole utterance, not on local
  loudness.
- **Fixed population statistics come closest**: 3.51 dB mean over `gen`, and 0.89 to
  1.86 dB on p05, p06 and p08–p10. They fail on the shortest phrase (p01, 10.7 dB) and on
  both long concatenations (3.9 and 4.7 dB). A phrase's own statistics depend on its
  length and silence content, so one per-voice table cannot match every phrase.
- **`seeded1000` is uniform but never good**: 3.4 to 4.6 dB on every phrase.

## What is left open

The decisive result is negative for causal statistics. What remains is a design choice:
statistics supplied from outside the stream. The host knows phonemes, durations and F0
before the first sample, so it could supply per-phrase, per-layer statistics as inputs,
like the per-voice gamma/beta table in `masked.py`. On the device they fold into fixed
affine layers, removing the InstanceNorm reduction from the hot path. Only stage 1 and
(less so) stage 0 need them; `noise_res` could stay causal. Fixed per-voice statistics
already reach about 1 to 2 dB on typical 2.5 to 3.3 s phrases. Whether a small
host-side predictor of per-phrase statistics closes the rest is a separate, host-only
experiment. Nothing here shows it works.

## Reproduction

```
KOKORO_MODEL_DIR=<dir with kokoro-v1_0.pth, config.json, voices/af_heart.pt> \
  python src/export/causal_norm.py ../Build/Kokoro-QNN/causal-norm --wav
python src/export/causal_norm.py ../Build/Kokoro-QNN/causal-norm --summarize
```

`results.json` holds per-phrase metrics and all 58 per-layer SNRs for every run. WAVs
(`<id>_reference.wav`, `<id>_reseed.wav`, `<id>_<scope>_<variant>.wav`) are written next
to it and are not committed.

## Tables

In the per-layer table, `=` marks a layer upstream of every modified norm, where the
output is bit-identical to the reference.

### Corpus

| id | s | frames | tokens | phonemes |
| --- | ---: | ---: | ---: | --- |
| p01 | 1.40 | 56 | 9 | `həlˈoʊ.` |
| p02 | 1.90 | 76 | 18 | `jˈɛs, ɪɡzˈæktli.` |
| p03 | 1.98 | 79 | 25 | `ðə bˈɛnʧmɑɹk ɪz ɹˈʌnɪŋ.` |
| p04 | 2.30 | 92 | 32 | `ðɪs ɪz kˈoʊkəɹoʊ ɑn hɛksəɡˌɑn.` |
| p05 | 2.70 | 108 | 41 | `ðə dɪkˈoʊdəɹ ɹˈʌnz ɑn ðə nˈʊɹəl ˈɛnʤɪn.` |
| p06 | 3.27 | 131 | 47 | `həlˈoʊ wˈɜɹld. ðɪs ɪz kˈoʊkəɹoʊ ɑn hɛksəɡˌɑn.` |
| p07 | 2.52 | 101 | 36 | `spˈiʧ sˈɪnθəsɪs wɪðˈaʊt ðə klˈaʊd.` |
| p08 | 2.58 | 103 | 38 | `ˈɛvɹi fɹˈeɪz ɪz mˈɛʒəɹd ɑn ðə fˈoʊn.` |
| p09 | 3.25 | 130 | 53 | `ðə kwˈɪk bɹˈaʊn fˈɑks ʤˈʌmps ˈoʊvəɹ ðə lˈeɪzi dˈɔɡ.` |
| p10 | 3.12 | 125 | 50 | `ɪt spˈiks ɪts ˈoʊn bˈɛnʧmɑɹk ɹɪzˈʌlt ˈaʊt lˈaʊd.` |
| long1 | 8.62 | 345 | 133 | `həlˈoʊ wˈɜɹld. ðɪs ɪz kˈoʊkəɹoʊ ɑn hɛksəɡˌɑn. ˈɛvɹi fɹˈeɪz ɪz mˈɛʒəɹd ɑn ðə fˈoʊn. ɪt spˈiks ɪts ˈoʊn bˈɛnʧmɑɹk ɹɪzˈʌlt ˈaʊt lˈaʊd.` |
| long2 | 9.90 | 396 | 152 | `ðə kwˈɪk bɹˈaʊn fˈɑks ʤˈʌmps ˈoʊvəɹ ðə lˈeɪzi dˈɔɡ. ðə dɪkˈoʊdəɹ ɹˈʌnz ɑn ðə nˈʊɹəl ˈɛnʤɪn. spˈiʧ sˈɪnθəsɪs wɪðˈaʊt ðə klˈaʊd. ðə bˈɛnʧmɑɹk ɪz ɹˈʌnɪŋ.` |

### Whole-output metrics (mean over phrases; worst = largest log-mel distance)

| run | scope | waveform SNR dB | log-mel dB | worst log-mel dB | log-mel by quarter dB | norm lookahead ms (har ahead / streamed) |
| --- | --- | ---: | ---: | ---: | --- | --- |
| whole-replaced |  | 118.9 | 0.00 | 0.00 |  |  |
| reseed |  | 21.8 | 0.34 | 0.40 | 0.2 / 0.4 / 0.4 / 0.2 |  |
| cum | all | -0.3 | 12.51 | 15.21 | 21.2 / 12.4 / 11.9 / 4.4 | 0 |
| la4 | all | -0.1 | 12.98 | 17.33 | 20.5 / 13.4 / 13.2 / 4.7 | 985 / 985 |
| la8 | all | 0.1 | 13.42 | 17.81 | 20.9 / 14.6 / 13.7 / 4.3 | 1970 / 1970 |
| la16 | all | 0.3 | 13.37 | 17.24 | 20.6 / 14.6 / 13.9 / 4.2 | 3940 / 3940 |
| la32 | all | 0.4 | 13.23 | 17.49 | 19.7 / 15.5 / 14.2 / 3.5 | 7880 / 7880 |
| la64 | all | 1.2 | 12.26 | 16.24 | 17.3 / 13.6 / 13.9 / 4.1 | 15760 / 15760 |
| ema100 | all | -0.7 | 19.65 | 22.02 | 23.2 / 18.7 / 16.7 / 20.1 | 0 |
| ema400 | all | -0.7 | 16.65 | 18.75 | 21.7 / 16.9 / 16.5 / 11.4 | 0 |
| ema1600 | all | -0.4 | 13.83 | 16.59 | 21.4 / 13.5 / 13.9 / 6.5 | 0 |
| fixed | all | 5.7 | 4.31 | 11.31 | 2.5 / 6.2 / 6.4 / 2.1 | 0 |
| seeded1000 | all | 2.1 | 4.81 | 5.58 | 4.0 / 5.5 / 6.7 / 3.1 | 0 |
| cum | gen | 0.3 | 14.12 | 18.52 | 21.0 / 16.0 / 15.0 / 4.3 | 0 |
| la4 | gen | 0.2 | 14.34 | 18.98 | 20.8 / 16.7 / 15.4 / 4.4 | 35 / 65 |
| la8 | gen | 0.2 | 14.40 | 19.08 | 20.8 / 16.8 / 15.5 / 4.4 | 70 / 130 |
| la16 | gen | 0.3 | 14.18 | 18.79 | 20.2 / 16.5 / 15.5 / 4.4 | 140 / 260 |
| la32 | gen | 0.6 | 13.64 | 18.20 | 18.6 / 15.9 / 15.6 / 4.4 | 280 / 520 |
| la64 | gen | 1.2 | 12.72 | 17.06 | 17.1 / 14.3 / 15.1 / 4.4 | 560 / 1040 |
| ema100 | gen | -0.5 | 20.01 | 25.93 | 23.5 / 18.8 / 16.0 / 21.7 | 0 |
| ema400 | gen | -0.6 | 17.09 | 22.64 | 22.2 / 17.6 / 14.5 / 14.0 | 0 |
| ema1600 | gen | 0.1 | 14.45 | 18.49 | 21.3 / 16.8 / 14.6 / 5.0 | 0 |
| fixed | gen | 9.2 | 3.51 | 10.74 | 1.9 / 5.2 / 5.3 / 1.6 | 0 |
| seeded1000 | gen | 4.7 | 4.02 | 4.60 | 3.1 / 4.3 / 6.0 / 2.7 | 0 |

### Per-phrase log-mel distance, dB

| id | reseed | all/cum | all/la64 | all/ema1600 | gen/cum | gen/la4 | gen/la64 | gen/fixed | gen/seeded1000 | all/fixed |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| p01 | 0.25 | 15.18 | 13.56 | 15.55 | 17.64 | 17.63 | 13.80 | 10.74 | 4.48 | 11.31 |
| p02 | 0.26 | 14.34 | 15.17 | 15.14 | 17.42 | 17.55 | 15.42 | 5.71 | 4.02 | 7.08 |
| p03 | 0.31 | 15.21 | 16.24 | 15.64 | 17.51 | 17.82 | 15.82 | 3.86 | 3.75 | 4.93 |
| p04 | 0.33 | 14.92 | 15.49 | 15.66 | 17.14 | 17.49 | 15.64 | 3.00 | 4.20 | 3.65 |
| p05 | 0.36 | 13.33 | 13.69 | 14.10 | 15.52 | 15.99 | 14.75 | 1.86 | 4.06 | 2.69 |
| p06 | 0.37 | 10.88 | 9.86 | 12.50 | 11.92 | 11.99 | 10.44 | 1.71 | 3.42 | 2.21 |
| p07 | 0.34 | 14.91 | 13.00 | 16.43 | 15.45 | 15.77 | 13.87 | 3.06 | 4.38 | 3.87 |
| p08 | 0.34 | 15.01 | 15.55 | 16.59 | 18.52 | 18.98 | 17.06 | 1.54 | 4.60 | 2.22 |
| p09 | 0.33 | 10.74 | 10.55 | 12.61 | 11.80 | 11.93 | 10.93 | 0.89 | 3.89 | 1.34 |
| p10 | 0.36 | 13.15 | 12.47 | 14.28 | 14.26 | 14.59 | 13.18 | 1.22 | 4.46 | 1.61 |
| long1 | 0.38 | 6.49 | 5.83 | 9.00 | 6.28 | 6.29 | 5.91 | 3.85 | 3.52 | 4.91 |
| long2 | 0.40 | 5.97 | 5.68 | 8.50 | 5.95 | 5.98 | 5.82 | 4.70 | 3.48 | 5.93 |

### Attribution: one layer group non-whole at a time

| group | stats | waveform SNR dB | log-mel dB | worst log-mel dB |
| --- | --- | ---: | ---: | ---: |
| front | cum | 1.6 | 3.90 | 4.55 |
| front | fixed | 8.6 | 1.29 | 2.80 |
| noise | cum | 12.3 | 0.42 | 0.50 |
| noise | fixed | 28.4 | 0.10 | 0.26 |
| gen0 | cum | 3.4 | 3.04 | 3.85 |
| gen0 | fixed | 15.1 | 0.84 | 1.94 |
| gen1 | cum | 0.7 | 13.32 | 17.21 |
| gen1 | fixed | 13.7 | 2.41 | 6.22 |

### Per-layer activation SNR along the path, dB (AdaIN output vs reference, mean over phrases)

| layer | all/cum | all/la64 | all/ema400 | all/fixed | gen/cum | gen/la64 | gen/fixed | gen/seeded1000 | only-gen1/cum | only-gen1/fixed |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| encode.norm1 | 9.3 | 32.8 | 5.4 | 13.2 | = | = | = | = | = | = |
| decode.3.norm2 | 2.7 | 13.4 | 0.1 | 10.4 | = | = | = | = | = | = |
| generator.noise_res.0.adain2.2 | 9.6 | 12.1 | 8.4 | 21.8 | 9.6 | 12.1 | 21.8 | 18.6 | = | = |
| generator.resblocks.0.adain1.0 | 8.7 | 17.2 | 5.7 | 16.9 | 17.0 | 19.3 | 29.1 | 27.2 | = | = |
| generator.resblocks.2.adain2.2 | 2.3 | 7.9 | -0.0 | 10.1 | 6.4 | 8.7 | 15.8 | 13.3 | = | = |
| generator.noise_res.1.adain2.2 | 12.8 | 13.6 | 11.5 | 27.5 | 12.8 | 13.6 | 27.5 | 22.1 | = | = |
| generator.resblocks.3.adain1.0 | 7.9 | 10.7 | 6.5 | 15.8 | 9.8 | 11.0 | 21.4 | 16.6 | 13.3 | 31.0 |
| generator.resblocks.5.adain2.2 | 0.7 | 2.3 | -0.5 | 6.9 | 1.6 | 2.4 | 10.1 | 6.3 | 3.2 | 15.2 |

Exactness of the replacement path (whole-phrase statistics through the variant code): min layer SNR 119.5 dB, min output SNR 117.7 dB.

Convolution (non-norm) lookahead, measured with causal norms: whole decoder 324.6 ms, generator alone 105.6 ms.

