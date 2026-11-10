# Reference/corpus checkpoint for Fable — 2026-11-10

Scott requested tools down and a local commit for review. No push was requested. This is an incomplete engineering checkpoint, not a completed Student/discovery deliverable.

## Actual progress

- Resident stock-equivalent reference reuse in the two existing owning scripts; config, voice archives and shared token-dependent calculations can remain resident. Voice rows retain the phoneme-count dependency. The comparer checks full token arrays, including hash collisions, and isolates caller-visible arrays from cached data.
- Nine original-reference cases across three voices and three lengths passed 162 byte comparisons including PCM. Frontend-only acquisition separately passed 72 boundary comparisons. These fixtures do not establish broad corpus correctness or learned capability.
- Observation modes separate component boundaries from conditioning capture and optional decoder internals. Actual language/voice objects, source definitions, provenance, duration/control clocks and full normalization dependency extents are retained. Generator normalization point correspondence remains unestablished and is rejected by its point-access method.
- All 8,703 original Common Voice MP3s and 54 verified voice packs are resident. The 2,571 available transcriptions produced 104,806 recursively reachable populated typed instances. This is retained reference evidence and authored analysis, not acquired understanding.
- Ten supplied EPUBs are resident as original archives and ordered XML: 5,729,699 body characters. They have not been fully interpreted or run through stock.

## Where acquisition stopped

The first real corpus pilot retained **32 captures**, not the proposed 336.

Scott then prioritized text breadth and actual stock frontend work. A pass over 2,038 directly eligible inputs was started with af_heart. It retained **six captures** and stopped on:

```
Language emission spans are inconsistent with the observed input.
```

The cause is unestablished. The semantic gate was not bypassed. This is the immediate integration failure to inspect before scaling. The last source-AST-sharing change was exercised by this attempt, but the earlier nine-case PCM suite was not repeated after that metadata edit.

The current English scanner also enforces 8,192 source characters and 256 occurrences in its active clause. Large-document ingestion is not evidence that this frontend already supports the intended continuing interpretation stream.

No speech percept, valid speech three-sigma nomination, useful learned conditioning procedure, broad human-audio alignment, or broad Zira correspondence has been demonstrated. The current Invoke-Discovery default is a native/source correspondence experiment, not an implemented speech discovery loop.

## User's mechanism

The Student is a deterministic acquired worldview operating on a continuing stream of typed objects with extended types. A large unit bank grounds investigation; it is not a percept bank. Seek small recurring relationships that compose on unfamiliar text and reduce repeated work. Rule-of-Three bearings, statistical nomination, practical benchmark validation and mathematical proof remain distinct operations.

FL Studio/Yamaha FM are useful analogies: interacting executable procedures and continuing control state produce a performance. Conditioning may hold, transition and overlap across text objects. Whole-reference-context normalization scope must not be relabeled as an instantaneous event or an intrinsic property of a word type. Unknown preceding context remains unknown.

Stock Kokoro, Zira, Moby and human audio are evidence/instruments. The Student must not inherit stock's predictor interface, sentence/utterance lifetime or a bank of fitted per-category means. Decoder removal is optional. MIDI 2.0 speech extensions are an investigated interface idea, not implemented code or an adopted runtime dependency.

## Review provenance

Both committed scripts already had substantial working-tree changes before this task. This checkpoint includes their complete current versions because the reference additions depend on those existing observation definitions; it does not attribute all their additions to Codex. Other pre-existing modified/untracked files were deliberately left unstaged.

Exact pre-edit snapshots of these two scripts remain under the ignored `build/generator-audit-20261109/resident-reference/`, named by SHA-256:

- Invoke-KokoroDevelopment.ps1: 1A68CF0883F8E0A31AA2F52F4F2C87801D66CCE0EE00F228B677A32348CEDE11
- Invoke-KokoroPrecomputedDecoder.ps1: 1CF27F93C39C1065F01352496315F956CE62142C8C2F070C3BEB3E911BCB8C28

The first filename/hash should be checked against the actual saved snapshot rather than assumed from this note if it differs. Verification receipts and numeric artifacts are also under that ignored build directory; the complete unit bank is not in Git.

The accompanying indictment audit is a snapshot of Scott's requested durable file in Downloads, including historical findings and corrections. Its appendices distinguish measurements, source observations, hypotheses and uncompleted work.

## Live state

PowerShell PID **5940**, tool session **68382**, is idle with the resident evidence. Relevant variables: `SpeechField`, `CorpusBank`, `VoiceBank`, `CorpusLanguages`, `TextStreamCensus`, `MorphologyCensus`, `EpubBank`, `CorpusPilotCaptures`, `StockFrontEndCaptures`, `StockFrontEndFailure`, and `BreadthReference`. Access from another chat is not established; do not assume these objects are persisted or automatically available to a new process.

PSC was left read-only. C:\dev\sma is deprecated and psperception is stale. The phone is available to Scott; current corpus work does not require it.