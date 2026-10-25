# Human word alignment and live Zira stress flags

Implementation: Kokoro-Hexagon commit `29c28be`, in `student/Invoke-Student.ps1`.
`Alignment` retains Zira audio with source labels, computes spectral DTW against the human recording in lowered
code, and snaps the resulting word boundaries to rest transitions, local level dips or onsets from human Listen
evidence. Source identity, global token index and source offsets stay attached to every word occurrence.
The result retains human times, each boundary's snap size and evidence kind, and source-audio provenance.
No syllabus is used. Zira's durations and pauses are not retained as human observations.

## Alignment measurement

The command was `Student -Parameters @{ Step = 'Alignment'; Recordings = <Alice recording directory>; RecordingLimit = 1 }`.
The alignment receipt (`../../../../Kokoro-Hexagon/build/student-alignment-20261021T092403/receipt.clixml`), SHA-256
`472A31DDD7583E84127679B9F835DDC7D24E0A245BE0F603CB1703A2FFA1FE43`, contains the individual boundaries and snaps.

| Measure | Result |
| --- | ---: |
| Labelled word occurrences | 2,148 |
| Reference spectral frames | 36,726 |
| Human spectral frames | 39,818 |
| Unsupported snapped boundaries | 0 |
| Zero-duration words after snapping | 0 |
| Mean absolute snap | 16.994879 ms |
| Median absolute snap | 10 ms |
| Maximum absolute snap | 242.5 ms |
| First human boundary | 22.675 seconds |
| Last human boundary | 778.4875 seconds |
| Complete cached-evidence alignment step | 21.355440 seconds |

Snap sizes summarize movement to detected human acoustic evidence. They are not word-boundary errors against
independently annotated human labels. The spectral path and resulting word identities still require that accuracy
evaluation before they support pronunciation acceptance. Zira audio is cached by content, engine and capture-owner
identity. The human recording's physical event stream is replayed without rebuilding it.

The receipt's machine hash is `AE7BC97B9C763CA3CDAE837A2CE352A56AD12978806DE18703C27B6169CB42C3` and kernel hash
is `C20793E31D38264B611D7B9F71C55A7CC1EF7F052B3AD42D5051E30047C3C821`.
The Stems regression receipt (`../../../../Kokoro-Hexagon/build/student-stems-20261021T092403/receipt.clixml`) passes
the existing pitch, event, level, coefficient and known spectral-warp checks.
The Verify log (`../../../../Kokoro-Hexagon/build/student-verify-alignment.log`) passes before commit.

## Stress-flag observation

Mechanical source-text prefixes from each corpus book were passed through live `Get-EnglishZiraReference`
captures. The corpus stress receipt (`../../../../Kokoro-Hexagon/build/student-zira-stress-corpus-receipt.clixml`),
SHA-256 `F0FD041D8254CE217F2D588B083188D443060CAE94800C6875FD46B32722DCBA`, records:

| Book | Phone events | Word events | Nonzero emphasis flags |
| --- | ---: | ---: | ---: |
| pg11615 | 1,127 | 216 | 0 |
| pg14006 | 1,125 | 243 | 0 |
| pg30036 | 1,103 | 238 | 0 |
| pg11 | 1,075 | 249 | 0 |
| Total | 4,430 | 946 | 0 |

No observed stress position was available to replace the authored first-vowel fallback. This is bounded evidence
from these captures, not a claim that all contexts or engine versions return zero flags.
`Pronunciation -Text` now reports live per-phone flags with source positions, without inserting stress.
Its owner diagnostic receipt (`../../../../Kokoro-Hexagon/build/student-zira-stress-owner-receipt.clixml`), SHA-256
`359C91F96758170B5FD4E2835FD5DE3C9939A0A5E6D0F965333CF0356FA4128C`, provides a repeatable check.
