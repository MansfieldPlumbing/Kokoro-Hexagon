# Provisional acoustic contrast learning and runtime refinement

Implementation: Kokoro-Hexagon commit `77d2c6c`, extending `student/Invoke-Student.ps1`.
Alignment can retain phone hypotheses with `PhoneLabels`. Discriminate measures human acoustic evidence,
fits a declarative threshold program, and persists its evidence in an isolated live percept image.
The image exposes Classify and LearnContrast through the shared machine. No generator is used in this step.

## Label provenance and clock checks

The phone alignment receipt (`../../../../Kokoro-Hexagon/build/student-alignment-20261021T131140/receipt.clixml`)
contains 7,362 phone hypotheses associated with the existing 2,148 Alice word occurrences. Phone events
come from Zira, mapped through the same lowered spectral warp used for the
[word alignment](student-human-word-alignment-20261021.md). They are explicitly marked ZiraWarpHypothesis
and not independently reviewed. The warp gives conditional timing labels, not an independent human
phone transcription or a calibrated timing confidence interval.

A null-output reference capture failed the retained word-clock equality check. Phone capture therefore
uses the same native WAV output as the retained reference. Before accepting events, it checks byte identity
of the recaptured and retained WAV, exact word positions and word times, and phone bounds. The redundant
temporary WAV is removed after identity checks; phone labels are cached beside the retained reference.
No existing controller recording or source audio is rebuilt when the Student machine changes.

## Fitting and held-out label agreement

The experiment receipt (`../../../../Kokoro-Hexagon/build/student-acoustic-contrast-20261021T132148/receipt.clixml`),
SHA-256 `1766D01E5261A40F19FD67CA1F80AF2989ABFDB67CE8E93419C456FDD575A2EB`, records the experiment.
The run check (`../../../../Kokoro-Hexagon/build/student-acoustic-contrast-check.clixml`), SHA-256
`33680C0EB11A7AE5B7F1A167C174A5BE6EFE0BA79984A03AD5CBE413E63F519E`, records 16.6382829 seconds
for the complete Discriminate call, machine SHA-256
`CCFA4C1FFCF8F1E88E0B20876ACDBCC669AD9AD7071AA8A1E400FBB152AF4409` and lowered kernel SHA-256
`D9A6530BC7FBB72A71B1E2E839DCFF2794C2266994652D06BC68043AE2F8E21C`.

Each supported occurrence contributes relative octave-band levels measured from the human audio, without
an averaged phone prototype. The numeric summarizer, threshold fit and decision loop are lowered methods
of the existing kernel class. A phone hypothesis requires complete analysis support within its proposed
interval. Unsupported hypotheses remain recorded as exclusions.

Canonical word spellings are assigned deterministic folds before fitting. Training folds determine feature,
threshold and polarity. Training coverage selects the candidate inventory; a separate development fold
selects the contrast. Test feature values do not choose the fitted parameters or contrast. This is spelling
holdout on one recording, not lexical-family, chapter or reader holdout. The learned program is binary and
does not establish recognition of other phones.

| Measure | Result |
| --- | ---: |
| Supported phone hypotheses | 4,758 |
| Excluded hypotheses | 2,604 |
| Evaluated candidate pairs | 66 |
| Selected labels | æ / s |
| Selected relative-band axis | 4, centered at 4,000 Hz |
| Threshold | -7.9072771072387695 dB |
| Training balanced label agreement | 0.979068858 |
| Development label counts | 21 / 57 |
| Development correct counts | 21 / 56 |
| Development balanced label agreement | 0.991228070 |
| Test label counts | 19 / 65 |
| Test correct counts | 19 / 61 |
| Test balanced label agreement | 0.969230769 |
| Test word spellings | 38 |
| Test decisions sensitive to interval perturbation | 4 / 84 |
| Interval perturbation | ±0.02 s |
| Exported held-out phone review excerpts | 32 |

Perturbation sensitivity compares both shifted intervals with the nominal decision. It is a bounded
sensitivity check, not an estimated confidence bound. All label-agreement figures depend on the unreviewed
Zira warp. They must not be reported as independently established human phone-recognition accuracy.

The generated phone-review CSV and audio excerpts are linked from the receipt. Observed phones, observed
boundaries and reviewer identities remain blank. Word-boundary review support is described separately in
[the alignment review result](student-alignment-review-20261021.md). No independent annotations were
available during this experiment.

## Runtime update, permanent counter-evidence and persistence

The incremental check (`../../../../Kokoro-Hexagon/build/student-acoustic-incremental-check.clixml`), SHA-256
`B4C8C6A8441690D67397DEEBB2467BFB13D8EFBFF46C826005027A2084C6BE00`, exercises runtime refinement
with actual measured occurrences from the selected contrast. Its initial fit uses eight training
occurrences selected by identity order. Development and test evidence remain outside fitting. The remaining
training observations are then supplied to the live image.

Development balanced agreement improves from 0.832080201 to 0.991228070. The replacement corrects 77
earlier label disagreements across the complete selected evidence; this does not imply that every
previously correct decision is preserved. All 82 initial counter-evidence records survive refinement and
restart. Both program versions remain, with the previous program marked Superseded and genealogy linking
the update and corrected evidence. A repeated LearnContrast call after restart makes no further change.
These are corrections relative to provisional labels, not independently adjudicated pronunciation corrections.

The final replay and numeric check (`../../../../Kokoro-Hexagon/build/student-acoustic-final-check.clixml`),
SHA-256 `DD57224745974A31F66B158037A90BE71F2B1FB011766DF564E43B71B20D7D25`, records exact preservation
of all 484 selected decisions across save/restore. The complete fit image retains 472 agreement examples
and 12 disagreement records. A repeated live LearnContrast call takes 0.1855252 seconds and leaves the
program unchanged. Both test occurrences with following-phone contexts absent from training agree with
their labels; that denominator is insufficient for a broad context-transfer claim.

Known-value numeric checks verify relative-band summarization and confirm that changing held-out feature
values cannot change the training fit. The persisted program is a typed feature/threshold/polarity record;
each percept uses the same interpreter. Classify and LearnContrast require no Windows speech service once
the image and lowered kernel are available. These runtime calls were measured on the host, not Android.

The Stems regression receipt (`../../../../Kokoro-Hexagon/build/student-stems-acoustic-receipt.clixml`), SHA-256
`24337587D86495E6AD9F8C8F112B574B97341C4F21C11AF7AC5F505812F92BBC`, records zero state and event
errors, maximum pitch error 0.357657219 cents and deterministic replay. The
Verify log (`../../../../Kokoro-Hexagon/build/student-verify-acoustic-contrast.log`) passes before commit.

The next evidence dependency is independent review of alignment and phone identity. The experiment does
not learn controller inversion, transitions, arbitrary phone recognition, intelligible speech or generator
quality. It supplies a measured provisional acoustic distinction, reusable runtime behavior, permanent
disagreement evidence and a tested refinement/checkpoint path while generator work continues.

## Dependency-based reinterpretation

Implementation: Kokoro-Hexagon commit `5c76e8c`, extending only the Student owner.

The live image now retains interpretation records separately from immutable observations. Each decision
references its typed evidence and the percept identities it depends on. Percept revisions and a reverse
dependency index queue affected decisions when observations, specializations or learned rules change.
The existing acoustic and prosody interpreters re-evaluate queued decisions; unchanged dependencies do
no work. Acoustic classification, prosody application and learning process the queue automatically.
The Reconsider step also exposes this operation. Direct rule edits use the image's Publish method.

Missing knowledge leaves a decision Unresolved. A later percept can resolve it without replacing the
original evidence. Interpretation history records previous and current results, dependency revisions
and the interpreting machine hash. Pending work and history survive image save/restore; legacy images
without decisions still load. This mechanism currently supports acoustic contrast and prosody decisions.
It does not automatically introduce new acoustic features or independently validate phone boundaries.

The real-evidence replay (`../../../../Kokoro-Hexagon/build/student-real-reconsider-check.clixml`), SHA-256
`ABF3A996D1EC261F8CBF089623DF97BF6B010BD741F5D39AF7892383409F3038`, registers 484 decisions against
the earlier contrast program, then supplies the remaining training evidence through LearnContrast.
All 484 decisions are automatically reconsidered. Of these, 84 change and 77 earlier disagreements
with provisional labels are corrected. All 82 original counter-examples remain. Learning plus
reinterpretation takes 0.7003823 seconds on the host; an unchanged reconsideration takes 0.0056996 seconds
and performs zero re-evaluations. Decisions and histories restore exactly. These measurements describe
the update mechanism and provisional label agreement, not independent phone-recognition accuracy.

The lifecycle check (`../../../../Kokoro-Hexagon/build/student-reconsider-check.clixml`), SHA-256
`3FB29E9620456ED1FA2760039F61E27CDA47CBDAE001FFBFA2AD8DA4EA88D26A`, exercises unresolved knowledge,
later resolution, pending-work persistence and isolation from unrelated word evidence. The
identity check (`../../../../Kokoro-Hexagon/build/student-reconsider-identity-check.clixml`), SHA-256
`FFBD7DD473092B8D09D4C6E4945321BE91F30D635DCE294DEB706446910B00D3`, verifies reuse of the same
decision identity after restore and rejection of different inputs under that identity. No manual
annotation is required to continue provisional learning. Independent validation remains necessary to
establish acoustic accuracy. Generator sources and device execution are outside this change.

The controller regression receipt (`../../../../Kokoro-Hexagon/build/student-stems-reconsider-receipt.clixml`),
SHA-256 `05F83CD064A0E06460A07172259055D3281239BAE281035B45A8C23680895374`, reports zero state and
event errors, deterministic replay and maximum pitch error 0.357657219 cents. The
Verify log (`../../../../Kokoro-Hexagon/build/student-verify-reconsider.log`) passes before the implementation
commit, including the case-pair and audio-measurement checks. These checks run on the host; no device
measurement is claimed.
