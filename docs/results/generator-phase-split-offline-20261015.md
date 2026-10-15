# Generator phase split, offline, 2026-10-15

STOP condition hit: none. Implementation: `f14bf19b7bcfe0ef69679d7cb29da26d5c43b7c4`.
Single checkout, `C:/Dev/Kokoro-Hexagon`, branch `main`. This work is not pushed.
No phone, new harness, new JSON, or changes to protected captures, manifests or
historical receipts. The existing connected Lock producer was extended in place.

## Result and interpretation

All eleven cases (dog, peach, nine selected-unit sentences) cover all 48 Snake
sites: 528 observations. Fixed seat bias is largest at 26 sites, channel/frame
lock at 3, and residual at 19. Among the 36 main sites these counts are 18, 3,
and 15. Dominance means the largest of the three shares, not necessarily a
majority. The split does not preserve the matched per-seat PCM below. Preserve
this result and move to the student driving the phased signals; do not extend
the descriptive fixed bias into an utterance-specific resident preload.

Let theta = alpha times the existing pre-Snake input, without phase wrapping.
A[channel,position] is the mean theta at that seat across all complete frames
of all eleven cases. B[channel,frame] is mean_position(theta - A).
R = theta - A - B. Report the ordered raw phase-energy reductions
`(E0-E1)/E0`, `(E1-E2)/E0`, and `E2/E0`, where E1 is energy after removing A
and E2 after removing A+B. These sum to one within 2.23e-16. They include the
DC phase component and are not percentages of audible signal energy.

A is shared across these cases, including their existing voice-style rows;
this is a descriptive fit on the measured set, not held-out validation of a
deployable per-voice constant. No normalization constants were recalibrated.
Main sites retain the existing seven-capture fixed AdaIN scaffolding. Source
sites use the pinned reference's live AdaIN. Complete rows are grouped exactly
as the existing producer groups them: 10 or 60 cycle positions. The extra
60x row is excluded from energy/delta statistics and handled in rendering.

## Every site

Shares are percentages. Delta is absolute B(frame)-B(previous frame), unwrapped
radians of alpha times u. Quantiles pool channels and adjacent complete frames
within each case; no delta crosses an utterance boundary. Median uses the two
middle values for even counts; p99 uses nearest rank. F = fixed seat bias,
C = channel/frame lock, R = residual. Full per-case rows and input hashes are
in `build/lock-split-20261015/all-cases/per-case-site.csv` and `observations.clixml`.

| Site, under generator | A % | B % | Residual % | Dominant | Median delta | p99 delta |
| --- | ---: | ---: | ---: | --- | ---: | ---: |
| noise_res.0.adain1.0 | 13.06 | 9.17 | 77.78 | R | 0.194633 | 3.730383 |
| noise_res.0.adain1.1 | 29.91 | 10.98 | 59.12 | R | 0.106984 | 2.052785 |
| noise_res.0.adain1.2 | 56.31 | 7.54 | 36.14 | F | 0.075073 | 0.812030 |
| noise_res.0.adain2.0 | 52.42 | 8.66 | 38.92 | F | 0.036790 | 0.237428 |
| noise_res.0.adain2.1 | 67.64 | 7.39 | 24.97 | F | 0.021523 | 0.274817 |
| noise_res.0.adain2.2 | 64.42 | 10.94 | 24.64 | F | 0.026927 | 0.372053 |
| noise_res.1.adain1.0 | 18.36 | 11.60 | 70.05 | R | 0.069814 | 1.305843 |
| noise_res.1.adain1.1 | 61.31 | 4.98 | 33.71 | F | 0.023558 | 0.507812 |
| noise_res.1.adain1.2 | 74.06 | 3.56 | 22.38 | F | 0.019757 | 0.323636 |
| noise_res.1.adain2.0 | 25.07 | 5.92 | 69.01 | R | 0.003227 | 0.141386 |
| noise_res.1.adain2.1 | 61.30 | 6.19 | 32.51 | F | 0.007077 | 0.132376 |
| noise_res.1.adain2.2 | 73.70 | 3.59 | 22.71 | F | 0.006331 | 0.147999 |
| resblocks.0.adain1.0 | 59.14 | 3.54 | 37.31 | F | 0.052576 | 0.406915 |
| resblocks.0.adain1.1 | 58.97 | 3.06 | 37.97 | F | 0.053610 | 0.384627 |
| resblocks.0.adain1.2 | 57.29 | 6.12 | 36.60 | F | 0.063971 | 0.464207 |
| resblocks.0.adain2.0 | 33.89 | 4.56 | 61.56 | R | 0.064380 | 0.414799 |
| resblocks.0.adain2.1 | 32.62 | 4.76 | 62.62 | R | 0.070338 | 0.418967 |
| resblocks.0.adain2.2 | 19.57 | 16.77 | 63.65 | R | 0.109669 | 0.768992 |
| resblocks.1.adain1.0 | 52.26 | 3.99 | 43.75 | F | 0.064603 | 0.512196 |
| resblocks.1.adain1.1 | 47.77 | 6.42 | 45.80 | F | 0.071394 | 0.585770 |
| resblocks.1.adain1.2 | 53.43 | 12.99 | 33.58 | F | 0.093391 | 0.903519 |
| resblocks.1.adain2.0 | 40.25 | 5.86 | 53.89 | R | 0.065295 | 0.501306 |
| resblocks.1.adain2.1 | 34.60 | 12.91 | 52.49 | R | 0.087225 | 0.765008 |
| resblocks.1.adain2.2 | 9.03 | 32.72 | 58.25 | R | 0.141551 | 3.132448 |
| resblocks.2.adain1.0 | 49.92 | 3.85 | 46.24 | F | 0.057288 | 0.481091 |
| resblocks.2.adain1.1 | 44.97 | 6.95 | 48.08 | R | 0.078944 | 0.605967 |
| resblocks.2.adain1.2 | 54.43 | 14.47 | 31.10 | F | 0.097596 | 0.858038 |
| resblocks.2.adain2.0 | 39.28 | 5.21 | 55.51 | R | 0.060248 | 0.466243 |
| resblocks.2.adain2.1 | 39.19 | 15.01 | 45.80 | R | 0.091862 | 0.936489 |
| resblocks.2.adain2.2 | 18.15 | 31.26 | 50.59 | R | 0.151650 | 2.464728 |
| resblocks.3.adain1.0 | 66.91 | 10.23 | 22.86 | F | 0.040893 | 0.634328 |
| resblocks.3.adain1.1 | 45.95 | 21.97 | 32.08 | F | 0.089595 | 0.981859 |
| resblocks.3.adain1.2 | 48.23 | 35.32 | 16.45 | F | 0.089655 | 1.103233 |
| resblocks.3.adain2.0 | 34.94 | 21.55 | 43.51 | R | 0.042765 | 0.609336 |
| resblocks.3.adain2.1 | 33.83 | 35.34 | 30.84 | C | 0.092834 | 1.031566 |
| resblocks.3.adain2.2 | 30.77 | 57.44 | 11.79 | C | 0.086920 | 1.199786 |
| resblocks.4.adain1.0 | 41.45 | 22.63 | 35.92 | F | 0.078803 | 1.183106 |
| resblocks.4.adain1.1 | 53.71 | 10.14 | 36.15 | F | 0.106350 | 0.789220 |
| resblocks.4.adain1.2 | 57.83 | 17.77 | 24.40 | F | 0.091177 | 0.714807 |
| resblocks.4.adain2.0 | 33.54 | 13.00 | 53.46 | R | 0.096767 | 0.734171 |
| resblocks.4.adain2.1 | 24.83 | 16.89 | 58.28 | R | 0.116224 | 0.792103 |
| resblocks.4.adain2.2 | 37.56 | 35.85 | 26.60 | F | 0.100164 | 0.891757 |
| resblocks.5.adain1.0 | 40.27 | 24.96 | 34.77 | F | 0.073676 | 1.078623 |
| resblocks.5.adain1.1 | 58.77 | 11.33 | 29.90 | F | 0.089200 | 0.853770 |
| resblocks.5.adain1.2 | 55.05 | 20.45 | 24.51 | F | 0.080556 | 0.801987 |
| resblocks.5.adain2.0 | 31.42 | 18.82 | 49.76 | R | 0.088697 | 0.841349 |
| resblocks.5.adain2.1 | 32.02 | 20.51 | 47.47 | R | 0.103530 | 0.904341 |
| resblocks.5.adain2.2 | 35.10 | 43.36 | 21.53 | C | 0.088042 | 0.871328 |

Small median changes do not establish small worst-case changes. Rotation with
a supplied or learned delta remains possible; these measurements establish
neither its DSP cost nor its accumulated numerical error. The previous pair
alone does not supply the next frame's innovation. No universal small-angle
approximation is admitted by these numbers.
For a sin(2B)/cos(2B) pair, the actual rotation angle is twice the reported
delta in B. The table deliberately retains the requested unwrapped a·u units.

## Listening pairs and stream size

Each WAV is mono Float32, 24 kHz, per-seat first, 0.6 s silence, split second,
with no makeup gain. Split uses sin/cos angle addition for A+B; it recomputes B
from the candidate's current input at each site, including the source branch.
This is an offline teacher experiment, not a trained front-end predictor.
Convolution, checkpoint, style and source draws match within each pair. The
phase helper uses FP64 arithmetic with FP32 output; the pinned per-seat Snake
uses FP32/MathF. No DSP implementation or instruction saving is measured.

| Case | Audio seconds, each half | Split vs per-seat PCM SNR | Peak absolute error |
| --- | ---: | ---: | ---: |
| dog | 2.175 | -0.328865 dB | 0.392766982 |
| peach | 2.350 | -0.131853 dB | 0.234400995 |

The per-seat baseline itself uses fixed main AdaIN scaffolding: against the
stock score captures it is 4.931628 dB for dog and 3.530724 dB for peach.
Thus neither half is presented as faithful stock synthesis. Early auxiliary
stock-comparison metadata for cases 01/02 used a zero placeholder and is not
evidence; none of the phase-input observations or pair comparisons use it.

Files under `build/lock-split-20261015/`:

| Pair | SHA256 |
| --- | --- |
| dog-per-seat-then-split.wav | A32CA2059758E5C1B94098C5F62877152AF7FF393A11FC6FD1A5F82658C69B97 |
| peach-per-seat-then-split.wav | 677D52111937DC52D69C29E7E2C9254B2FD5F4472BD5BEE61B0E0DAA4CFF8424 |

One FP32 phase per channel/frame costs 2,211,840 B/s for the 36 main sites,
versus 58,982,400 B/s for per-seat phases (26.6667x). If all 48 sites ran
downstream, those phase-only rates would be 2,949,120 and 78,643,200 B/s.
The typed contract instead supplies the source branch's tiles upstream.
Its complete frame rates, including streamed AdaIN, are 8,358,400 B/s and
65,128,960 B/s, plus a 27,920-byte final boundary payload per utterance.
The candidate A occupies 737,280 FP32 bytes for main sites, or 983,040 bytes
for all 48; its residency has not been adopted. See
[the field contract](../generator-input-stream.md) for every field and block size.

## Timing reference, normalized per second of audio

There is no new DSP timing. The [old peach receipt](peach-combined-constants-sm8550-20261012.md)
states `ResidentHvxThreads=4` and reports combined decoder/source/generator
99.593 ms for 2.125 s: 46.867294 ms per second of audio. The preserved
`build/peach-combined-constants-20261012/separate-generator-run.clixml` says
`MedianRegionMs=89.076 AudioSeconds=2.125`: 41.918118 ms per second, but has
only Run=0, so it is not five warm runs. The supplied approximate 85 ms reference
is approximately 40 ms per second, approximately 25x.

Those are historical integer device results, not a before/after comparison
with these FP32/FP64 host renders. The inputs and durations also differ (current
peach is 2.350 s). Hardware speed, clock policy for any new artifact, and pair
rotation on DSP remain unverified. Four-thread HVX restoration is still required
before bundling; no bundling occurred in this offline task.

## Provenance and verification

Pinned reference source:
`8DAD8231FDCBF80C024E2C9C0A4D53FC7CE0E02D3415ABBE2FE73A1AB8E07257`.
Admitted reference DLL:
`446FD867E60D8D21F267D9B372A6736D357E84DEF7B680609E8386CBE22D1F8D`.
Unchanged generator constants:
`D8F3E426FBB3B781F4CEAA95AE12D1B255CC2EA8CD67A1E2A52511B11100D20E`.
Native phase-analysis DLL:
`53CD991F973EDEB48BA5BB302732FAAF9937F6A4D0AEFDE4845ADF7340EB5A4A`.
It is CLR-only admitted through pinned PSLowering
`1afabe056235a570da29e268824784557d4f6cdd`; recompilation from the final
module produces that same DLL. Producer snapshot SHA256:
`50F01DC61DE908639BE9BA3502E4299B13AB23060BA3BFCA713BD2CD8D19D571`.

`build/lock-split-20261015/artifacts.tsv` inventories generated paths and hashes;
`listening-pairs.clixml` records individual WAV hashes and matched comparisons.
The existing producer is preserved as `producer-snapshot.ps1`, not a second
implementation. Native analytic checks reproduced an exactly additive phase
signal with zero residual and exact one-radian frame deltas. Typed-frame checks
accepted finite data and rejected a NaN control. Verify passed before the
implementation commit. Per-site/per-case results and input hashes are retained.
Unrequested scope: none.
