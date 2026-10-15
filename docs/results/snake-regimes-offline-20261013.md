# Generator Snake regimes and correction energy, offline, 2026-10-13

Analysis based on `98f0cc2`, using the existing completed 48-site study
`build/generator-snake-study-20261012-160825/` in the original checkout and
its seven stock captures. No phone access, DSP source changes, new captures,
training, recalibration or listening occurred in this analysis. Pending
workspace/FastRPC changes in this worktree are outside this result.

Stock source pin: `dfb907a02bba8152ca444717ca5d78747ccb4bec`.
Checkpoint SHA-256:
`496DBA118D1A58F5F3DB2EFC88DBDC216E0483FC89FE6E47EE1F2C53F18AD1E4`.

## Definition and range

All 9,216 channels are classified using the study's frozen per-channel input
units and folded corpus constants, including their rounded K and M. Captured
inputs are rounded to even and clamped to [-32767, 32767], reproducing the
existing study's minimum and maximum at every channel. The central 99.9%
range is the equal-tailed empirical interval [0.0005, 0.9995] over all seven
captures, weighted by sample count. There is no fitted quadratic coefficient.

For QT22 phase `P = K*q/32768 + M`, the analytic correction in output LSB is
`(1-cos(2*pi*P/2^22))*2^22/(2*pi)*S/2^31`; the Taylor quadratic correction
is `P^2*pi/2^22*S/2^31`. These are the learned-alpha Snake and `alpha*y^2`
in the same frozen output unit. One LSB means the site's convolution-input
int16 unit, not one PCM LSB. Learned alpha signs are retained.

Identity requires a strict correction bound below 1 LSB; quadratic requires
approximation error at most 1 LSB; all others are periodic. Bounds were checked
over the entire continuous interval: identity includes any interior cosine
extrema, and the quadratic error is largest at the endpoint with largest
absolute phase. This check changed zero classifications from the integer-code
sweep. These are corpus-range classifications, not guarantees for unseen inputs.

| Regime | Channels | Channel share | Captured channel-value share |
| --- | ---: | ---: | ---: |
| Identity-like | 1 | 0.0109% | 0.0244% |
| Quadratic-like | 80 | 0.8681% | 1.5259% |
| Periodic | 9,135 | 99.1211% | 98.4497% |

The sole identity channel is `generator.noise_res.1.stage1`, channel 82.
Its central interval is input codes [-9810, 11604]; analytic Snake removal
costs at most 0.008381 output LSB there.

## HVX work interpretation

Identity channels moving completely into HMX would remove 0.0244% of the
captured AdaIN+Snake lane work. Quadratic channels cover another 1.5259%.
The current QT22 kernel has 60 HVX instructions in its two-row/32-channel
inner iteration, including load, stores and plane handling. Under the
requested idealization that each quadratic channel retains only one of those
60 operations and identity retains none, the operation-count reduction bound
is **1.5249%** of AdaIN+Snake HVX work. This is an optimistic lane accounting
bound, not a measured cycle or latency reduction; affine setup, memory and
packing still require a realizable schedule.

All **288 of 288 existing 32-channel blocks contain periodic channels**.
Simply masking eligible lanes removes zero periodic vector iterations in
the existing layout. Repacking or a different schedule would be needed to
approach the lane bound; neither was implemented or measured. Existing PMU
evidence is not converted into a claimed speedup.

## Periodic-channel correction energy

For each periodic channel, `d=Snake(y)-y` is decomposed into one corpus-wide
mean, a centered low-frequency component, and a residual. Energy uses real
activation units, preserving alpha, rather than mixing different channel LSB
units. Each utterance is processed separately at the site's actual rate:
800 samples/s for 256-channel sites and 4800 samples/s for 128-channel sites.

The low-pass is an offline orthogonal projection: reflect the utterance to
twice its length, retain FFT bins at or below 80 Hz, inverse-transform and
take the original half. This avoids joining unrelated utterances and gives
an ideal, noncausal cutoff. Between-utterance changes in the mean enter the
slow component. DC + slow + residual energies reconstruct the original
correction energy, checked at relative tolerance 1e-10 at every channel.
Shares below aggregate energy across periodic channels at each site.

Across all sites, summing captured sample energies gives **63.8689% mean,
13.4235% slow, 22.7076% residual**. This weights high-rate sites by their
sample count; it is not a cycle-weighted or perceptual measure.

Counts are identity/quadratic/periodic. Energy columns are percentages of
periodic-channel correction energy, not energy of the full activation.

| Site | I/Q/P | Mean % | Slow <=80 Hz % | Residual % |
| --- | ---: | ---: | ---: | ---: |
| generator.resblocks.0.stage0 | 0/1/255 | 67.80 | 7.27 | 24.93 |
| generator.resblocks.0.stage1 | 0/0/256 | 57.55 | 8.60 | 33.85 |
| generator.resblocks.0.stage2 | 0/0/256 | 67.63 | 6.89 | 25.48 |
| generator.resblocks.0.stage3 | 0/1/255 | 57.86 | 8.52 | 33.62 |
| generator.resblocks.0.stage4 | 0/0/256 | 63.75 | 8.55 | 27.70 |
| generator.resblocks.0.stage5 | 0/0/256 | 53.75 | 11.49 | 34.76 |
| generator.resblocks.1.stage0 | 0/0/256 | 66.53 | 7.94 | 25.53 |
| generator.resblocks.1.stage1 | 0/2/254 | 60.61 | 9.38 | 30.01 |
| generator.resblocks.1.stage2 | 0/0/256 | 62.41 | 9.88 | 27.72 |
| generator.resblocks.1.stage3 | 0/0/256 | 57.68 | 11.49 | 30.83 |
| generator.resblocks.1.stage4 | 0/0/256 | 63.38 | 12.63 | 23.99 |
| generator.resblocks.1.stage5 | 0/0/256 | 48.59 | 18.70 | 32.71 |
| generator.resblocks.2.stage0 | 0/0/256 | 67.90 | 7.54 | 24.55 |
| generator.resblocks.2.stage1 | 0/1/255 | 61.90 | 8.21 | 29.89 |
| generator.resblocks.2.stage2 | 0/0/256 | 64.25 | 8.60 | 27.15 |
| generator.resblocks.2.stage3 | 0/1/255 | 57.63 | 11.36 | 31.00 |
| generator.resblocks.2.stage4 | 0/1/255 | 61.79 | 12.94 | 25.27 |
| generator.resblocks.2.stage5 | 0/0/256 | 49.92 | 21.21 | 28.88 |
| generator.noise_res.0.stage0 | 0/1/255 | 70.71 | 7.60 | 21.69 |
| generator.noise_res.0.stage1 | 0/2/254 | 54.12 | 12.11 | 33.76 |
| generator.noise_res.0.stage2 | 0/2/254 | 75.58 | 6.23 | 18.19 |
| generator.noise_res.0.stage3 | 0/3/253 | 66.73 | 10.67 | 22.60 |
| generator.noise_res.0.stage4 | 0/3/253 | 72.87 | 7.53 | 19.60 |
| generator.noise_res.0.stage5 | 0/3/253 | 60.58 | 14.74 | 24.68 |
| generator.resblocks.3.stage0 | 0/0/128 | 83.60 | 5.52 | 10.88 |
| generator.resblocks.3.stage1 | 0/1/127 | 45.32 | 25.23 | 29.45 |
| generator.resblocks.3.stage2 | 0/0/128 | 72.80 | 13.78 | 13.42 |
| generator.resblocks.3.stage3 | 0/1/127 | 57.33 | 25.37 | 17.30 |
| generator.resblocks.3.stage4 | 0/0/128 | 70.28 | 20.25 | 9.47 |
| generator.resblocks.3.stage5 | 0/0/128 | 47.96 | 38.64 | 13.41 |
| generator.resblocks.4.stage0 | 0/0/128 | 70.46 | 9.15 | 20.39 |
| generator.resblocks.4.stage1 | 0/0/128 | 56.53 | 14.66 | 28.81 |
| generator.resblocks.4.stage2 | 0/0/128 | 63.19 | 13.45 | 23.36 |
| generator.resblocks.4.stage3 | 0/0/128 | 47.73 | 19.37 | 32.89 |
| generator.resblocks.4.stage4 | 0/0/128 | 67.72 | 16.03 | 16.25 |
| generator.resblocks.4.stage5 | 0/1/127 | 48.32 | 31.11 | 20.57 |
| generator.resblocks.5.stage0 | 0/0/128 | 71.02 | 8.14 | 20.84 |
| generator.resblocks.5.stage1 | 0/0/128 | 54.91 | 16.64 | 28.45 |
| generator.resblocks.5.stage2 | 0/0/128 | 63.05 | 13.39 | 23.56 |
| generator.resblocks.5.stage3 | 0/0/128 | 53.53 | 17.27 | 29.21 |
| generator.resblocks.5.stage4 | 0/0/128 | 64.76 | 15.08 | 20.16 |
| generator.resblocks.5.stage5 | 0/0/128 | 52.70 | 24.85 | 22.44 |
| generator.noise_res.1.stage0 | 0/0/128 | 70.39 | 3.60 | 26.01 |
| generator.noise_res.1.stage1 | 1/45/82 | 69.29 | 3.75 | 26.96 |
| generator.noise_res.1.stage2 | 0/0/128 | 79.50 | 3.23 | 17.27 |
| generator.noise_res.1.stage3 | 0/9/119 | 74.38 | 4.15 | 21.47 |
| generator.noise_res.1.stage4 | 0/0/128 | 78.75 | 3.68 | 17.57 |
| generator.noise_res.1.stage5 | 0/2/126 | 84.16 | 3.09 | 12.75 |

The residual is irreducible relative to this DC + 80 Hz temporal subspace on
these inputs. It does not prove irreducibility under other conditioning
features or learned controls. Conversely, assigning energy to DC or slow
terms does not establish a valid cheap replacement in the connected graph.
An 80-sample/s control stream has only 40 Hz Nyquist bandwidth; a separate
40 Hz sensitivity analysis uses the same projection and corpus mean.

| Ideal low-pass cutoff | Mean energy % | Slow energy % | Residual energy % |
| --- | ---: | ---: | ---: |
| 80 Hz | 63.8689 | 13.4235 | 22.7076 |
| 40 Hz (80-sample/s control Nyquist) | 63.8689 | 11.8550 | 24.2761 |

Per-site 40 Hz results are in `build/snake-regimes/energy-sites-40hz.csv`.
Mean shares agree with the 80 Hz decomposition at every site; lowering the
cutoff increases residual energy at every site.

## Ablation and current-body error

The single variant removes Snake at the identity channel and uses the
learned-alpha Taylor quadratic at the 80 quadratic channels. All 9,135
periodic channels retain the existing Q22 polynomial. The same frozen K/M/S,
input units, int16 saturation and output units apply to both bodies. There
is no exception or fallback for out-of-range tails.

Over all **1,756,713,984** captured site values, including tails, local
replacement error against the current integer body is **268 output LSB max,
0.877956 LSB RMS**, with **8,849,963** changed values. Restricted to the 81
selected channels (27,234,300 values), RMS error is **7.051237 LSB**.
These are local operator
outputs; they are not PCM errors. The largest tail error occurs at
`generator.resblocks.4.stage5` channel 89: 4 LSB maximum against the body
inside the central interval, 268 LSB over the full captured inputs.

Analytic classification and current polynomial parity are distinct: for
example, the identity channel's removal bound is 0.008381 analytic LSB,
but its current-body difference reaches 38 LSB even inside the central
interval. Another quadratic channel, `generator.noise_res.1.stage1` channel
33, differs by 40 body LSB centrally. A one-LSB analytic classification
must not be reported as one-LSB current-body equivalence.

For propagated generator error, both offline replays use the current Q22
Snake arithmetic and folded corpus constants inside the pinned stock
generator's FP32 convolutions and tail. The variant changes only the 81
selected channels. Inputs, style, checkpoint and captured excitation are
held fixed. An unchanged stock replay is first required to reproduce each
saved PCM float tensor bit-for-bit. This isolates the Snake ablation in a
connected generator, but does **not** emulate the full integer DSP graph:
integer convolution, residual-storage and tail errors are not reproduced.
It does not establish PCM error against receipt `541aa1e`.

All seven unchanged stock replays reproduced their saved float PCM bit-for-bit.
The connected ablation comparisons below cover 2,144,400 samples. Pooled
SNR is **40.399362 dB**, RMS error **0.000307199**, maximum absolute error
**0.014872342**, in normalized float PCM units. No listening conclusion is
drawn from these metrics.

| Corpus capture | PCM samples | SNR vs Q22 body (dB) | RMS error | Maximum absolute error |
| --- | ---: | ---: | ---: | ---: |
| 0 | 36,600 | 41.077 | 0.00024169 | 0.00260408 |
| 1 | 106,800 | 40.038 | 0.00031393 | 0.00351020 |
| 2 | 193,200 | 40.139 | 0.00032219 | 0.00584215 |
| 3 | 390,000 | 40.360 | 0.00033042 | 0.00487959 |
| 4 | 646,200 | 40.433 | 0.00030200 | 0.01487234 |
| 5 | 672,600 | 40.465 | 0.00029712 | 0.00946715 |
| 6 | 99,000 | 40.721 | 0.00029743 | 0.00337963 |

## Reproduction artifacts

Ignored `build/snake-regimes/` holds `Prepare-Study.ps1`, `analyze.py`,
`check-continuous.py`, `check-ablation.py`, `control-band.py` and `ablate.py`.
PowerShell prepares frozen contracts; the existing offline numerical runtime
is `C:/bin/micromamba/envs/mono/python.exe`, NumPy 2.5.3 and PyTorch
2.14.0+cpu. No dependency was installed or downloaded.

`regimes.csv` records every channel's regime, input interval, alpha and
error bounds. `energy-channels.csv` records each periodic channel's mean
and energy shares; `counts.csv` and `energy-sites.csv` aggregate by site.
`ablation-channels.csv` separates central and full-range local errors.
`generator-ablation.csv` records propagated output errors and hashes, with
both float output variants preserved as `generator-{body,ablation}-N.f32`.

Identities (SHA-256):

| Artifact | SHA-256 |
| --- | --- |
| Existing study CLIXML | `0E9903EBB20CD5304F76E86308CF711471935695CC5D5AE74D7BD5910CE943BA` |
| Existing corpus-constant tables | `D8F3E426FBB3B781F4CEAA95AE12D1B255CC2EA8CD67A1E2A52511B11100D20E` |
| `analyze.py` | `20FA611B989DD7C9E7F88BF8E4AB867276C57E7265D514B9D1166E5957CB6564` |
| `ablate.py` | `F8DEE9944E66CFBAE3352D46B2F344C319AA0848735DCACEA80C74B10DE4A62A` |
| `regimes.csv` | `3BF04540B2B0C5FB90B83C2663AAF1393DE441143BB4B02ED726D773552A36A9` |
| `energy-sites.csv` | `2FEAF515D97C233DA1397BDDF8C1649807124AC73CEB56B0D05D07F94CDEC6B1` |
| `energy-sites-40hz.csv` | `9CBB1B1FDE80F15109DFD08E817549DFF718343F49BEDFC97AF5BA34685314B7` |
| `generator-ablation.csv` | `EDD3EADECB131A9D71979029B444B4692315C35286198A32F1FF44970F07CBEE` |

Verification: all 672 captured input/alpha tensor files passed integrity checks;
all 9,216 channel ranges reproduced the existing study; continuous interval
classification checks passed; every channel's three energy terms reconstructed
its correction energy; all seven stock PCM replay gates passed and both ablation
outputs were finite. `Invoke-KokoroDevelopment.ps1 Verify` passed. The shared
case-pair check reported zero pairs in the one scratch PowerShell preparation
file. No runtime-frames files were edited and nothing was pushed.
