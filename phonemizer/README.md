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
pwsh -NoProfile -File phonemizer/Invoke-EnglishPhonemizer.ps1 -BuildDriver
pwsh -NoProfile -File tools/Invoke-PhonemizerProbe.ps1 -DriverPath <driver dll> -Soc SM8550
```

The product interface is `CoreDriver.Run(text).SymbolIds` (Kokoro vocabulary IDs, without the BOS/EOS zeros),
valid only when `Complete` is true. Measured in this repository: all Windows gates pass; on SM8550 the driver
loads in 15 ms, takes 25 ms on its first call and 39 us warm per sentence, with IDs identical to Windows; 22 of
the 73 challenge sentences are complete. See `docs/results/phonemizer-driver-sm8550-20261008.md`.

Gaps before end-to-end text input: inflected forms (`-s`, `-ed`, `-ing`), numerals, units, currency, dates and
acronyms, and a default for heteronyms the grammar leaves unresolved. Moby output also lacks stress on monosyllabic
content words and US flaps; Zira's phone events carry no stress either. Planned: a hand-written polish pass.