# Generator residual pairs replaced by per-channel stand-ins (syllabus port)

Kokoro-Hexagon `2cd65cc`, Student `-Step Retune` on the host syllabus port (the stock-Kokoro reference), `af_heart`.

## Method

- Held-out input: the same 130-tick (1.625 s) syllabus stretch as `generator-residual-pairs-20261026.md` (full render
  RMS 0.0436 and harmonic-to-noise ratio 7.57 dB in both), rendered by the port's generator alone from the stretch's
  own x and f0, with the port's seeded source draws.
- Two sets of residual pairs are left out together:
  - `CheapestSix`: `resblocks.0.0-2` and `resblocks.3.0-2`, the two blocks with the smallest single-pair losses
    (1,474,560 parameters);
  - `HeaviestBlock`: `resblocks.2.0-2` (4,325,376 parameters).
- Stand-in: each left-out pair's correction c is replaced by `a x + b` per channel, where x is the stream entering
  the pair and a, b are the least-squares fit of c on x over every frame. Two numbers per channel per pair: 2,304
  for `CheapestSix`, 1,536 for `HeaviestBlock`.
- Conditions, each scored against the full render (PCM SNR, RMS, change in harmonic-to-noise ratio):
  - `Dropped`: the pairs left out, nothing in their place;
  - `Tuned`: stand-ins fitted on four other syllabus stretches (0 to 3, 130 ticks each);
  - `TunedInSample`: stand-ins fitted on the held-out stretch itself, an upper bound for this stand-in.
- Fitting took 31.2 s on the host.

## Result

| Set | Condition | Parameters removed | Stand-in values | PCM SNR | RMS | Harmonic-to-noise change |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `CheapestSix` | `Dropped` | 1,474,560 | 0 | 10.01 dB | 0.04 | +1.52 dB |
| `CheapestSix` | `Tuned` | 1,474,560 | 2,304 | 10.35 dB | 0.04 | +2.30 dB |
| `CheapestSix` | `TunedInSample` | 1,474,560 | 2,304 | 10.40 dB | 0.04 | +2.25 dB |
| `HeaviestBlock` | `Dropped` | 4,325,376 | 0 | 4.43 dB | 0.04 | +2.40 dB |
| `HeaviestBlock` | `Tuned` | 4,325,376 | 1,536 | 4.12 dB | 0.04 | +1.99 dB |
| `HeaviestBlock` | `TunedInSample` | 4,325,376 | 1,536 | 4.07 dB | 0.04 | +2.00 dB |

## Observations

- **A per-channel gain and offset recovers almost nothing:** at most 0.39 dB for `CheapestSix`, and it loses 0.31 dB
  for `HeaviestBlock`.
- **The limit is the stand-in, not generalization:** stand-ins fitted on the held-out stretch itself score within
  0.05 dB of those fitted elsewhere. A pair's correction is not predictable from the same channel at the same
  position; what the left-out convolutions contribute is mixing across time and channels.
- **Losses add up:** the six cheapest pairs left out together give 10.01 dB, below the 12.38 dB of the worst single
  pair among them.
- **The left-out pairs add aperiodic content:** every render without them is 1.5 to 2.4 dB more harmonic than the full
  render, with RMS unchanged.

## Decision

Per-channel retuning of K and M cannot stand in for residual pairs. Removing generator weights needs a stand-in that
mixes across time or channels; a per-site gain and offset is not one.

Receipt: `build/generator-retune/run-20261026T202551/retune.clixml`, with a WAV per set and condition and the full
render.
