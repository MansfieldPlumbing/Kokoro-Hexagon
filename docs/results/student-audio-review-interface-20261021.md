# Native audio annotation interface

## Removal

Kokoro-Hexagon commit `adfbf87` removes the WPF Review entrypoint, its presentation, event handlers,
annotation-session machinery and waveform-only kernel. The original implementation and checks below are
historical evidence, not a current capability. Existing audio, review CSVs, annotation journals and
speech-learning behavior are preserved. Audit retains rejection of synthetic annotations and exclusion of
prediction-exposed annotations. The removal Verify log (`../../../../Kokoro-Hexagon/build/student-verify-ui-removal.log`)
passes, and the Stems regression receipt (`../../../../Kokoro-Hexagon/build/student-stems-after-ui-removal.clixml`)
records passing state/event checks and deterministic replay.

Implementation: Kokoro-Hexagon commit `9b5e0ee`, extending `student/Invoke-Student.ps1` through the Review step.
The host interface uses WPF, authored markup and PowerShell-owned state. It loads the most recent boundary
and phone review sets, or a single CSV supplied with Annotations. Audio remains in the existing excerpts.
The waveform envelope is a lowered numeric method in the existing Student kernel class.

Review presents a single excerpt, its target word and the requested annotation. Word-boundary time starts
unset. Phone cases show the proposed interval as context, with the proposed identity hidden. The reviewer
can play the excerpt or target/marked interval, drag markers, enter clip-relative times, select a phone
identity, enter another sound or mark the case ambiguous. Confirmed times are exported relative to the
original recording so the existing Audit command can consume boundary reviews.

Predictions cannot be revealed until the presentation is confirmed. Reveal events are permanent journal
entries. Exposure on one presentation also marks later annotations of the same case as exposed, including
repeat presentations. Audit excludes exposed reviewed boundaries from blind error scoring. The visual
protocol does not establish expert phonetic annotation or independent timing accuracy by itself.

Each confirmation checkpoints the append-only annotation journal and rebuilds the canonical review CSVs.
Writes retain the previous file for recovery. On resume the journal restores confirmed answers and
materializes their CSV fields. Case manifests bind the source identities, excerpt hashes, timing context,
target and prediction metadata. Repeated presentations do not overwrite the primary answer. The summary
reports eligible same-reviewer blind-repeat agreement and boundary differences when observations exist.

## Interface checks

The combined interface receipt (`../../../../Kokoro-Hexagon/build/student-review-interface-check.clixml`), SHA-256
`3BDDE48F84907FFC0A4DEE765CA3E2870C75B4C878FC7E4B7C35AE71B7F1E3F0`, records these checks against
isolated copies of the review CSVs:

| Measure | Result |
| --- | ---: |
| Source review sets | 2 |
| Canonical cases | 64 |
| Presentations including repeats | 72 |
| Synthetic confirmations in interface fixture | 4 |

Prediction gating, incomplete-input rejection, exact journal resume, cross-presentation exposure tracking,
ambiguous-answer preservation and selected-audio loading pass. Fixture audio is loaded without playback.
Fixture annotations are explicitly marked SyntheticInterfaceCheck and are never written to the production
review CSVs. Rendered boundary and phone previews were inspected for layout, waveform, markers, controls,
prediction visibility and readable sound labels.

The single-source annotation check (`../../../../Kokoro-Hexagon/build/student-review-annotation-check.clixml`),
SHA-256 `B9025162EFE2993A6BC2441F34337ADC7BD4A7194D89376EF9EB0610D6C44D78`, links its isolated fixture
and verifies that Audit rejects synthetic interface annotations rather than counting them as human
boundary evidence. The combined receipt records machine SHA-256
`72ECA76A72552A9D4D5A3A33E8AD47BC393BEEE06707F8CA574FE9699BCAE136`.

The Stems regression receipt (`../../../../Kokoro-Hexagon/build/student-stems-review-receipt.clixml`), SHA-256
`7BF3566224168FF4E9A48670E65EAFAF38F1C2FD3AC0533C388F5503F53A69A9`, records zero state and event
errors, maximum pitch error 0.357657219 cents and deterministic replay. The
Verify log (`../../../../Kokoro-Hexagon/build/student-verify-review-interface.log`) passes before commit.

These checks establish annotation mechanics and persistence, not human-label agreement or audio quality.
No human-label accuracy is established by the synthetic interface fixtures. The review process itself
supplies the independent observations needed by the
[alignment audit](student-alignment-review-20261021.md) and
[provisional acoustic contrast](student-acoustic-contrast-learning-20261021.md).
