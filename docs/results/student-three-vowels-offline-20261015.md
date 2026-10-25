# Three-vowel trace and frozen lexicon cause

This follows the initial corpus audit without changing its historical receipt.
The test is offline, with no device, Python execution or bank replacement.

## Historical cause

The frozen reference build receipt's source SHA256,
`18019F37D00C14D4268C8BD1CAA131F4232B77082FF19F59AFFCCBD97F8437F1`,
exactly matches the LF source of `phonemizer/Invoke-EnglishPhonemizer.ps1` at
`df29cffe89da5e42d8aa155a6147af02d3f9662b`.

That revision translates Moby identities through an ordinal map, including
`aI=I`, `I=ɪ`, and `i=i`. Its later pronunciation interning uses `$interned=@{}`,
a case-insensitive hashtable. Replaying that actual interning function on
`i`, `I`, `ɪ` stores only `iɪ`; the second entry reuses the first entry's offset.
Thus distinct translated phonetic identities can collapse before emission.
The ordinal interning correction is present in
`7924b9b388050f0f8c34df6466065f5e5ff6d53e`; the preserved artifact was not rebuilt.

## Controlled trace

| Word | Pinned raw Moby notation | Current translation | Frozen lookup | Rebuilt lookup | Frozen emitted | Rebuilt emitted |
| --- | --- | --- | --- | --- | --- | --- |
| eye | `/aI/` | `I` | `i` | `I` | `ˈi .` | `ˈI .` |
| bit | `b/I/t` | `bɪt` | `bɪt` | `bɪt` | `bˈɪt .` | `bˈɪt .` |
| see | `s/i/` | `si` | `si` | `si` | `sˈi .` | `sˈi .` |

The raw pronunciation file SHA256 is
`EAB1C6DFDA47178A36103041C118398C9A10ED1CE08C14D9D43865D60275B0D4`,
from Moby commit `0a780d8d6a83909f9538b01aba8c6848b6689935`.
No new claim about the original alphabet is inferred merely from capitalization:
the translator and downstream interning are separate boundaries.

Both variants of “Eye bit see.” use the same first 1,000 bank sentences,
selector source, context weights and K. At target unit 2, frozen selection
chooses sentence 962, token 12, symbol `i`; corrected selection chooses
sentence 883, token 35, symbol `I`. At unit 6, both select sentence 678,
token 20, symbol `ɪ`; at unit 11, both select sentence 144, token 27, symbol `i`.
The whole selected sequence may change because selection includes join costs.

For “Peach. I could eat a peach for hours.”, both drivers emit exactly
`pˈiʧ . I kʊd ˈit ə pˈiʧ fəɹ ˈWɹz .` under ordinal comparison. Both 1,000-sentence
selections choose the same ordered 36 donor IDs. The requested lexical
intervention therefore changes no acoustic input for this sentence. No
duplicate WAV is presented as an improvement. The separate 25 versus 75 ms
“I” listening test remains a duration intervention, with changed noise layout.

## Implementation and validation

Fresh Student text selection defaults to the separately rebuilt driver.
`DriverDirectory` plus an explicit `DriverSHA256` permits a controlled historical
comparison. The historical bank, lexicon DLL and captures remain read only.
The builder's fidelity assertion now uses explicit `StringComparison.Ordinal`.

`BuildDriver -LibraryOnly` omits the compiler entrypoint and emits a managed
library without a host runtime JSON. A first diagnostic attempt retained the
compiler entrypoint, which emitted an unintended runtime config; its bytes
were preserved in CLIXML and that generated JSON was removed. The final
library directory contains no JSON. Existing executable-driver behavior remains
available without `LibraryOnly`.

- Corrected library driver source identity:
  `D7B06FD52B900130E8702544D14BE2F662EC2E009EFCE6B33E3FC92BE8B70AD1`.
- Corrected library DLL SHA256:
  `112DC0B565042184DF74FA5176F09F6E8294857693B44F0BBED456A43B3FEEF1`.
- Selector source SHA256:
  `293DA2E73F207595B2368F224FAC681157AC22BE28EB0913B1674F1093A274FA`.
- Trace artifacts: `build/phonemizer/case-check-20261015/three-word-trace.clixml`
  and `three-word-selection-trace.clixml`.
- Selections: `build/student-three-words-frozen-20261015/`,
  `build/student-three-words-corrected-20261015/`, and
  `build/student-peach-corrected-selection-20261015/`.

No hardware/SDK/API performance claim or acoustic duration norm is established
by this test. The Moby-to-Kokoro translation was correct in the traced source;
the verified failure was downstream case-insensitive pronunciation interning
and continued use of its frozen output.
