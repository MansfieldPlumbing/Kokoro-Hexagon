# Zira observations, contextual selection and Kokoro speech

The executable entrypoint is
`phonemizer/Dev.MansfieldPlumbing.English.Phonemizer.ps1`.
It streams a UTF-8 text corpus into one compact PSD1 intermediary, projects
validated records into typed observations, and lowers pronunciation knowledge
and selection logic into a managed assembly. Stock Kokoro is the Windows audio
reference. The standalone pronunciation driver references only
`System.Private.CoreLib`; it does not load SMA, Zira or the PSD1 at runtime.

## One entrypoint and one intermediary

Run from `C:\Dev\PSPerception`:

```powershell
# Six contextual examples; replace this input with a larger sentence corpus.
pwsh -NoProfile -File phonemizer/Dev.MansfieldPlumbing.English.Phonemizer.ps1 -Zira -CorpusPath phonemizer/corpora/record-context-smoke.txt

# Embed observations with their timing and reference graph, without admitting rules.
pwsh -NoProfile -File phonemizer/Dev.MansfieldPlumbing.English.Phonemizer.ps1 -LowerCorpus

# Admit contextual choices using separate construction and held-out examples.
pwsh -NoProfile -File phonemizer/Dev.MansfieldPlumbing.English.Phonemizer.ps1 -Distill

# Check target token parity and canonical standalone behavior.
pwsh -NoProfile -File phonemizer/Dev.MansfieldPlumbing.English.Phonemizer.ps1 -Parity
pwsh -NoProfile -File phonemizer/Dev.MansfieldPlumbing.English.Phonemizer.ps1 -VerifyDriver

# Synthesize and play through the compiled pronunciation driver.
pwsh -NoProfile -File phonemizer/Dev.MansfieldPlumbing.English.Phonemizer.ps1 -Speak -Text 'Play the record.'
pwsh -NoProfile -File phonemizer/Dev.MansfieldPlumbing.English.Phonemizer.ps1 -Speak -Text 'Please record it.'
```

The default intermediary is
`%LOCALAPPDATA%\Build\PSPerception\english\zira-corpus.psd1`.
`-ObservationPath` selects another output in the project build directory.
Corpus capture reads one nonblank line at a time and flushes each observation
to a temporary file. A completed run replaces the destination, retaining a
backup of any previous file. A failed run leaves a `.partial` file and preserves
the previous completed destination. This is a streaming writer; it does not
retain the whole corpus in memory or create one capture file per sentence.

Use sentences to retain context. Isolated words cannot identify the intended
noun/verb reading. The existing
`phonemizer/corpora/english-pronunciation-challenges.txt` contains 73 short
challenges, including heteronyms, numbers, dates and units. These are test inputs,
not a claim of supported pronunciation coverage.

Custom admission partitions use `-Distill -CorpusPath <construction.txt>
-ValidationCorpusPath <held-out.txt>`. Both partitions must already be present
in the single captured PSD1 and must not overlap. The default construction
sentences are the first three smoke examples; the last three are held out.
Admission does not capture new teacher observations or silently use the stock
Kokoro phonemizer.

## Compact schema and preserved meaning

PSD1 is literal PowerShell data source, read with `Import-PowerShellDataFile`.
It is never evaluated as executable corpus code. No JSON conversion is used
for pronunciation observations, admission, token handoff or driver receipts.
Stock Kokoro's pinned model configuration and the .NET host's required
runtime configuration retain their upstream formats.

The corpus header stores the schema version, teacher profile, input corpus
SHA-256, and speech-assembly/engine SHA-256 once. Profile opcode `q=1` identifies
Microsoft Zira Desktop, en-US, rate zero and null audio output. Each utterance
retains its identity, full source text, UTC capture ticks, partition, alignment
status, raw phone events and word records.

Each raw phone event has six positional fields:

```powershell
@('phone','nextPhone',audioTicksL,durationTicksL,emphasisFlags,eventIndex)
```

Each word has twelve positional fields:

```powershell
@('word',role,'rawPhones','kokoroPhones',@(tokenIds),sourceStart,sourceLength,audioTicksL,wordEventIndex,@(phoneEventIndices),stressFlags,@(roleAlternatives))
```

Roles are `0` noun, `1` verb, `2` adjective, `3` participle, `4` function,
and `-1` unresolved. The role is inferred by our execution rules; Zira's
phoneme events do not supply a grammatical role. Before contextual admission,
the emitted words retain `-1`. Admission updates the role and alternatives
without replacing the raw teacher evidence. Partitions are `C` construction,
`H` held out and `U` unassigned.

Word records reference the shared phone-event table by index. Aligned word
indices reference the original word table. Lowering restores shared object
references, including each word's parent utterance. Raw phones, next phones,
pauses/control events, durations, audio positions, emphasis, source spans,
context, token identities and role alternatives remain available. Control
events are excluded from spoken token strings, not erased from observations.

Pronunciation mapping explicitly handles Zira's rhotics, affricates and tied
diphthongs. Unknown target symbols fail validation. There is no rule that
silently deletes arbitrary unknown symbols or combining marks.

## Contextual admission

The existing grammar now supports the explicit leading commands `play`, `push`,
`press` and `record`, optionally introduced by `please`, with an implicit
subject. It resolves the tested contrasts:

| Source | Selected record role | Retained Kokoro pronunciation |
|---|---:|---|
| Play the record. | 0 | `ɹˈɛkəɹd` |
| Please record it. | 1 | `ɹɪkˈɔɹd` |
| Push record. | 0 | `ɹˈɛkəɹd` |

These are explicit supported constructions, not a general English parser.
Selection uses word identity, admitted role and following vowel-onset context.
The corpus keeps complete utterance context even though the dispatch key is
compact. A contradictory teacher pronunciation, unknown target phone or
missing held-out support prevents admission. Accepted and rejected choices
retain their supporting observation graph in the typed corpus assembly.

Zira's segmental observations are the pronunciation reference. Existing lexical
stress is retained only when removing that stress produces exactly the observed
teacher phones. A changed pronunciation requiring unavailable lexical stress
is rejected. Zero emphasis flags do not establish missing lexical stress.
Agreement with Zira establishes teacher fidelity, not independent English
accuracy or universal Kokoro audio quality.

The existing Moby-derived lexicon remains the fallback for words without
admitted teacher knowledge and supplies earned stress where independently
matching. This change does not replace its entire vocabulary with six teacher
examples. `-Speak -UseZira` instead captures the full utterance live and feeds
only those observations to the compiled target-token mapper.

No neural trainer or new parser was introduced. The existing hillclimber was
not needed for the smoke examples. It remains a possible fallback for residual
distinctions that explicit admitted rules cannot resolve.

## Microsoft source investigation

Microsoft's [SAPI TTS engine porting specification](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/ee431802(v=vs.85))
documents pronunciation alternatives, explicit part-of-speech hints, context
fields, phoneme event durations and feature flags. It specifies that the
part-of-speech field is unknown unless the caller supplies a hint. The
[GetPronunciations API](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/ee125564(v=vs.85))
exposes user/application lexicon alternatives. Neither establishes access to
Zira's internal contextual selector or its entire engine lexicon. The source
search did not find a reusable published implementation of that selector.
No unrelated SDK or neural model was imported.

## Demonstrated gates, October 8, 2026

The six smoke utterances emitted 19 words and 83 raw phone events in 4.33 seconds
on the observed Windows machine. This includes capture setup and output; it is
not a prediction of throughput on a large corpus.

The 73-utterance challenge corpus separately emitted 332 word events and 1,272
raw phone events into one PSD1 in 16.92 seconds. Its token-parity gate passed
with 1,292 mapped symbols, zero dropped symbols and 153 retained pause/control
events excluded from spoken token strings. Contextual alignment remains
explicitly unproved where source spans cannot be established.
All 73 utterances also passed typed lowering with original word fields and
phone references checked, including partially aligned observations. Unproved
alignment does not enter pronunciation rule admission.

- `TYPED_ZIRA_CORPUS_LOWERED`: six utterances restored from the compiled
  observation assembly, with field equality and shared phone/word references
  checked. Assembly references: `System.Private.CoreLib` only.
- `ZIRA_CONTEXTUAL_ADMISSION=PASS`: four admitted choices, three retained
  rejections, six held-out comparisons and six canonical teacher checks.
  This includes corroborated existing pronunciations; four admissions do not
  mean four previously incorrect pronunciations were fixed.
- `CORELIB_STANDALONE_PHONEMIZER=PASS`: 26 fixtures, the three independent
  imperative record assertions, four separate .NET processes without SMA,
  11 teacher-backed token checks, and OOV/input-bound rejection.
- `ZIRA_TO_KOKORO_TOKEN_PARITY=PASS`: all 114 target vocabulary IDs checked
  against the pinned model configuration; 84 mapped symbols across six captured
  utterances; zero dropped symbols; 12 pause/control events excluded from spoken
  tokens but preserved as observations. Separate-process mapping loaded no SMA.
- `PHONEMIZER_TO_STOCK_KOKORO_WAV=PASS`: `Play the record.` produced 39,600
  mono PCM samples at 24 kHz, 1.65 seconds, using the lowered driver phones.
  `Please record it.` separately produced and played 39,000 samples,
  1.625 seconds, through the same canonical driver.

Warm compiled timing, excluding capture, compilation, process startup and audio:
the parity run measured a 1.482 microsecond median batch mean for raw-phone
mapping and 127.084 microseconds for the full sentence driver. Each is the
median of nine batch means, not an individual-call latency percentile.
The subsequent 73-utterance parity run measured 1.938 microseconds for mapping
and 107.831 microseconds for the same full-driver fixture. A separate 2,000-run
driver verification measured 335.523 microseconds under another observed load;
these measurements are not an idle-machine latency guarantee.

Pins: PSLowering `1afabe056235a570da29e268824784557d4f6cdd`, stock Kokoro source
`dfb907a02bba8152ca444717ca5d78747ccb4bec`, model revision
`f3ff3571791e39611d31c381e3a41a3af07b4987`. Cached source and assets are
hash-verified before execution. Generated adapters and compiled artifacts stay
under the project build directory. The Windows stock audio backend is not an
Android runtime dependency.

Current lowering/admission guards allow at most 4,096 utterances and 128 MiB of
PSD1 input. Capture itself streams larger corpora. Large-corpus lowering,
resume/append after failure, comprehensive unseen-word coverage, general
number/date verbalization and broad contextual accuracy are unproved. The
emitted corpus retains unsupported evidence for subsequent refinement rather
than presenting it as a completed phonemizer.
