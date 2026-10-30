# Student front-end judges: composition, recall and role coverage (2026-10-30)

Kokoro-Hexagon at the commit that adds this record (parent `9d4a043`). Three judges of the Student's front end, run
through `StudentJudges` (`student/Invoke-StudentJudges.ps1`), against the phonemizer driver the Student pins
(SHA-256 `666E90BE...`, read from `$script:StudentInputs` in `student/Invoke-Student.ps1`). The judges are owned apart
from the Student. Probe items are generated from the lexicon and the corpus by declared records; none is hand-picked.

## Method

- **Composition (leave whole word out).** Every lowercase lexicon form of at least three letters that the compiled
  morphology (`CoreDriver.WordCompositions`) derives from a root other than the form itself. The derived readings are
  compared with the lexicon's own readings of the whole form (roles 0-4), which composition does not consult. Exact:
  some derived reading equals a lexicon reading. Segments: equal after removing stress marks. Strata are the rule
  chain of the analysis. The lexicon is the reference notation the front end already emits, not independent evidence.
- **Composition recall.** Lexicon forms of at least five letters that are a standard English affix (33 suffixes, 18
  prefixes, `$script:JudgeAffixes`) on a lexicon stem of at least three letters, with standard spelling restoration
  (dropped final e, y written as i, doubled final consonant). Scored: whether the morphology returns any parse. An
  affix-shaped spelling on a lexicon stem is not always a derivation (`reaction`, `image`), so this bounds recall from
  above for the inventory, not its accuracy.
- **Role coverage.** Every 97th blank-line paragraph (40 to 2,000 characters) of each Project Gutenberg text the Student
  reads (`build/grammar-corpus/raw`: 11615, 14006, 30036), through `CoreDriver.Run`. Scored: complete phonemization,
  grammar status, and the share of word tokens carrying at least one grammatical role, which is what clause composition
  (`Invoke-StudentComposition`) consumes. A paragraph the driver throws on is counted with status `Exception`.

## Results

### Composition, 7,197 forms

| Rule chain | Forms | Exact | Segments | More than one reading |
| --- | ---: | ---: | ---: | ---: |
| all | 7,197 | 50.0 % | 57.5 % | 4.9 % |
| AdjectiveAdverb (-ly) | 2,607 | 90.8 % | 95.4 % | 4.6 % |
| AdjectiveNominalization (-ness) | 1,558 | 0.0 % | 0.0 % | 7.6 % |
| NominalPlural (-s) | 752 | 35.5 % | 60.2 % | 5.5 % |
| VerbAgent (-er) | 694 | 83.1 % | 83.9 % | 2.9 % |
| AdjectiveNegation (un-) | 565 | 0.4 % | 23.7 % | 1.9 % |
| RepetitionPrefix (re-) | 369 | 37.7 % | 59.6 % | 2.4 % |
| NominalAbsence (-less) | 227 | 0.0 % | 0.0 % | 7.9 % |
| NominalProperty (-ful) | 183 | 67.8 % | 69.9 % | 2.7 % |
| AdjectiveComparative (-er) | 142 | 71.8 % | 73.9 % | 2.1 % |
| NominalPlural twice | 36 | 0.0 % | 0.0 % | 8.3 % |
| ThirdPersonPresent (-s) | 29 | 27.6 % | 58.6 % | 3.4 % |

- The suffix and prefix phones differ from the lexicon's in every form of four rules: -ness `nəs` against `nɛs`/`nɪs`
  (`absorbedness`), -less `ləs` against `lɪs` (`aimless`), un- `ʌn` against `ən` or `ˌʌn` (`unable`), -ful `fəl`
  against `fʊl`/`fˌʊl` (`armful`).
- 61 forms are analysed with one rule applied twice, all incorrect: plural on plural (`abbess`, `bass`), third person
  on third person (`abyss`, `duress`), re- on re- (`reremouse`). Monomorphemic words ending in a suffix spelling are
  split (`danger` as comparative, `beer` as agent, `abas` as plural).
- re- and un- carry no secondary stress where the lexicon has one (`reaccustom`, `unaccountable`).

### Composition recall, 20,680 forms

| Affix | Forms | Parsed |
| --- | ---: | ---: |
| all | 20,680 | 34.0 % |
| all needing spelling restoration | 3,745 | 4.4 % |
| -ly | 2,930 | 89.3 % |
| -er | 1,797 | 46.6 % (0.8 % of 665 needing restoration) |
| -ness | 1,611 | 96.8 % |
| -ing | 1,133 | 0.3 % |
| -ed | 904 | 2.7 % |
| un- | 815 | 63.2 % |
| -s | 725 | 68.7 % |
| -less, -ful | 232, 200 | 96.1 %, 94.0 % |
| -al, -ism, -ity, -ize, -ist, -ation, -ous, -ment | 4,115 together | 0.0-0.3 % each |
| in-, de-, dis-, over-, sub-, pre-, inter-, out-, under- | 2,499 together | 0.0-0.2 % each |

Within the inventory's own affixes, forms whose stem needs a spelling change are rarely parsed (`abuser`, `abutter`,
`busily`, `applied`, `chilliness`).

### Role coverage, 158 paragraphs, 8,586 word tokens

| Text | Paragraphs | Complete | Word tokens | With a role |
| --- | ---: | ---: | ---: | ---: |
| 11615 | 102 | 3.9 % | 7,262 | 0.1 % |
| 14006 | 48 | 22.9 % | 1,079 | 0.2 % |
| 30036 | 8 | 25.0 % | 245 | 0.8 % |
| all | 158 | 10.8 % | 8,586 | 12 tokens, 0.1 % |

Grammar status: `Contradictory` 78, `Unsupported` 76, `Extensible` 2, `Pending` 1, and one paragraph on which the driver
throws `ArgumentOutOfRangeException`. The only caller of clause composition is its own structural check
(`Test-StudentComposition`), which supplies roles directly; with 0.1 % of word tokens carrying a role, clause
composition is not reachable from corpus text through the driver.

## Limits

- The composition reference is the lexicon's notation. Where the lexicon itself lacks stress (`dumbly` `dəmli`), an
  exact match is not expected.
- Invented-word probes are not scored: a root outside the lexicon is unresolved (`UnknownLexicalIdentity`), so they
  depend on phonics, which the driver does not have.
- Role coverage measures whether roles exist, not whether they are correct.

Receipts: `build/student-judges-20261030T162252` (`Composition.clixml`, `CompositionRecall.clixml`, `RoleCoverage.clixml`).
