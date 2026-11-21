# Student source breadth, 20 November 2026

This pass prioritizes distinct sources of evidence. One complete literary work anchors the text, dramatic reading and teacher comparison. Three already-available Gutenberg language references remain whole. The source bank sits under the ignored `data/source-bank/` directory. Private performance and lexical items already present in the workspace are referenced in place.

| Source | Verified local coverage | Text and audio relationship |
| --- | --- | --- |
| Project Gutenberg | Four complete eBook files, 7,272,661 bytes and 19,187 paragraph spans. EBooks 11, 11615, 14006 and 30036. The publisher catalog contains 79,769 records. | Original edition bytes remain addressable by SHA-256. Paragraph offsets use UTF-16 positions in the BOM-aware decoding and preserve the source line endings. The catalog count describes entries, including entries without retained local text. |
| LibriVox dramatic *Alice* | All 13 publisher-original VBR MP3 tracks, 152,965,216 bytes. Publisher duration totals 9,559.60 seconds. Every track matched the Archive.org length and SHA-1. | LibriVox nominates Gutenberg eBook 11 as its online text. The typed work link records that publication relationship. Alignment to exact words, passage boundaries and actors remains open. |
| Open Yap 1K public release | One complete 2,163.0837-second conversation, two original FLAC tracks totalling 101,719,323 bytes, and the original metadata/transcript. Xiph FLAC 1.5.0 passed full decode integrity checks for both tracks. | Both tracks are mono 16-bit, 48 kHz and exactly 103,828,016 samples. The typed source index holds 7,185 publisher word intervals and 32 publisher non-word events on that sample clock. The original transcript is machine generated. |
| StudentLexicon | Nine existing reference files, including Open English WordNet 2025+, a distinct 2025 archive, Moby and CMUdict materials. | Existing originals and notices are referenced with file hashes. The existing lexical importer owns lexical semantics. |
| Private generated performance | 21 existing audio files totalling 120,657,538 bytes and 12 timing/script references. | The inventory retains existing file handles and hashes. Event alignment and an injection demonstration remain open. |
| AMI and LibriSpeech | AMI manual annotations v1.6.2 and the OpenSLR 12 release checksum manifest were retained. | Audio transfers were incomplete at verification. These sources contribute annotations or release metadata only in this pass. |

Sources [Project Gutenberg offline catalogs](https://www.gutenberg.org/ebooks/offline_catalogs.html), [LibriVox dramatic reading](https://librivox.org/alices-adventures-in-wonderland-dramatic-reading-by-lewis-carroll/), [Archive.org original item](https://archive.org/details/aliceinwonderland_1102_librivox), [Open Yap dataset card and license](https://huggingface.co/datasets/TheAgenticDataCompany/open-yap-1k), [AMI annotations](https://groups.inf.ed.ac.uk/ami/download/), [OpenSLR 12](https://www.openslr.org/12/).

## Conversation timing

Intersecting the union of the two channels’ publisher word intervals produced 221 disjoint intersections spanning 5,742,695 samples, or 119.6395 seconds. The longest individual word intersection was `[29044800, 29078640)`, approximately 605.100–605.805 seconds. Independent decoding and RMS measurement on the original waveform gave −26.69 dBFS on channel A and −42.39 dBFS on channel B over that window. The 15.70 dB level difference warrants inspecting this window before treating the two transcript labels as equally strong acoustic evidence. Speaker attribution, phoneme hypotheses and retort interpretation remain open.

The acquired Open Yap item came from shard 00000 at publisher revision `cae5c0617b2e225422076599ef99516b73c637e3`. The retrieval entry point uses byte ranges to resume original tar members and skips the preview stream. The full Open Yap corpus requires an access request. Basis Conversations 1500 also requires publisher approval and was unavailable for download in this run. [Open Yap releases](https://huggingface.co/datasets/TheAgenticDataCompany/open-yap-1k) · [Basis dataset access](https://huggingface.co/datasets/basis-ai/basis-conversations-1500).

## Paired teacher output

Both engines accepted the same paragraph beginning at UTF-16 position 12,249 in Gutenberg eBook 11. A previous attempt on the opening paragraph failed in the Student phonemizer. The verified pair sits in `data/source-bank/teachers-alice-with-events/`. Zira produced native 16 kHz WAV with 12 word and 38 phone events on its output clock. Kokoro `af_heart` produced 24 kHz WAV through its existing decoder and generator with seed 17, 59 token durations and 284 predictor ticks per F0 and N curve. The Zira event source reloads through the existing typed English observation importer. Kokoro controls describe model predictions. Real-audio forced alignment and full-work teacher coverage remain open.

## Reproduction and verification

- `student/Invoke-StudentSourceInventory.ps1` builds or refreshes the index and can resume the LibriVox download using `-AcquireAlice`. Pass `-PrivatePerformanceDirectory` only for a private local inventory.
- `student/Get-StudentOpenYapConversation.ps1 -Revision cae5c0617b2e225422076599ef99516b73c637e3` acquires the first full conversation from the pinned public shard.
- `student/Invoke-StudentTeacherPair.ps1` takes an index, an exact `TextSpanUtf16` ID, a local phonemizer driver receipt and a new output directory. It uses the existing Student under PowerShell 7.7 or later on Windows.
- A fresh PowerShell process loaded 26,471 source records, checked every retained file hash, and verified shared CLR parent, child and transcript object references. The teacher index separately restored both audio records to the same span instance. A separate read checked the matching teacher input text, predictor array lengths and Kokoro waveform hash.

Providence acoustic phone discovery, the NL1/PSC admission cycle, captured-event playback and native 48 kHz Opus output remain open.
