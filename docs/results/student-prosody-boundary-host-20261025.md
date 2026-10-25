# Student prosody through Kokoro's text encoder and decoder (host)

Kokoro-Hexagon `8125dd5`. `Student -Step Inventory` and `Student -Step Speak`, with `-WindowLimit 16`: the first 16
windows of the cached `af_heart` syllabus evidence for corpus `build/corpus-20261020T124308`, re-rendered so that the
evidence stores N (273.2 s of speech).

The boundary follows `student/AGENTS.md` (`7a1c989`):
- The Student supplies phoneme tokens (our phonemizer), durations, f0 and N.
- Kokoro's text encoder and decoder produce x, and the generator renders it.
- PL-BERT, `bert_encoder` and the predictor do not run.

This record is a host render through the lowered port (`Invoke-OfflineSpeech -SuppliedDurations -SuppliedF0
-SuppliedN`). It does not measure the phone.

## Method

**Occurrences and split.** Phone occurrences and the held-out split are as in
`student-stage1-audition-sm8550-20261025.md`: word-token blocks of 64, with 7 mod 8 held out and 6 mod 8
development. This gives 3,742 training, 360 development and 318 held-out phone occurrences.

**Rules per phone type,** fitted on the training occurrences:
- duration: the mean of log(frames + 1), plus word-final and stressed-vowel terms;
- voicing: the fraction of ticks above 10 Hz;
- pitch: the voice's mean log f0, an optional per-type offset, and a stressed-vowel term, over ticks of at least
  50 Hz;
- energy: the mean N.

**Development choices.** The development occurrences choose whether stressed vowels are their own types (by duration
error) and whether types carry pitch offsets (by pitch error). They chose separate stressed-vowel types and no
per-type pitch offsets.

**Streams.** Per tick, f0 (within voiced runs) and N approach their targets by 0.5 per tick.

## Result

**Held-out scores** (evidence timing):

| Stratum | Occurrences | Duration error (frames) | Voicing agreement | Pitch error (dB) | N RMS error |
| --- | ---: | ---: | ---: | ---: | ---: |
| All | 318 | 0.81 | 0.79 | 1.82 | 4.16 |
| Seen context | 121 | 0.74 | 0.79 | 1.71 | 4.43 |
| New context | 16 | 0.69 | 0.77 | 2.46 | 5.92 |
| New word | 181 | 0.87 | 0.79 | 1.83 | 3.87 |
| Consonants | 140 | 1.11 | 0.64 | 1.67 | 4.70 |
| Vowels | 59 | 0.51 | 0.98 | 1.85 | 2.37 |
| Stressed vowels | 24 | 0.33 | 0.98 | 1.97 | 2.32 |

N in the evidence ranges from -9.75 to 8.68.

**Development choices** (development occurrences):

| Stressed vowels as types | Per-type pitch | Duration error (frames) | Pitch error (dB) |
| --- | --- | ---: | ---: |
| No | No | 0.89 | 1.68 |
| No | Yes | 0.89 | 1.70 |
| Yes | No | 0.88 | 1.68 |
| Yes | Yes | 0.88 | 1.70 |

**Text outside the corpus**, rendered both ways: "Most of the people who came to the meeting had already read the report, so the
discussion was short."

| Render | Speech (s) | Host render (s) |
| --- | ---: | ---: |
| Student durations, f0 and N; Kokoro text encoder, decoder, generator | 5.225 | 12.3 |
| Stock pipeline on the same phonemes | 6.075 | 15.0 |

The WAVs are in `build/student-speak-20261025T100929`.

## Not yet done

- **Phrasing.** Phrase-level pitch contours, pauses and phrase-final lengthening are not modelled. The boundary and
  pause behaviours learned from recordings (`student-human-boundary-learning-20261021.md`) are not yet applied.
- **Rules from all the evidence.** The rules come from 16 of the 100 cached windows.
- **On the phone.** The text encoder on the phone CPU and the decoder and generator on the DSP at any length are not
  yet built or timed.
