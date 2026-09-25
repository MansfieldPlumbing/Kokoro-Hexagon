# SMA speech planning boundary

SMA owns realization. A language model may supply authored text, communicative
objective, discourse annotations, or token surprisal, but it does not write the
phoneme stream and it does not mix stage directions into the transcript.

```text
authored text + objective + optional model evidence
    -> coordinate-preserving SMA parse
    -> speech-act and boundary candidates
    -> spoken normalization
    -> pronunciation oracle
    -> Kokoro inputs
    -> device acoustic and listening gates
```

`speaker` is a stable discourse identity; `voice` is the selected Kokoro style
asset. They are separate on purpose: a character can be recast without changing
the dialogue plan, and one voice can serve multiple anonymous roles.

## Representations

- **Authored text** is immutable and round-trips byte-for-byte through the SMA
  lexer.
- **Cue cards** use `⟦name[:parameter]⟧`. They are explicit overrides and debug
  fixtures, not the normal authoring language. They never enter visible or
  spoken text.
- **Speech plan** records source coordinates, speech-act candidates, planning
  load, recharge decisions, and optional surprisal evidence.
- **Spoken text** contains only material intended for pronunciation.
- **Phonemes and PCM** are later derived artifacts with their own admission
  gates.

## Multiple speakers

Every speech plan and phrase bundle carries both `speaker` and `voice`. A speaker
turn changes the style vector and the precomputed per-voice gamma/beta input; it
does not change or reload either compiled QNN graph. The persistent pipeline
therefore keeps all capacity contexts and its one bounded AAudio stream alive
while consecutive phrases use different voices. Device receipts name both
fields so a listening result remains attributable.

This is cheap in execution, not evidence-free: each admitted voice asset must be
pinned by hash, each phrase still passes the fp32 oracle gate, and the first
multi-speaker claim requires a physical speaker receipt. Voice tensors remain
host-side export inputs rather than runtime model dependencies.

The initial cue vocabulary is deliberately small: `breath`, `pause`, `laugh`,
`cough`, `clear_throat`, `sigh`, and `gasp`. Pauses require an explicit duration
from 20 to 5000 milliseconds. Asterisks and ordinary square brackets have no
special meaning.

## Borrowed mechanisms

Two local research repositories provide useful, bounded mechanisms:

- ChangeModel separates canonical state from represented state, records
  predicted and actual deltas, and promotes a representation mutation only
  when full-ledger replay strictly reduces contradictions or error. Speech
  planning can use the same mechanism to discover whether features such as
  question type, discourse contrast, surprisal, remaining breath budget, or
  dialogue role explain measured acoustic outcomes.
- JS2PS preserves original coordinates, proposes small reversible edits, scores
  parser shape separately from semantics, and admits a result only through an
  execution oracle. Speech lowering follows the same discipline: an inferred
  contour is a candidate, and a punctuation, phoneme, duration, or style change
  is promoted only after reference, device, and listening gates.

Neither repository proves a speech model. Their search and admission patterns
are the reusable parts.

## Evidence admitted so far

Primary studies support the architecture, but not a universal fixed syllable
limit:

- Wang et al. measured breathing and audio from 16 healthy North American
  English speakers. Inspiratory locations usually aligned with grammatical
  boundaries; reading and spontaneous speech differed, with mean breath-group
  durations of 4.05 and 4.88 seconds in their data. This supports a dynamic
  state tied to task and syntax rather than a hard “16 syllables” rule.
  [Primary paper](https://pmc.ncbi.nlm.nih.gov/articles/PMC2945274/)
- Rochet-Capellan and Fuchs measured respiratory kinematics in 26 speakers of
  spontaneous German. Breath-group duration averaged about 3.5 seconds, and
  inhalation depth and duration varied with upcoming clause type and group
  length. This supports planning a recharge from both remaining state and
  upcoming linguistic load.
  [Primary paper](https://doi.org/10.21437/Interspeech.2013-478)
- Nickerson and Chu-Carroll elicited direct and indirect readings of identical
  yes/no questions in dialogue. Boundary tone and final pitch differed with
  intended speech act, showing why punctuation alone is insufficient.
  [Primary paper](https://www.internationalphoneticassociation.org/icphs-proceedings/ICPhS1999/papers/p14_1309.pdf)
- Chodroff and Cole manipulated information structure and affect in American
  English mini-stories. Contrastive focus changed F0 excursion, while lively
  affect also changed duration and amplitude. This supports treating model
  surprisal and discourse focus as prominence evidence rather than literal
  synthesis commands.
  [Primary paper](https://doi.org/10.21437/Interspeech.2018-1529)
- Karlapati et al. used contextual text and parse-tree features to sample
  prosodic representations for neural TTS, with controlled listening tests.
  Their results support context-conditioned prosody while also leaving a gap
  between predicted and oracle prosody.
  [Primary paper](https://arxiv.org/abs/2011.02252)

These sources justify candidate features and test design. They do not establish
that Kokoro exposes the corresponding controls or that any proposed mutation
sounds better on this device.

## Admission sequence

1. Preserve authored text and reject malformed cue cards.
2. Produce speech-act, boundary, state, and prominence candidates without
   changing authored text.
3. Lower one candidate through a reversible mutation.
4. Verify pronunciation and tensor bounds.
5. Measure the physical device and play the result through the speaker.
6. Compare blinded or paired listening judgments and retain the full outcome
   ledger, including rejected candidates.

The current implementation proves only the first two steps. Contour labels and
word-count planning budgets are explicitly provisional until later gates pass.
