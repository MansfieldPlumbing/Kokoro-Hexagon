# Human boundary learning in the live Student image

Implementation: Kokoro-Hexagon commit `d05daa7`, in `student/Invoke-Student.ps1`.
The Learn step imports the prosody rulebook as candidates, derives typed boundary observations from
the retained human word alignment and controller recording, and admits pause, pitch-reset and rest-presence
components independently when their held-out error improves. The live image exposes Learn and Apply
methods. Apply consults the pinned neighborhood and returns physical control directions through the shared
machine; it does not store executable code in percepts.

The learning receipt (`../../../../Kokoro-Hexagon/build/student-learning-receipt.clixml`), SHA-256
`24656C08117C88E3D33F35EBA041BCA152E9E258114958067953CDBEADE94CC0`, records machine SHA-256
`A8BC636518834D6B78037CB25383EB4971C72BE5EDA5E91FA2E874C8457FD7CE` and these measurements.
Evidence comes from the [Alice word alignment](student-human-word-alignment-20261021.md).

| Measure | Result |
| --- | ---: |
| Imported rulebook candidates | 80 |
| Human boundary observations | 2,147 |
| Admitted pause components | 5 |
| Admitted pitch-reset components | 2 |
| Admitted rest-presence components | 5 |
| Complete opening, observation and learning call | 59.7532711 s |
| Repeated Learn call in the same process | 0.437912 s |
| Additional programs on repeated call | 0 |

The deterministic holdout hashes the pair of source occurrence identities into a fifth of the evidence.
No occurrence pair crosses the training/holdout split. This is occurrence holdout within boundary classes,
not transfer to unseen lexical families or independent readers. Each recording provenance is treated as
a separate style. Corpus structural counter-examples remain counter-examples while their acoustic values
remain available for timing learning.

The reference predictor uses the reader's training-wide means and rest vote. Candidates condition on the
typed punctuation or paragraph boundary; their means use training evidence only. Rulebook confidence
supplies prior support for the rest vote. The table reports absolute pause-duration error on held-out
observations; a rejected component uses the reference behavior.

| Boundary | Training | Held out | Reference pause MAE (ms) | Candidate pause MAE (ms) | Pause admitted |
| --- | ---: | ---: | ---: | ---: | --- |
| Colon or semicolon | 31 | 7 | 355.914588 | 258.813364 | Yes |
| Comma | 136 | 42 | 179.344608 | 116.360294 | Yes |
| Exclamation | 20 | 4 | 282.655423 | 221.875000 | Yes |
| No punctuation boundary | 1,460 | 380 | 39.177632 | 0.385905 | Yes |
| Question | 9 | 4 | 98.280423 | 186.805556 | No |
| Stop | 19 | 5 | 495.780423 | 248.552632 | Yes |

Pitch-reset MAE improves from 785.733458 to 747.468927 cents at commas and from 232.474344 to
230.086703 cents with no punctuation boundary. These errors remain substantial. Rest-presence accuracy
improves respectively from 0.285714 to 0.714286, 0.238095 to 0.761905, 0.25 to 0.75, 0.25 to 0.75,
and 0 to 1 for colon/semicolon, comma, exclamation, question and stop. This binary acoustic rest decision
is not grammatical boundary-class recognition. Small held-out classes require more independent evidence.

Prediction evidence retains both agreement and disagreement, including actual values, predicted pause,
tolerance, rule identity, provenance and holdout membership. Genealogy records the admission decision and
its evidence identities. Prior programs remain in the image when stronger candidates replace them.
Rulebook entries whose typed conditions are not implemented remain explicitly awaiting typed conditions;
importing the candidates does not establish that the complete rulebook executes.

## Persistence and controller replay

The learning work exposed an earlier checkpoint conversion defect: ordered controller layouts had been
converted into member descriptions containing keys and values. Restore now reconstructs the layout from
those retained values and rebinds performance and event types in place. No source evidence was regenerated.

The original controller recording and the restored legacy image agree exactly across 764,508 wire bytes
and 509,672 physical frame values. The declared clock remains 0.0125 seconds and the seed remains 1729.
These are input replay checks, not generator PCM checks.

The restore receipt (`../../../../Kokoro-Hexagon/build/student-learning-restore-receipt.clixml`), SHA-256
`886E661CFFB26344CCCEBCBC9033AD8E0F14AC8D9F5E4E3B27D0D4DE2F5CAD8E`, confirms exact controller
replay and identical learned actions after saving and restoring the new image. It records 89 percepts,
6,412 evidence objects, six retained boundary actions and 72.3572634 seconds to open the image. The
checkpoint SHA-256 is `2D01BD4009A7C2194435F669B0F62B613474D09801273B432BEBE584ACF1DE18`.
Opening cost is separate from the repeated live learning measurement above.

The Stems regression receipt (`../../../../Kokoro-Hexagon/build/student-stems-prosody-receipt.clixml`), SHA-256
`82D5C5DF8EF152B7164D0C1410491C813420A487408F2333579542D91D29FBB9`, records zero state and event
errors, maximum pitch error 0.357657219 cents, coefficient-axis error 0.029562473 and response error
0.068882167. Diagnostic replay remains deterministic. The
Verify log (`../../../../Kokoro-Hexagon/build/student-verify-prosody.log`) passes before commit.

This step establishes host learning, typed actions and persistence on automatically aligned evidence.
It does not establish independently annotated timing accuracy, lexical-stress transfer, phone runtime
throughput or generator binding quality. Human boundary evidence comes from the retained human audio;
Zira supplies alignment identity as described in the alignment result.
