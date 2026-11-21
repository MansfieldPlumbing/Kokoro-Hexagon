# Student unit bank audit, 20 November 2026

## Before expansion

The audited `data/source-bank/sources.bin` is a 6,303,555-byte binary index. It restores one `StudentSourceInventory` owner and 26,471 `StudentSourceUnit` instances. `Kind` distinguishes rows at the data level. The runtime has no distinct word, speaker, acoustic event or percept subclasses in this checkpoint. No canonical row restores as a string or `PSCustomObject`. The reader creates all CLR instances, then resolves stored IDs to shared object references. The publisher JSON files are external source artifacts. The legacy Student Corpus and Syllabus commands use CLIXML and remain separate from this checkpoint.

| Stored kind | Count | Level and evidentiary status |
|---|---:|---|
| FullText | 4 | Full original work handles |
| TextSpanUtf16 | 19,187 | Paragraph source coordinates |
| OriginalHumanAudio | 13 | Original LibriVox file handles |
| OriginalConversationChannel | 2 | FLAC file handles with source clocks |
| PublisherTranscriptWordSamples | 7,185 | Imported timed word labels |
| PublisherTranscriptEventSamples | 32 | Imported timed non-word labels |
| PublisherConversationTranscript | 1 | Original publisher transcript handle |
| PublisherRecordingMetadata | 1 | LibriVox release metadata handle |
| PrivatePerformanceAudio | 21 | Private audio file handles |
| PrivatePerformanceReference | 12 | Private timing or script file handles |
| LexicalReference | 9 | Lexical file handles |
| PublisherCatalog | 2 | Gutenberg catalog and mirror metadata handles |
| PublisherMeetingAnnotations | 1 | AMI annotation archive handle |
| PublisherReleaseChecksums | 1 | LibriSpeech release checksum handle |
| **Total** | **26,471** | **67 file-backed records and 26,404 range records** |

| Source | Exact records |
|---|---:|
| Gutenberg 11, *Alice’s Adventures in Wonderland* | 881, including 880 paragraph spans |
| Gutenberg 11615, *The Grammar of English Grammars* | 12,030, including 12,029 spans |
| Gutenberg 14006, *An English Grammar* | 5,260, including 5,259 spans |
| Gutenberg 30036, *Word Study and English Grammar* | 1,016, including 1,015 spans |
| Gutenberg catalog/mirror metadata | 2 |
| LibriVox dramatic *Alice* | 14, including one release and 13 tracks with one record apiece |
| Open Yap speaker channel A | 2,897, including the channel, 2,871 words and 25 non-word labels |
| Open Yap speaker channel B | 4,322, including the channel, 4,314 words and 7 non-word labels |
| Open Yap conversation metadata | 1 |
| Private generated performances | 33 |
| StudentLexicon | 9 |
| AMI | 1 |
| LibriSpeech | 1 |

There were 26,419 parent links and 7,220 corresponding-text links. The parent links comprised 19,187 paragraph-to-work links, 7,217 annotation-to-channel links, 13 track-to-release links, and two channel-to-transcript links. The corresponding-text links comprised 7,217 annotations, two channels, and the LibriVox release. All 33,639 links pointed to the exact object in the inventory dictionary after reload. Every parent’s child collection contained the same child instance. No file SHA-256 appeared twice. LibriVox and private recordings had no typed actor/speaker assignments. The original index had zero token-level grammar, morphological readings, waveform-derived observations, phone alignments, or independently acquired percepts.

The separately retained 2,704-byte teacher index has six `StudentSourceUnit` records. It repeats handles for the work and one span in its own inventory, then links two teacher WAVs and two supporting artifacts. Those repeated handles are outside the 26,471-record total.

## Source-wide passes

The source bank retained 479,564,830 bytes across 67 indexed files before expansion. Two checksum-verified LibriSpeech archives raised the main inventory to 26,473 entries, including 69 file handles totalling 1,114,770,461 bytes. The 42 lexical and private originals, totalling 172,412,605 bytes, were copied byte-for-byte into the ignored bank under content hashes. Their existing source IDs and checksums still resolve the waveform and lexical evidence. The frozen baseline index is `sources-before-expansion.bin`.

| Complete work body | Word occurrences | All corpus tokens | Punctuation or quote tokens | Sentence spans |
|---|---:|---:|---:|---:|
| Gutenberg 11 | 26,563 | 33,831 | 7,194 | 1,416 |
| Gutenberg 11615 | 997,802 | 1,581,347 | 380,626 | 66,416 |
| Gutenberg 14006 | 81,630 | 124,597 | 25,122 | 8,513 |
| Gutenberg 30036 | 17,890 | 24,671 | 3,913 | 1,831 |
| **Total** | **1,123,885** | **1,764,446** | **416,855** | **78,176** |

All body tokens mapped back to their original UTF-16 extents. The original files also retain their front matter and license text. The existing Student tokenizer supplied paragraph, heading, sentence and counterexample relations. Those relations are parser observations.

The compiled driver ran on complete corpus traversals of Alice and *Word Study and English Grammar*. Fresh-process reload restored four `StudentTextEvidence` objects and 3,247 `StudentSentenceEvidence` objects. All 2,984 `StudentMorphologyEvidence` and 6,699 `StudentGrammarEvidence` records point to their actual sentence objects. Clause candidates preserve subject, predicate, object and auxiliary occurrence indices when the engine supplies them. Corpus coordinates remain compact integer arrays. Text-derived phone hypotheses have no waveform alignment.

| Full interpretation | Sentence records | Unresolved | Original words mapped to nonempty pronunciations | Morphology readings | Clause spans | Clause candidates | Multiple roles | Multiple phone readings |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Alice | 1,416 | 10 | 26,438 of 26,563 | 1,225 | 1,406 | 1,538 | 5 | 148 |
| Word Study | 1,831 | 2 | 17,643 of 17,890 | 1,759 | 1,829 | 1,926 | 7 | 263 |

The ten unresolved Alice sentences had empty corpus projections. Word counts are distinct mapped source occurrences. Role and phone-alternative counts are driver token slots.

The opening paragraph's raw form was rejected because curly single quotation marks at original UTF-16 offsets 1008, 1039, 1055 and 1091 produced `UnsupportedSymbol`. The four `StudentTextIssue` instances persist this result alongside the normal corpus interpretation, which applies the existing corpus projection. Neither original spelling nor punctuation was overwritten.

| Waveform sources | Track objects | Analyzed channel seconds | RMS frame values | YIN candidate frames |
|---|---:|---:|---:|---:|
| LibriVox dramatic reading | 13 | 9,558.7931 | 477,934 | 477,895 |
| Open Yap conversation | 2 | 4,326.1675 | 216,308 | 216,302 |
| Private performance files | 21 | 2,288.0550 | 114,397 | 114,334 |
| **Total** | **36** | **16,173.0156** | **808,639** | **808,531** |

Open Yap is a single 2,163.0837-second conversation. Both channels were measured separately. Each `StudentWaveEvidence` holds a source reference and dense `Single[]` buffers, with the decoder and Student kernel SHA-256 values. The existing lowered Student RMS and YIN functions ran on decoded 8 kHz mono analysis signals with 20 ms steps. The YIN window was 40 ms and used a 0.15 threshold. These are energy and periodicity observations on the analysis stream. High-band features, speaker identities, phone boundaries and speech/non-speech classes require additional evidence. The original encoded files remain intact.

The measured feature buffers cover all 7,185 Open Yap word labels and all 32 non-word labels. Both channels share the original 48 kHz source clock but carry separate waveform measurements. The `StudentConversationOverlap` query found 735 overlapping publisher word pairs, of which 672 had at least one full analysis frame within their intersection. Among the measured pairs, 195 dropped below −60 dBFS on at least one channel. The threshold is an authored review criterion and does not establish whether a speaker produced a word. The other 63 pairs retain unknown energy comparisons. The 400 ms same-channel gap criterion composed all 7,185 publisher words into 405 `StudentTurnHypothesis` objects. These carry the preceding other-channel candidate and a signed gap in source samples. All 861 private provisional timing cues from two local bundle files were matched to measured windows by exact filename convention. The resulting `StudentTimingCue` links share the same recording and annotation instances. Cue labels remain provisional.

The complete LibriSpeech original-books and dev-clean archives add 635,205,631 retained bytes. On open, the archive reader creates 1,484 `StudentLibriBook` objects, 97 `StudentLibriChapter` objects from 40 readers and 2,703 `StudentLibriUtterance` objects. All 97 chapters linked to a retained book member through the corpus metadata. Every utterance linked to its same-ID normalized transcript and shared chapter instance, with native FLAC sample clock facts totalling 19,396.12075 seconds. These archives were traversed in 13.7 seconds. Their waveform channels and full books still await the deeper acoustic and linguistic passes.

The existing WordNet and Moby graph loaded 161,875 `StudentWordForm`, 212,659 `StudentWordSense`, 120,564 `StudentSynset`, 297,172 `StudentSemanticEdge`, 122,054 `StudentSenseEdge` and 30,259 `StudentMobyGroup` instances. Moby also carries 2,520,225 related-term array entries. It took 23.2 seconds to import both sources and verify their shared sense/synset references. A full document traversal linked 18,964 Alice occurrences, 696,028 in Gutenberg 11615, 58,269 in Gutenberg 14006 and 13,382 in Gutenberg 30036 to 16,490 pooled spelling lookups shared across the works. These were spelling-based candidate links to actual lexical objects, without word-sense or discourse-referent selection. The join rebuilds from retained originals when opened.

The SMA pass preserved 20 complete PowerShell source files from the Student, phonemizer, PSC and local Pwsh checkout, totalling 1,766,263 bytes. Fresh-process parsing restored the actual `ScriptBlockAst`, 290,906 SMA tokens and 3,638 `CommandAst` nodes. AST parent links were checked by reference. Six SMA `TypeNotFound` diagnostics remain visible when parsing the snapshot outside the full runtime environment.

## Reproduction

- `student/Invoke-StudentTextEvidence.ps1` imports the existing Student corpus functions and a hash-verified phonemizer receipt. `-InterpretWork` selects complete works for interpretation. `-InterpretAll` processes all retained Gutenberg works in that pass.
- `student/Invoke-StudentWaveEvidence.ps1 -Decoder <ffmpeg.exe>` decodes the original audio solely for measurement. It writes waveform analysis arrays under `data/source-bank/waveform` and does not replace the originals.
- `student/Join-StudentLexicalEvidence.ps1 -LexiconModule <StudentLexicalCorpus.psm1>` rebuilds shared lexical references.
- `student/Open-StudentLibriSpeech.ps1` composes archive members into book, chapter and utterance objects with publisher transcript links.
- `student/Invoke-StudentSmaEvidence.ps1` captures complete source files and `-Read` reparses the snapshot using SMA.
- `student/Test-StudentUnitBank.ps1` verifies hashes, coverage and reference identities after a fresh-process load.

The final four text binaries occupy 46,616,395 bytes and took 106.9 seconds to produce. The 36 waveform binaries occupy 13,513,690 bytes. Their measurement loop took 192.8 seconds after Student kernel import. The active main binary inventory occupies 6,306,934 bytes. The lexical, overlap, turn, timing and AST queries recreate their CLR views on opening the retained source evidence.

## Open coverage

Independent Student-acquired percepts and resolved discourse referents remain at zero for this expansion. The waveform and linguistic observations give the existing Student material to investigate. They have not gone through independent corroboration, capability admission or recursive reuse. Full-book teacher renders, LibriVox word and phone alignment and actor attribution, acoustic phone identification, validated speech turns and performance events, additional lexical-source semantics, and a comprehensive Gutenberg mirror remain open.
