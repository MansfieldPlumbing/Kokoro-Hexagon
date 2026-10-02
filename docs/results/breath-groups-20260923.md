# Breath groups from SMA's tokenizer

Prosodic segmentation of a phoneme stream with no grammar, no regex and no Python, by
feeding it to PowerShell's own parser and using the token stream. `tools/Split-BreathGroups.ps1`.

## Why it works

The phoneme stream is not PowerShell, but the tokenizer splits on exactly the punctuation
that delimits prosody, tolerates the parse errors that result, and returns exact character
offsets. Token kind carries boundary strength.

```
phonemes: həlˈoʊ wˈɜɹld. ðɪs ɪz kˈoʊkəɹoʊ ɑn hɛksəɡˌɑn.
tokens=8  errors=0

Identifier  0..6    həlˈoʊ
Generic     7..14   wˈɜɹld.
Identifier  15..18  ðɪs
...
Generic     35..45  hɛksəɡˌɑn.
```

IPA lands as `Identifier`. A word carrying terminal punctuation comes back as `Generic`.
`,` and `;` arrive as their own kinds, `Comma` and `Semi`.

```
'fˈɜst, wiː tˈɛst; ðˈɛn wiː ʃˈɪp!'    Comma:,  Semi:;  Generic:ʃˈɪp!
'ɪz ðˈɪs ɐ kwˈɛstʃən? jˈɛs — ɪt ˈɪz.'  Generic:kwˈɛstʃən?  Generic:—  Generic:ˈɪz.
'wˈʌn tˈuː θɹˈiː ... tˈɛn'            (no boundaries, correctly)
```

So there are two boundary strengths available for free: `Comma`/`Semi`/`Colon` as
intonational-phrase boundaries, and terminal punctuation as breath boundaries.

## Output

```
həlˈoʊ wˈɜɹld. ðɪs ɪz kˈoʊkəɹoʊ ɑn hɛksəɡˌɑn.
   [breath]   0..14  həlˈoʊ wˈɜɹld.
   [breath]  14..45  ðɪs ɪz kˈoʊkəɹoʊ ɑn hɛksəɡˌɑn.

fˈɜst, wiː tˈɛst; ðˈɛn wiː ʃˈɪp!
   [phrase]   0..6   fˈɜst,
   [phrase]   6..17  wiː tˈɛst;
   [breath]  17..32  ðˈɛn wiː ʃˈɪp!
```

A group over the optional frame cap is split at its widest internal gap, so a cut lands
between words:

```
   [split]  0..9   wˈʌn tˈuː
   [split] 10..21  θɹˈiː fˈoːɹ
   ...
```

## Cost

0.055 ms per phrase for the tokenizer call, warm, over 500 iterations - about 18,000
phrases a second. Invoked as a standalone script it measures 5.085 ms, which is process and
scope setup, not the parse.

## Where this fits

Chunking happens at these boundaries and never inside an utterance, which keeps the
temporal axis semantic. Paralinguistic fences cover the joins, and the same bank covers
FIRST_ANY_PCM while the first breath group is still being generated. Neither affects
FIRST_SEMANTIC_PCM or steady-state RTF, which stay separately measured.

`EstFrames` is currently characters times a constant. It becomes real when the duration
predictor runs on device.
