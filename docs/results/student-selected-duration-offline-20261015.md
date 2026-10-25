# Selected “I” duration, offline

The existing selector source, `tools/reference/unit-bank/mine.ps1`, SHA256
`293DA2E73F207595B2368F224FAC681157AC22BE28EB0913B1674F1093A274FA`,
scores phoneme context and F0/noise joins. It loads donor durations but does
not include duration in candidate scoring. Rendering borrows the selected
donor's stored duration; it does not predict duration for the fresh sentence.

For “Peach. I could eat a peach for hours.”, target unit 8 is `I`:

| Selection | Donor sentence | Donor token | Stored ASR ticks | Duration |
| --- | ---: | ---: | ---: | ---: |
| First 1,000 sentences | 719 | 52 | 1 | 25 ms |
| Full 43,679 sentences | 21,098 | 12 | 1 | 25 ms |

These ticks are distinct from the student's 300-sample ticks: one stored ASR
tick expands to two 300-sample ticks at 24 kHz. The donor contexts contain
`I kæn` and `I kʊd`, respectively. This locates the borrowed allocation; it
does not establish that every short diphthong is incorrect or that a duration
penalty would fix the selected sequence.

The separately rebuilt phonemizer emits the same complete phoneme string
for this sentence, and its 1,000-sentence selection has all 36 donor IDs
identical to the frozen-driver selection. The lexical correction alone does
not change this duration.

The existing listening intervention extends target unit 8 from two to six
300-sample ticks, 25 to 75 ms, retaining the other token durations and 1.3
output gain. Output duration changes from 2.325 to 2.375 seconds. Source-noise
allocation changes with length, so no PCM SNR across these variants is claimed.
These are audio durations, not synthesis-latency measurements.

- Preview selection: `build/student-peach-line-preview-selection-20261015/selection.clixml`.
- Full selection: `build/student-peach-line-selection-20261015/selection.clixml`.
- Corrected-driver selection: `build/student-peach-corrected-selection-20261015/selection.clixml`.
- Original-duration student WAV SHA256:
  `A9A56C9D5DDFD920C0AD19C16F2FF4F60CA5E21725FF565967D0335C492C39EB`.
- 75 ms “I” WAV: `build/student-peach-I75ms-preview-20261015/01-student.wav`, SHA256
  `205C1AC4CB04F24BA3BFD219F59724EECC11DCABF6538654EC1FAA061ED5B66A`.

The selector and historical bank were read only. No duration norm from an
external acoustic study is used as a mandatory threshold. No device, SDK or
hardware-performance claim is made.
