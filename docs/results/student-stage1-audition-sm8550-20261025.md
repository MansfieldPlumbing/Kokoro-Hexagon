# Student stage 1: inventory and audition on the phone's generator (SM8550)

Kokoro-Hexagon `b449145`. `Student -Step Inventory` and `Run -Case student-audition` with `-Parameters
@{ Student = @{ WindowLimit = 16 } }`; the first 16 windows of the cached `af_heart` syllabus evidence for corpus
`build/corpus-20261020T124308`.

## Method

**Evidence.** Every phoneme character of every window is a phone occurrence: spaces, punctuation, stress marks, and
the pads before and after each window, with its ticks from the syllabus durations (two ticks per duration frame, 80
ticks per second).

- Duplicates in overlapping windows are kept once, from the window where the occurrence lies farthest from the ends.
- Word tokens in blocks of 64 split the occurrences: block index 7 mod 8 is held out, 6 mod 8 is development, the
  rest train.
- Neither held-out nor development occurrences enter any fit.

16 windows give 4,452 phone occurrences: 3,742 training and 318 held out.

**Voice binding.** x = mean + axes c, with the mean and the leading axes of the training ticks' x (subspace
iteration).

**Phone models, in the order they were tried:**

1. *Target response.* One target per phone type, and the state approaches the current target by a fixed rate per tick.
   The targets are fitted by least squares on the training ticks; the development split chooses the rate.
2. *Context codes.* Each occurrence is three codes: the means of its coordinates over the thirds of its ticks. Each
   percept key holds the training mean of its occurrences' codes. The keys are the type, the type after its previous
   symbol, the type before its next symbol, and both. An occurrence takes its most specific key with at least
   MinCount training occurrences, else its type. The development split chooses MinCount (2) and whether stressed
   vowels are separate types (no).

**Durations, voicing and pitch.**
- Durations: the training mean of log(ticks + 1) per type, with word-final and stressed-vowel terms.
- Voicing: the type's fraction of ticks above the generator's 10 Hz threshold.
- Pitch: the voice's mean log f0, with a stressed-vowel term, on ticks of at least 50 Hz.

**Audition.** Three held-out stretches of 130 ticks (1.625 s) are rendered with the syllabus f0. The renderer
(`New-KokoroGeneratorRenderer`) is the source-complete depth-first generator from the whole-source fixture's weights,
with int8 weights, seeded noise and AdaIN constants. The constants come from the layer export job, either on the
syllabus stretch or on the rendered stream itself.

## Result

**Held-out x SNR**, 512 channels, against the syllabus x; 16 windows, 318 held-out occurrences:

| x | Rank | x SNR (dB) |
| --- | ---: | ---: |
| Binding mean | 32 / 128 | 2.39 |
| Target response | 32 | 3.02 |
| Target response | 128 | 3.09 |
| Context codes, type only | 128 | 3.07 (development) |
| Context codes, MinCount 2 | 128 | 3.88 (4.45 for seen contexts, 3.50 for occurrences in new words) |
| Projection of the syllabus x | 32 | 7.00 |
| Projection of the syllabus x | 128 | 10.64 |

At rank 128 the axes explain 97.7% of the training variance (80.6% at rank 32).

**Other held-out scores** (context codes):

| Component | Score |
| --- | --- |
| Durations | 1.66 ticks mean absolute error |
| Voicing agreement | 0.79 |
| Pitch | 1.82 dB RMS, 20 log10 of the f0 ratio, where both are voiced |

**Renders**, mean over the three stretches. PCM SNR is against the syllabus render with the syllabus constants:

| x | AdaIN constants from | x SNR (dB) | PCM SNR (dB) | PCM RMS (syllabus 0.030 to 0.036) |
| --- | --- | ---: | ---: | --- |
| Projection, rank 128 | syllabus | 10.5 | 3.5 to 6.9 | 0.02 to 0.03 |
| Oracle: each occurrence's own mean | syllabus | 5.8 to 7.1 | 0.5 to 2.7 | |
| Oracle: own means over thirds | syllabus | 8.6 to 10.8 | 7.1 to 9.2 | |
| Oracle: projection, rank 32 | syllabus | 6.7 to 6.9 | -0.2 to 0.7 | |
| Target response, rank 128 | syllabus | 2.7 to 3.3 | 0.0 to 0.1 | 0.003 (one stretch) |
| Context codes | syllabus | 2.4 to 4.0 | -0.9 to 0.1 | 0.002 to 0.023 |
| Context codes | own export | 2.4 to 4.0 | -2.8 to -1.4 | 0.03 |
| Binding mean | syllabus | 2.2 to 2.9 | 0 | 0.000 |
| Binding mean | own export | 2.2 to 2.9 | -1.6 to -1.1 | 0.02 |

The oracle rows read the held-out evidence and are diagnostics, not Student output. Renders are under
`build/student-audition-20261025T044657` (oracles) and `build/student-audition-20261025T083901` (own-export
constants).

## Observations

- **Target response fails on consonants.** Its fitted consonant targets point away from those types' own
  mid-occurrence coordinates: the cosines on the leading 8 axes are -0.35 to -0.03 for `ɹ`, `n`, `l` and `d`. The
  joint least-squares fit through the lagged response is ill-conditioned, so the model was replaced.
- **Constants from another stream remove the output level.** With constants exported from the syllabus x, streams far
  from that x render at 0.000 to 0.003 RMS. With their own exported constants the same streams render at the
  syllabus level.
- **The predicted codes stay far from each occurrence's code.** Context codes reach 3.9 dB x SNR on held-out text; an
  occurrence's own mean held over its ticks is 5.8 to 7.1 dB.

## Not yet done

- **Larger tests.** All 100 cached windows, and context keys with closure state.
- **AdaIN that follows the Student's x.** Causal per-site moments on the DSP, or moments the Student predicts.
- **Speak.** It has not run; it uses voice-base constants, which the observations above indicate will not hold.
- **On the phone.** The Student itself runs on the host.
