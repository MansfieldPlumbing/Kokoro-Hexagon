# Phonemizer polish pass on SM8550, 2026-10-08

`CoreDriver.Run` now applies a hand-written polish pass (`CorePolish`) after Moby lookup, grammar roles and Zira
choices: units, acronyms, numbers, abbreviations, contractions, regular inflection and heteronym defaults for open
spans; Zira-measured function-word forms; primary stress on content words; US flaps within words. Code: commit
`7924b9b`. Driver SHA-256 `8AAF6DA2B7B932D840686B58542F678F7513C602007FF50DE89FFDFF1CEA27CF` (CoreLib only).

| | Before (driver `9E7DD7BE...`, `d3c48ba`) | After, Windows | After, SM8550 |
| --- | ---: | ---: | ---: |
| Challenge corpus complete (73) | 22 | 73 | 73 |
| Held-out set complete (153, committed before the rules) | 37 | 149 | 149 |
| Symbol ID mismatches vs Windows | | | 0 / 73, 0 / 153 |
| Assembly load | 14.98 ms | | 17.8 ms, 18.8 ms |
| First call (cold) | 25.41 ms | | 996 ms, 984 ms |
| Warm median per sentence (median of medians, 25 runs each) | 39.2 us | 53.7 us mean (`-VerifyDriver`) | 57.8 us (challenge), 96.6 us (held-out) |

Before-column timings are from `phonemizer-driver-sm8550-20261008.md`; before counts and phones are from the same source (`d3c48ba`) rebuilt here (driver `5484381585FF0FD2...`).
The held-out count was 145 before a Moby decoder fix (doubled delimiters, `b//Oi//`) that held-out words exposed.
The cold first call grew about 40x; not yet diagnosed (likely JIT of the larger driver and first use of the lexicon
strings). The 4 held-out misses: `pair` (Moby row undecodable), `smaller`, `safely`, `restarted` (no
`-er`/`-ly`/prefix rules).

Lexicon fixes in the same commit: phone strings were interned in a case-insensitive hashtable, which merged `I`
with `i` (the pronoun I came out as `i`, `pipe` as `pip`); Moby rows rejected by the decoder fell from 9,041 to
2,480 of 177,267.

Zira corpus: 1,004 authored sentences captured (559 construction, 281 held out, 164 carriers); admission 192
choices (30 change a pronunciation, 0 held-out regressions), 48 rejected, 877 held-out teacher checks.

Windows gates passed on this driver: `-Verify`, `-Distill`, `-Parity` (1,004 captures, 17,889 symbols, 0
dropped), `-VerifyDriver` (26 SMA-equivalence fixtures on `RunLexical`, 20 polish fixtures, 2,570 teacher checks),
`-Speak` (stock Kokoro, af_heart). Listening WAVs (before/after for 3 sentences, after-only for 2) were generated
for the team to listen to; their quality is not assessed here.

Fixed sentence set, phones before and after (polish fixtures in `Test-EnglishCoreDriver`):

| Sentence | Before (5484381585FF0FD2) | After (8AAF6DA2B7B932D8) |
| --- | --- | --- |
| They live here. | incomplete | `ðA lˈɪv hˈiɹ .` |
| I saw her duck. | `i sˈɔ hɜɹ dˈʌk .` | `I sˈɔ hɜɹ dˈʌk .` |
| The water was better than the little ladder. | `ðə wˈɔtəɹ wəz bˈɛtəɹ ðæn ðə lˈɪtəl lˈædəɹ .` | `ðə wˈɔɾəɹ wəz bˈɛɾəɹ ðæn ðə lˈɪɾəl lˈæɾəɹ .` |
| The kitten sat on a pretty button. | `ðə kˈɪtən sæt ɑn ə pɹˈɪti bˈʌtən .` | `ðə kˈɪtən sˈæt ɑn ə pɹˈɪɾi bˈʌtən .` |
| The apple fell. | `ðə ˈæpəl fɛl .` | `ðɪ ˈæpəl fˈɛl .` |
| The rebels rebel. | incomplete | `ðə ɹˈɪbɛlz ɹɪbˈɛl .` |
| The pipe contains lead. | incomplete | `ðə pˈIp kəntˈAnz lˈɛd .` |
| John's keys aren't here. | incomplete | `ʤˈɑnz kˈiz ˈɑɹnt hˈiɹ .` |
| I read it yesterday. | incomplete | `I ɹˈɛd ɪt jˈɛstəɹdi .` |
| We stopped, tried and ended. | incomplete | `wi stˈɑpt , tɹˈId æn ˈɛndɪd .` |
| The total is $12.50. | incomplete | `ðə tˈOɾəl ɪz twˈɛlv dˈɑləɹz æn fˈɪfti sˈɛnts .` |
| Meet at 12:05 PM. | incomplete | `mˈit æt twˈɛlv ˈO fˈIv pˌiˈɛm .` |
| The rate is 5 Mb/s. | incomplete | `ðə ɹˈAt ɪz fˈIv mˈɛɡəbˌɪts pəɹ sˈɛkənd .` |
| The date is 03/04/2026. | incomplete | `ðə dˈAt ɪz mˈɑɹʧ fˈɔɹθ twˈɛnti twˈɛnti sˈɪks .` |
| Use a 3/4-inch pipe. | incomplete | `jˈuz ə θɹˈi kwˈɔɹɾəɹz ˈɪnʧ pˈIp .` |
| NASA called the FBI. | incomplete | `nˈæsə kˈɔld ðɪ ˌɛfbˌiˈI .` |
| Dr. Smith lives on Main St. | incomplete | `dˈɑktəɹ smˈɪθ lˈIvz ɑn mˈAn stɹˈit .` |
| I want to go to the city. | `i wɑnt tu ɡO tu ðə sˈɪti .` | `I wˈɑnt tʊ ɡˈO tʊ ðə sˈɪɾi .` |
| Give it to him and to her. | `ɡɪv ɪt tu hɪm ænd tu hɜɹ .` | `ɡˈɪv ɪt tʊ hɪm æn tʊ hɜɹ .` |
| What are you looking at? | incomplete | `wˈʌt ɑɹ ju lˈʊkɪŋ æt ?` |
