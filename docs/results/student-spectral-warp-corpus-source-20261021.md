# Student spectral warp primitive and human corpus source

Implementation: Kokoro-Hexagon commit `9af797c`, in `student/Invoke-Student.ps1`.
This is partial alignment infrastructure, not completion of human word alignment.

The Student now includes the LibriVox book's Gutenberg text in corpus discovery, using the declared
`StudentInputs.HumanText` path. The source is appended after the existing books so their ordinals remain unchanged.
Conflicting files with the same book name fail explicitly. Spectral analysis shares its octave-band projections
between Listen's physical spectral slope and the lowered banded dynamic-time-warping kernel.

## Checks

The Stems receipt (`../../../../Kokoro-Hexagon/build/student-stems-20261021T084022/receipt.clixml`), SHA-256
`B23CF091DD5D98E2B1CF29AF20794BBA3A55D397D10A7121A6D400E3775941B1`, records the independent known-path checks.
An identity path over 24 spectral frames maps exactly to itself. A second path over 48 observed frames, made by
repeating every reference frame twice, stays within one observed frame of the specified mapping. All previous
Stems pitch, state, event and coefficient gates pass in the same receipt. These paths check the dynamic programming
and traceback, not acoustic alignment between different readers.

The corpus check receipt (`../../../../Kokoro-Hexagon/build/student-corpus-source-check.clixml`), SHA-256
`6F35C166A5D643112E2073DA866876524BB392725F7A7843287A2B5FAC029701`, comes from `Corpus -ParagraphLimit 1`.
It contains 129 word tokens and zero projection mismatches. The stored book ordinals are `pg11615:0`,
`pg14006:1`, `pg30036:2`, and `pg11:3`. This limited check was moved outside the default `corpus-*` selection
pattern so it does not replace the full corpus selected by later commands.

The render-machine hash is `4C1861E718E54E2DC1F7637D63FF5BD16508D3A9E90BC81DD8A9A5D981BE3BD7` and its
lowered-kernel hash is `674943CFC73D50F35350C0F1CE91BF7B9AF0524588DFCC2C5B5BBFA83749ECD7`.
The Verify log (`../../../../Kokoro-Hexagon/build/student-verify-alignment-kernels.log`) passes before commit.

## Remaining dependency

`Get-EnglishZiraReference` in the phonemizer owner calls `SetOutputToNull`. Its `NoSave` switch controls
observation persistence, not audio output. Actual Zira-to-human alignment therefore needs an audio-output
option in that owner, followed by acoustic alignment measurement and snapping to human Listen evidence.
No human word-boundary accuracy, snap distances, generator contact or phone execution is claimed here.
