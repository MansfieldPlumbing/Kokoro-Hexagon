# Live AdaIN hybrid: the resblock sites must normalize their own whole-utterance input; the noise sites can be supplied (2026-11-14)

Branch `live-adain`, Kokoro-Hexagon `1247b08` plus the port change this commit adds. Host only; no phone, no DSP.
Receipt: `build/live-adain-hybrid-20261114/` (predictions, scripts, supplied moments, logs, CSVs, every WAV,
`manifest.csv` of SHA-256s).

**Two results.**

- With the 36 resblock sites normalizing their own whole-utterance input and the plan-conditioned moments (P3)
  supplied at the 12 `noise_res` sites, the render is 0.28 dB mel-cepstral distortion from stock, against 9.88 dB
  for P3 supplied everywhere and 4.58 dB for a reseed. Not causal.
- No causal hybrid comes closer to stock than P3 supplied everywhere. Running moments at the stage-1 resblocks alone
  give 15.17 dB. Refuted as predicted.

## Predictions

`PREDICTIONS-HYBRID.md` was written before any hybrid render; SHA-256
`E00794E18F64D5C8CCDE5035108E38878E446778805086B915CC62B331BC4242`, recorded at 20:04 on 2026-11-14
(`predictions-hash.txt`).

## Port change

`tools/Invoke-KokoroPrecomputedDecoder.ps1`: `OfflineMomentPolicy.SuppliedSites` (and the same parameter on
`New-OfflineMomentPolicy`) names the generator sites that do not measure in Measured mode. Each takes its supplied
moments for the whole utterance, exactly as Supplied mode does, and records what its input then had. Without the
list, Measured mode is unchanged.

`Verify`: every check passes but `handoff` (`handoff-20261101.md has no next steps`), as before (`verify.log`).

## Controls

| Control | Predicted | Observed |
| --- | --- | --- |
| Every site named as supplied, Measured mode, 3 windows, against the Supplied-mode P3 render | byte-identical | byte-identical in 3 of 3 |
| R640P (no list) on Stage B's 8 windows against Stage C's `renders-added/<window>-R640P.wav` | byte-identical | byte-identical in 8 of 8 |
| Sites recording observed moments = sites named as supplied, every hybrid render | equal | equal in all 99 renders (the script throws otherwise) |
| `Verify` | all but `handoff` | all but `handoff` |

The first control can fail: any site that measured would change the PCM, as every other arm shows.

## Arms

The 16 held-out windows of the closed-loop run (378 to 2,278 ticks; the first 8 are Stage B's render windows),
generator only, teacher x and F0, port seed 17, `af_heart` at each window's voice row, P3 from the closed-loop run's
`model-0.bin`. Every render shares x, F0, durations, style and the seed-17 draws with the exact render; arms differ
only in where the AdaIN moments come from. Sites that do not measure take P3 for the whole utterance.

`CompareAudio` against the exact render, mean over the 16 windows (`renders/closed-loop-audio.csv`):

| Arm | Sites measuring | Scope there | Causal | Log-spectral distance | Mel-cepstral distortion | On Stage B's 8 | f0 RMSE | Voicing | Below P3 in | Predicted mel-cepstral |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| P3 everywhere | none | | yes | 1.59 dB | 9.88 dB | 10.83 dB | 40.0 cents | 0.971 | | |
| HW-RB | all resblocks (36) | whole utterance | no | 0.11 dB | 0.28 dB | 0.33 dB | 2.9 cents | 0.999 | 16 of 16 | 5.0 to 8.0, below HW-S1: **far below the range**; below HW-S1 in 16 of 16 |
| HW-S1 | stage-1 resblocks (18) | whole utterance | no | 0.99 dB | 4.14 dB | 4.61 dB | 37.2 cents | 0.986 | 16 of 16 | 6.5 to 9.0, below P3 in at least 12: **below the range**; 16 of 16 |
| H640-S1 | stage-1 resblocks (18) | running, 640-tick P3 prior | yes | 2.66 dB | 15.17 dB | 15.46 dB | 45.7 cents | 0.950 | 2 of 16 | 11 to 16: in range |
| H640-RB | all resblocks (36) | running, 640-tick P3 prior | yes | 3.16 dB | 17.63 dB | 17.76 dB | 65.3 cents | 0.929 | 1 of 16 | 13 to 17, not below H640-S1: 0.63 dB above the range; not below |
| H160-S1 | stage-1 resblocks (18) | running, 160-tick P3 prior | yes | 3.82 dB | 23.35 dB | 23.80 dB | 47.2 cents | 0.921 | 0 of 16 | H640-S1 + 2 to 8: +8.18, just above |
| R640P | all 48 | running, 640-tick P3 prior | yes | 3.17 dB | 17.64 dB | 17.76 dB | 66.5 cents | 0.927 | 1 of 16 | 15 to 18: in range |

Pads contribute in every running arm. The reseed yardstick exists only on Stage B's 8 windows: 1.43 dB log-spectral
distance, 4.58 dB mel-cepstral distortion.

**The two claims.**

- "What P3 loses at depth is self-correction": holds. HW-S1 is below P3 in every window, and I predicted too little
  of it: with all resblocks normalizing their own input the distance to stock all but vanishes.
- "A causal hybrid comes closer to stock than P3 supplied everywhere": refuted, as predicted. The best causal hybrid
  is 5.29 dB above P3.

## Observations

- **The `noise_res` sites can be supplied.** P3 there costs 0.28 dB when the resblocks self-normalize, less than a tenth
  of a reseed's distance. These are 12 of the 48 sites and 2,304 of the 9,216 channels.
- **Measuring the `noise_res` sites buys nothing either.** H640-RB and R640P differ by 0.01 dB in the mean. All of the
  running arms' distance from stock is made at the resblocks.
- **Stage 1 alone recovers most of it.** With only the 18 stage-1 resblock sites self-normalizing, the render is at
  the reseed's distance from stock (4.61 against 4.58 dB on the same 8 windows), with stage 0 still on P3.
- **The cost is the scope in time, not the choice of sites.** The same 18 sites cost 4.14 dB when they read the whole
  utterance and 15.17 dB when they read only what has been played, prior included. A running measure at those sites
  is worse than supplying P3 at them.
- So a render near stock needs, at each resblock site, the moments of that site's own input over the whole utterance.
  Two ways to have them before the audio leaves, neither tested: a second pass per utterance that supplies what the
  first pass observed (its fixed point is the stock render), or supplied moments accurate enough that the stream does
  not move, where how accurate is not known.
- Distance from stock is not quality. Scott reported Stage C's `0EF936E1DE6E-R640P.wav` sounds good; that arm is
  17.64 dB from stock here. Every WAV is kept in `renders/`, named by window and arm. No pass mark was adopted.

## Limitations

- One voice; float32 host port, not the DSP; teacher durations, F0 and N; generator sites only. 16 windows.
- The causal arms' causality rests on Stage C's truncation control for the running scope and on the supplied sites
  being fixed before synthesis. It was not retested for the hybrids.
- HW-RB and HW-S1 read the whole utterance at their measuring sites and are not streaming arms.
- The split between sites was chosen from the closed-loop record's per-site table, which used training windows of the
  same split. Only two splits were tried.
