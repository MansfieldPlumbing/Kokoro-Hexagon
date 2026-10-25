# Phonemizer driver on SM8550, 2026-10-08

The compiled pronunciation driver (`phonemizer/Invoke-EnglishPhonemizer.ps1 -BuildDriver`, CoreLib-only,
Moby lexicon plus 4 Zira-admitted corrections) loaded in the phone app's CoreCLR and phonemized the 73-line
challenge corpus (`phonemizer/corpora/english-pronunciation-challenges.txt`) with `CoreDriver.Run`.

| | SM8550 | Windows |
| --- | ---: | ---: |
| Driver SHA-256 | `9E7DD7BE...F6CFBEC` | same file |
| Assembly load | 14.98 ms | |
| First call (cold) | 25.41 ms | |
| Warm median per sentence (median of 73 medians, 25 runs each) | 39.2 us | 121 us mean (`-VerifyDriver` batch) |
| Complete sentences | 22 / 73 | 22 / 73 |
| Symbol ID mismatches vs Windows | 0 / 73 | |

Built in this repository from pinned inputs: Kokoro `config.json` at `f3ff3571`, PSLowering `1afabe05`
(`tools/Get-PhonemizerInput.ps1`, blob ids in `lib/manifest.json`), Moby `0a780d8d` (SHA-256 pinned).
Windows gates `-Verify`, `-Zira` (smoke corpus), `-LowerCorpus`, `-Distill` (4 admitted, 6 held out),
`-Parity` (PASS) and `-VerifyDriver` passed. Run with `tools/Invoke-PhonemizerProbe.ps1`.

Incomplete sentences produce no tokens. The 51 causes: inflected forms missing from the lexicon (`contains`,
`arrived`, `keys`), numerals, units, currency, dates and acronyms (no normalization yet), and 18 heteronyms the
grammar leaves unresolved (`read`, `live`, `close`). Misaki parity is not measured.
