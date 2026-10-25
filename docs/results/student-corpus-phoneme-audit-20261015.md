# Student corpus phoneme audit, offline

The selected-reference Peach preview is a reconstruction from selected bank
units, not a fresh untouched stock Kokoro utterance. Its articulation therefore
does not establish a stock-model defect. The student replay and that selected
reference agree at 44.690732 dB PCM16 SNR with identical selected units,
durations, inherited F0/noise contours, style, source seed and output gain.

## Earliest observed discrepancy

The bank capture producer reads the phoneme strings supplied by our front end
before invoking stock Kokoro. The first 100 bank rows match the preserved
compiled front end after its punctuation-space cleanup. This is a provenance
check, not an independent pronunciation check.

The preserved driver's generated lexical source already differs from the
current parsed Moby facts. In 577,440 compared lexical role slots, 2,514 differ;
2,226 differ only by character case. Some remaining differences may be authored
overrides. Role slots are not distinct words or observed bank units.

| Word | Current parsed fact | Preserved generated source and compiled lookup |
| --- | --- | --- |
| eye | `I` | `i` |
| i | `I` | `i` |
| aye | `A` | `A` |
| albi | `ɑlbˈi` | `ɑlbˈI` |
| alkine | `ˈælkIn` | `ˈælkin` |

These are distinct Kokoro symbols: `I` has token ID 25 and `i` has ID 51.
The corruption is present before compilation of the preserved driver. This
does not establish that the original Moby pronunciation data is wrong, nor
does it identify the historical operation that changed the case.

Current `Add-EnglishCompiledRange` uses an ordinal string dictionary. A direct
check of that source function retained all six separate values `I`, `i`, `A`,
`a`, `O`, `o`. The current source also makes pronunciation uniqueness
case-sensitive. Historical compiled artifacts were left untouched.

A separate build from the current source restores `i` and `eye` to `I`,
`albi` to `ɑlbˈi`, and `alkine` to `ˈælkIn`. Its DLL SHA256 is
`4182E8F4C26F68300B4C24BCD64EEEC0AAA9F0BDBB51BE0C3E5983A072F4C4E4`.
The existing build command also refreshed its ignored derived parsed-facts
cache and cache receipt; this was an unintended side effect of the audit.
The refreshed TSV SHA256 is
`23483DC5E30CC090DB7BCA26BCFAB576240EDD594E250F6F88A89868E794FCF4`.
It did not replace the historical driver or the bank. The original parsed
cache hash below identifies the input to the discrepancy count, not the
refreshed cache.

The build now checks every emitted lexical role slot against its input fact
with case-sensitive equality before issuing a build receipt. A separate
Proof-source build passes all 350 slots across 70 lexical identities.
An independent comparison of the separate Moby rebuild against the refreshed
parsed facts plus the existing authored overrides passes all 577,455 slots
across 115,491 identities; see
`build/phonemizer/case-check-20261015/fact-parity.clixml`.

The exact preview script's contextual driver output already contains `I`.
Its selected duration is only one 25 ms ASR tick in both the 1,000-sentence
preview selection and the full-bank selection. Thus the lexical discrepancy
alone does not explain this line's short “I.” A listening variant changes that
token to three ASR ticks, 75 ms; it is a duration intervention, not a learned
pronunciation correction. Changing duration also changes source-noise layout,
so waveform SNR across those differently sized renders is not reported.

Independent offline Zira observations for “I”, “Eye” and “Aye” at the start of
the sentence all begin with `a͡i`. These observations remain unassessed teacher
captures; their timings are not admitted training data.

## Reference check and limitations

The existing offline decoder/generator Gate command, one run with four host
threads and preserved stock inputs/noise, reports dog at 94.671656 dB and
peach at 95.595120 dB PCM SNR. This checks the reference implementation on
intact captures. It does not check the fresh-text selection or concatenation.
No device, SDK behavior or DSP performance was measured here.

## Identities and artifacts

- Repository base: `262422657657e6bfd3c762e68e3f4647651da712`, main.
- Preserved driver source identity:
  `851C290ED9753F2D6F8980C9C03ACB5777D76A7A231452AEF30FDF1163D3EA46`.
- Preserved driver DLL SHA256:
  `9EFAF7151BCB5D7C131BCCACACBDC7FB50997C398665653552F5D848304DF3BA`.
- Parsed-facts TSV SHA256:
  `599BC642ECA1A56B38CFD04300730696B08F2F6F24CA9D698930EA30F8DB6210`.
- Renderer source SHA256:
  `8DAD8231FDCBF80C024E2C9C0A4D53FC7CE0E02D3415ABBE2FE73A1AB8E07257`.
- Renderer assembly SHA256:
  `446FD867E60D8D21F267D9B372A6736D357E84DEF7B680609E8386CBE22D1F8D`.
- Reference Gate output:
  `build/precomputed-decoder-20261014/Gate-20261015-201113046/`.
- Matched selected-reference/student pair:
  `build/student-peach-preview-original-pair-20261015/01-original-then-student.wav`.
- 75 ms “I” listening variant:
  `build/student-peach-I75ms-preview-20261015/01-student.wav`.

Protected bank data, captures, integrity manifests, historical generated driver
and stock measurement receipts were read only. The derived parser cache
receipt was refreshed as disclosed above. No bank rebuild or replacement of
the student's training targets was performed.
