# Temporal bearings in the retained Student bank

Revision 17 extends the existing Student Hunt over the `d823b7b` bank. The new temporal adapter is authored investigative machinery. The live image retains its results and source references. This run did not establish autonomous acquisition of the adapter.

The previous Hunt required a uniquely linked single-word recognizer result before projecting a word-duration hypothesis onto recorded audio. LibriVox dictation stores timestamps for entire recognizer results, so the zero result did not rule out useful timing evidence. The new path preserves each recognizer's utterance interval, projects it to the recorded native sample grid and measures only complete retained RMS frames within it. The 44.1 kHz native capture supplies the grid even where the MP3 inventory omits a sample count. In that case the last verified native frame start provides a conservative coverage bound. Each source-token candidate keeps its own link to the shared interval. Containment is conditional on the recognizer and text alignment.

## Verified real-bank results

- 636 recognizer windows had usable native and RMS projections. They exposed 11,644 candidate word-to-window links. The reader retained 16,924 unaligned anchors, 937 anchors with competing text locations and 843 multiword recognizer results.
- The Student automatically revisited its competing morphology readings by canonical document and word occurrence. Human timing became accessible for 132 readings. Five also had stock teacher context for the same source word. The teacher context is a rendered passage. These links establish neither phone-level nor syllable-level alignment.
- The original 23 stress questions remain open. None gained a human containment link, and the stricter single-word duration path still yielded zero. Syllable stress remains unestablished.
- The Open Yap pass preserved boundary alternatives for 7,185 publisher word hypotheses. Of these, 5,115 supported at least one ordered native-sample duration and 2,459 supported more than one. The remaining 2,070 lacked an ordered pair under these candidate boundaries. The ranges summarize tested alternatives while the original onset and release candidates remain available.
- In six retained procedural histories, the stock-derived extent prediction matched the directly read waveform extent and the procedural token clock ended on the generator frame boundary. Those histories use the same generator with different upstream control. The result checks transfer within that execution family.

## Work measured

Across 224 occurrence queries in the later Alice chapters, exhaustive recall visited 2,608,256 candidate records and indexed recall performed 224 lookups. Both returned the same CLR references in order. One fresh-process run measured 3,329.24 ms for exhaustive recall, 9.76 ms for indexed recall, 961.14 ms for construction and 970.89 ms for construction and indexed recall combined. Reconsideration and teacher-context lookup took 242.72 ms. This comparison measures in-memory investigative retrieval, including the one-time cost of constructing the human timing bearings. It excludes bank loading and is a single-run measurement.

The live investigation retains distinct evidence about missing alignment, ambiguous alignment, clock projection, and inadequate temporal resolution. Source-clean persistence, independent syllable-stress judgment, and automated acquisition of new investigative instruments remain open.

Verified with `student/Test-StudentPerceptHunt.ps1` under PowerShell 7.7.
