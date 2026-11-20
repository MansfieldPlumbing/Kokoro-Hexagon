# Student heart-reading alignment

The Student can retrieve seven generated paragraph performances by audio hash, with candidate word times, transcript tags, low-level intervals, and local pitch movement. The seven clips total 146.725 seconds. The separate 75.46-second session WAV was outside this analysis.

Both transcripts have seven paragraphs. Removing the bracketed tags and normalizing whitespace gives the same spoken text in each pair. The experiment used Zira to label the spoken text and the Student’s spectral dynamic time warping kernel to map those labels onto each 24 kHz clip. The clips supplied the timing and acoustic measurements. The 439 reference word labels mapped to 439 candidate spans, one of which collapsed. A second warp with tighter search and edge bounds moved three word transitions, with a maximum change of 320 ms. Agreement between those settings measures sensitivity to the search bounds. Independent word timing review is still pending.

The 23 tags occur at 22 sites, including eight tags at seven paragraph openings. Fourteen of the 15 interior sites have untagged controls with the same punctuation in the same paragraph. The comparison excludes transitions with a collapsed neighbor or more than 60 ms of change under the alternate warp. Quiet time is the longest run of 10 ms hops below 35 dB relative to the clip’s peak frame RMS, using 30 ms windows that fit wholly between the estimated word edges.

| Punctuation | Matched tagged sites | Difference from same-paragraph untagged median |
| --- | ---: | --- |
| Period | 12 | Median +50 ms, range −400 to +170 ms |
| Comma | 2 | +155 and +170 ms |
| Question mark | 0 | The tagged question mark had no same-paragraph control |

Only three tagged interior sites had measurable pitch on both neighboring words. The period result varies substantially even within this small sample. For example, the first paragraph’s `[um]` site had 400 ms less quiet time than its untagged period median, while `[breath]` had 110 ms more. These are local acoustic observations. Testing whether individual tags produce audible changes would require repeated renders of the same text with and without each tag.

Run `student/Measure-HeartReading.ps1` with PowerShell 7.7. Pass the directory containing the two transcripts and `paragraphs` as `-ReadingDirectory`, and supply `-OutputDirectory` for the JSON receipt. Pass `-ImagePath` to add the seven paragraph observations to an existing Student image. The receipt records hashes for both transcripts, the clips, the Zira references, the measurement script and the Student kernel.
