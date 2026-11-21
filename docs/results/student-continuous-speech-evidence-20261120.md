# Continuous speech evidence, 20 November 2026

This pass extends the retained source bank from commit `62c0b20`. Human recordings supply the acoustic evidence. The stock Kokoro and Zira captures are computational comparisons with separate clocks. Source work IDs, sentence references and decoded audio coordinates remain traversable through the Student's `SpeechEvidence` step.

## Human waveform coverage

| Material | Original units analyzed | Native rate | Approximate track hours | Measurement |
| --- | ---: | --- | ---: | --- |
| LibriVox dramatic *Alice* | 13 complete MP3 tracks | 44.1 kHz | 2.655 | Native per-channel spectral statistics and RMS |
| Open Yap conversation | Two complete original mono FLAC channels | 48 kHz | 1.202 | Native spectral statistics and RMS on the shared source clock |
| LibriSpeech dev-clean | All 2,703 original utterances across 97 chapters | 16 kHz | 5.388 | Native 20 ms RMS with per-utterance reset |
| Private performance sources | 21 complete audio files | Original rates, including 24 and 48 kHz | 0.636 | Native per-channel spectral statistics and RMS |

The public human total is about 9.24 track-hours. Open Yap contributes about 36 minutes of elapsed conversation observed on two separate tracks. Stereo measurements preserve both channels and count the file duration once. The native spectral buffers contain 714,746 frames across the 36 complete track files. The spectral outputs are FFmpeg centroid, flatness, magnitude flux and rolloff. Each uses the existing native sample rate with a 2,048-sample Hann window and a 1,024-sample hop. RMS measures the current hop. The spectral support also includes the preceding hop, and flux compares the previous spectral window. Feature PTS are zero-origin decoded sample coordinates. The first spectral window includes padding, and the last frame may be short. These buffers do not establish usable upper-band speech bandwidth. The Student view also attaches the earlier RMS/YIN periodicity buffers through the same original recording object. [FFmpeg filter implementation](https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavfilter/af_aspectralstats.c)

The LibriSpeech pass linked native sample-count measurements directly to `StudentLibriUtterance` objects and retained the verified archive as the source. Concatenation was used to transport PCM out of the decoder. RMS windows restarted at every utterance boundary and were never taken across clips. This run covered 19,396.12075 native seconds, with a possible remainder under 20 ms per utterance beyond the last full RMS frame. The complete pass took 121.6 seconds, including original member extraction and Student kernel import.

The existing Student reopened the complete archive and matched normalized utterance text against the original UTF-8 books nominated by the chapter metadata. Of 2,703 utterances, 2,438 had exactly one candidate span, 22 had multiple candidates and 243 had none. The unique candidates link 4.779 hours of waveforms to an original text span at utterance granularity. All 2,798 candidate spans carry the complete archive member identity, member checksum, UTF-16 extent and a shared reference to the measured utterance. This took 79.8 seconds to rebuild. Word and phone boundaries inside those utterances remain unresolved.

The 36 native spectral buffers occupy 15,434,855 bytes and took 229.9 seconds to compute. The LibriSpeech RMS buffers occupy 4,138,297 bytes. The bank also has 359,034,309 bytes of verified extracted FLAC members under `libri-native/decode-input` for resumable processing. The retained publisher archive stays authoritative.

## Alignment and uncertainty

- Twelve `StudentHumanChapter` objects link the dramatic chapter audio tracks to exact original UTF-16 chapter ranges, original token ordinals and the same `StudentTextEvidence` object used by teacher captures. The cast-introduction track remains measured with its album context. The chapter links come from the track and text structure. They establish chapter context rather than spoken word timing.
- The Student can traverse from each of 7,185 Open Yap word intervals to both boundaries, original native frames and shared CMUdict alternatives. 5,768 word intervals have one or more lexical phone readings, and 2,326 have more than one. These are dictionary hypotheses conditioned on publisher words. The waveform does not adjudicate which phones were produced.
- All 14,434 publisher edges, including edges for the 32 non-word labels, received a native energy-minimum search within 60 ms. There were 3,577 edges with competing minima, 8,648 with a single unverified minimum and 2,209 with no minimum. The publisher time is retained on every record. The Student opens the 32 performance intervals with their original audio, boundary alternatives and interior physical measurements. It can also reopen all 861 provisional private timing cues with the prior waveform object.
- An unconstrained Windows en-US dictation path consumed all 13 LibriVox tracks through the recognizer's end-of-input event in about 1,412 seconds over three workers. The 12 text chapters produced 850 recognizer utterance intervals and 25,287 word and pronunciation hypotheses. Exact trigrams nominated one candidate source token for 7,426 hypotheses and several tokens for 937. Another 16,924 had no candidate. The recognizer supplies utterance timing, so word anchors carry the utterance's time interval and no phone or word boundary is asserted. The 13 complete recognition artifacts occupy 416,179 bytes.

An authored query through two Student views found 11 Open Yap candidate occurrences of “I don't know” and four LibriSpeech utterance candidates from four readers. Each result pointed back to human recordings and acoustic buffers. The query establishes candidates for a cross-source comparison and leaves their pronunciations and social interpretations unresolved.

## Teacher evidence and replay

`Invoke-StudentTeacherCorpus.ps1` uses the two complete works with interpretations already retained, *Alice* and *Word Study and English Grammar*. The default traverses all eligible sentences. `-NewPerWork` limits newly acquired pairs in a given run. Every capture retains the actual invocation and indexes the original document and sentence without cloning that referent. The stock path ran the existing ALBERT, projection, predictor, text encoder, decoder and generator with no supplied prosody or generator features. The pinned voice was `af_heart`, speed 1 and seed 17. The configuration records the runtime, worker count and hashes of the runtime components and existing driver. The bank keeps the original-word projection and a reconstructible UTF-16 mapping for Zira's normalized input.

Each committed pair includes both complete WAVs, the existing codec-independent Zira event artifact, and the actual stock token IDs, durations, F0, N, ALBERT values, projected ALBERT, duration features, text encoding, aligned encoding, both style vectors and generator input. The stock reader checks all 12 tensor shapes and types, including the token and sample-clock invariants. Zira restores as `EnglishZiraUtterance` with its original reported events and timing. A curly-quote serialization fault in existing artifacts is recovered through the SMA parser's safe constant data reader and the existing typed importer. The original artifact hash and exact original input both have to match.

| Verified teacher run | Coverage |
| --- | ---: |
| Pairs per work | 24 Alice and 24 Word Study |
| Source word occurrences | 772 |
| Stock duration | 280.350 seconds (0.077875 h) |
| Zira duration | 286.015 seconds (0.079449 h) |
| Zira word and phone events | 788 words and 3,087 phone events |
| Measured 20 ms teacher RMS frames | 28,280 |
| Capture storage, including both WAVs and full tensors | 135,431,668 bytes |
| Capture wall time, including startup and concurrent local work | 1,641 seconds |

The measured storage rate was about 1.74 GB per hour of stock output. A straight-line sizing estimate for 1,123,885 words at 150 words/minute is about 217 GB and 730 wall-clock hours at this run's measured rate. This is an estimate for budgeting, since text, model duration and execution conditions vary. It exceeds the roughly 101 GB free on the capture drive. No larger tensor collection was started. The checkpoint, model configuration and `af_heart` voice file were checked against the manifest for Kokoro revision `f3ff3571791e39611d31c381e3a41a3af07b4987`.

The exact five file inputs from the run's hash list were retained under `data/source-bank/teacher-provenance/`, keyed by SHA-256. These include the local decoder script, model manifest, English phonemizer source, text encoder module and batch source. The local decoder script's hash covers a pre-existing change to its separate single-run `Speech` entry point. The capture uses `Library` and preserves that exact revision for replay.

`-WorkIdentity` with `-SentenceIndex` can schedule additional captures from specific original sentence identities while retaining the chapter and full-work links. Capture boundaries remain teacher provenance.

The continuation ran a second acquisition against all 12 Alice chapters. The search favored short existing sentence projections with the most unique human-recognizer anchor tokens and excluded the previously captured sentences. It selected sentence ordinals 72, 144, 243, 366, 403, 638, 668, 902, 965, 1152, 1221 and 1389. Each chapter contributed one actual pair. The continuation took 200.6 seconds and added 57.4 seconds of stock output. The selection was an authored evidence search and did not admit a percept.

The final cold-process verification reopened all 60 pairs, 36 from Alice and 24 from Word Study. They cover 952 original word occurrences, 337.750 seconds of stock audio, 346.970 seconds of Zira audio, 968 Zira word events and 3,719 Zira phone events. Both teacher WAVs together supplied 34,189 measured RMS frames. Total teacher artifact storage was 163,671,965 bytes. Thirty-three pairs shared a human chapter context spanning all 12 chapters, and 26 of those had human-recognizer anchors in their source ranges. All 36 original native tracks, 32 Open Yap performance intervals, 861 private timing cues, 2,703 LibriSpeech utterances and cross-object source references also passed the check.

In a fresh PowerShell 7.7 process run `student/Test-StudentSpeechEvidence.ps1` for current corpus counts, artifact and source hashes, shape checks, measured teacher waveforms and shared references. `Invoke-Student.ps1 -Step SpeechEvidence -SourceIdentity Gutenberg/11` restricts the investigation to Alice context. `-SourceIdentity LibriSpeech` exposes the existing typed books, chapters and utterances with their new acoustic buffers.

The existing live image also exposes `OpenSpeechEvidence` as an ETS script method on `Kokoro.StudentImage`. An actual image opened the two native Open Yap tracks through that method and returned a CLR `StudentSpeechInvestigation` with all 7,185 typed word hypotheses. The evidence views keep their source references while the image's persistent learned-state format stays separate.

These observations allow evidence navigation and authored candidate searches. Independent Student-acquired percepts, learned ETS changes, new PSPerception admissions and acquired executable capabilities remain at zero for this pass. Complete teacher coverage, validated human word and phone boundaries, source-wide phonetic adjudication, formants, jitter/shimmer, calibrated high-band measurements, and independently verified conversational acts remain open.
