# Phonemizer

English text to Kokoro token IDs. Windows SAPI Zira's contextual pronunciation choices (for example noun/verb
`record`) are captured, lowered into a compact PSD1, and compiled with their selection logic into a CoreLib-only
assembly; no SMA at run time. Workflow: [ZIRA-DISTILLATION.md](ZIRA-DISTILLATION.md).

Developed in PSPerception and imported from GitHub `MansfieldPlumbing/PSPerception` at
`ab9f24ccedfede345187e07764b345f6d10e45d0`; each file's git blob id is checked against that commit:

| File here | Source path | Blob | Check |
| --- | --- | --- | --- |
| `phonemizer/Invoke-EnglishPhonemizer.ps1` | `phonemizer/Dev.MansfieldPlumbing.English.Phonemizer.ps1` | `45946de23bd062e075b3607112b75f954992c0aa` | verified at import; since renamed and edited here (build paths) |
| `phonemizer/corpora/english-pronunciation-challenges.txt` | `phonemizer/corpora/english-pronunciation-challenges.txt` | `fbfeb7d03fc4a936aab3f36800becc393ce4bf96` | verified |
| `phonemizer/corpora/record-context-smoke.txt` | `phonemizer/corpora/record-context-smoke.txt` | `0b0af5d958e98a03a52a4252bb65d2d778fea9f7` | verified |
| `phonemizer/ZIRA-DISTILLATION.md` | `docs/ZIRA-DISTILLATION.md` | `3c1a22252294fbae4b2a3091214a69105e6bb053` | verified at import; since edited here (paths) |

Not imported: `phonemizer/GetSmaPhonemes.ps1` (the earlier SMA path, which depends on PSPerception's
`experiments/` and `src/`).

## Build and run here

Generated files go under `build/phonemizer` (lexicon reference, Zira captures, typed corpora, driver). Inputs:
`tools/Get-KokoroModelInput.ps1` (Kokoro `config.json`), `tools/Get-PhonemizerInput.ps1` (PSLowering at the commit
and blob ids pinned in `lib/manifest.json`); Moby data is fetched SHA-256 pinned by `-Build`.

```powershell
pwsh -NoProfile -File phonemizer/Invoke-EnglishPhonemizer.ps1 -Build
pwsh -NoProfile -File phonemizer/Invoke-EnglishPhonemizer.ps1 -GenerateCorpus
pwsh -NoProfile -File phonemizer/Invoke-EnglishPhonemizer.ps1 -Zira -CorpusPath build/phonemizer/english/corpora/scaled/capture.txt
pwsh -NoProfile -File phonemizer/Invoke-EnglishPhonemizer.ps1 -Distill -CorpusPath build/phonemizer/english/corpora/scaled/construction.txt -ValidationCorpusPath build/phonemizer/english/corpora/scaled/held-out.txt
pwsh -NoProfile -File phonemizer/Invoke-EnglishPhonemizer.ps1 -BuildDriver
pwsh -NoProfile -File phonemizer/Invoke-EnglishPhonemizer.ps1 -Verify
pwsh -NoProfile -File phonemizer/Invoke-EnglishPhonemizer.ps1 -Parity
pwsh -NoProfile -File phonemizer/Invoke-EnglishPhonemizer.ps1 -VerifyDriver
pwsh -NoProfile -File tools/Invoke-PhonemizerProbe.ps1 -DriverPath <driver dll> -Soc SM8550
```

The product interface is `CoreDriver.Run(text).SymbolIds` (Kokoro vocabulary IDs, without the BOS/EOS zeros),
valid only when `Complete` is true. `CoreDriver.RunLexical(text)` is the same driver without the polish pass; the
gates check it against the SMA reference path. Results: `docs/results/phonemizer-polish-sm8550-20261008.md`
(earlier: `docs/results/phonemizer-driver-sm8550-20261008.md`).

## Pipeline

1. Lexicon: Moby pronunciations (public domain, SHA-256 pinned) decoded to Kokoro phones. A word's lowercase rows
   come before its capitalized rows (City, Here, Rose: names and other readings). Decoded units include `[@]`
   (ɜ), `/ju/`, `a`, and doubled delimiters (`b//Oi//`); `/A//I/` and `/&//U/` become I and W. Foreign-sound units
   (`R`, `x`, `y`) stay undecoded (2,480 of 177,267 rows). Phone strings are interned ordinally: Kokoro phones are
   case-sensitive (I/i, A/a, O/o).
2. Grammar roles and Zira choices: the CoreLib grammar assigns roles for the constructions it supports; admitted
   Zira choices (`word:role:following-onset`) replace the lexicon phones.
3. Polish pass (`CorePolish`, `CoreDriver.Run` only), in this order:
   - Open spans: a unit after a number (`12 MB`, `5 Mb/s`, `9 PM`); acronyms of two or three capitals, or longer
     ones the lexicon lacks, spelled with primary stress on the last letter (`FBI`, `CPU`); heteronym and variant
     defaults from the previous word (determiner: noun; pronoun, modal, `to`, `please` or clause start: verb;
     copula: adjective; `read` is past after `had`/`was`/`he` or with `yesterday`/`ago`/`last`). Same-role Moby
     variants prefer the role-tagged row, then fewer syllables. For words not in the lexicon: numbers (cardinals,
     years, ordinals, decimals, versions, currency, percent, times, `M/D/Y` dates, fractions, digit strings with
     leading zeros or dashes, a day after a month name), abbreviations followed by a period (`Dr.`, `St.` as saint
     before a capitalized word, else street; the period is silent when more words follow), contractions and
     possessives, and regular inflection (`-s/-es/-ies` as s/z/ɪz, `-ed/-ied` as t/d/ɪd, `-ing`, with e-drop and
     doubled consonants). A hyphen or slash between words is silent; `&`, `+`, `@` are read.
   - Function words (about 90, with contractions) take their weak form before another word and a full form at the
     end of a phrase. Forms follow Zira's captures where captured: `to` tʊ (36/36), `and` æn (21/21), `of` ʌv
     (15/15), `for` fəɹ (12/12, final fɔɹ), `the` ðə and ðɪ before a vowel (158 of 984), `I` I (153/153).
   - Primary stress before the vowel nucleus of every content word without one (secondary promoted first; a
     stressed schwa becomes ʌ, or ɜ before ɹ). Function words stay unstressed.
   - US flap within a word: t or d after a vowel, or t after ɹ, before a reduced vowel or syllabic əl (water,
     better, city, little, ladder); not before a full vowel (detail), a final ən (button), or for d after ɹ.
     Zira-admitted words keep Zira's segments (Zira has no flaps), with stress added.

## Zira corpus

`-GenerateCorpus` writes an authored, deterministic corpus to `build/phonemizer/english/corpora/scaled`: 559
construction and 281 held-out sentences in constructions the grammar resolves (pronoun subject, transitive verb,
determiner object; copular property; the original smoke pairs), plus 164 carrier sentences used only to measure
function-word forms. 1,004 sentences, captured in 95 s; 991 align exactly. Admission: 192 choices admitted (30 of
them change a pronunciation, none regress a held-out word), 48 rejected (43 would change lexical stress Zira cannot
show), 877 held-out teacher checks. No third-party text is used.

## Known gaps

Proper names and words outside Moby that are not regular inflections stay incomplete (no letter-to-sound rules);
`-er/-est/-ly` and prefixes are not derived. Moby errors pass through (`singer` /sˈɪnʤəɹ/, `upstairs`); `lives` is
always /lIvz/. Heteronym defaults are a previous-word heuristic, not a parse. Numbers above 999,999,999 are read
digit by digit. Weak forms are not applied to Zira-admitted words.
