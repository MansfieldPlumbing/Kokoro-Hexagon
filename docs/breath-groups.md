# Breath groups

The host splits phonemized text into breath groups on the CPU and renders one group at a time on the DSP, rendering
the next while the current one plays. Each group is an independent stock Kokoro call (stock `KPipeline` already runs
each chunk independently, AdaIN statistics over the whole chunk, voice style `pack[len(ps) - 1]`), so the split points
are our policy; the model math per group is stock.

## What people do

- Read speech: mean breath group 4.05 +/- 1.5 s (273 groups), spontaneous speech 4.88 +/- 1.93 s (1,106 groups);
  per-speaker means 3.50 and 4.35 s. Breaths fall at sentence ends, punctuation, and before noun, verb or adverbial
  phrases; never inside words (Wang et al. 2010, PMC2945274).
- Read speech, 18 speakers: 3.06 +/- 0.62 s and 17.95 syllables per breath group (Korean; koreascience
  JAKO200804748556267).
- Film dialogue: mean 1.9 s, 87% within 3.0 s (reported in search results; not read in full here).

## Policy

1. **First group very short**, because time to first audio is the time to render it. End it at the earliest
   grammatical boundary (punctuation, or before a noun, verb or adverbial phrase; the phonemizer's clause and nominal
   structure gives these) after a minimum of two words, aiming at about one second of speech. Shorter groups lose
   prosodic context; that cost is accepted for the first group only.
2. **Each later group grows** toward a natural length of 3-4 s, ending at the best boundary: sentence end, then
   punctuation, then a phrase boundary. A group may be longer than the previous one only as far as it still renders
   before the previous one finishes playing: duration(next) x RTF <= duration(current), with RTF the measured
   whole-model value on that phone plus margin.
3. **Hard limits**: at most 510 phonemes (stock), never split inside a word.
4. Durations are not known before the duration predictor runs, so the splitter plans by phoneme count, converted with
   a phonemes-per-second rate measured from our own predicted durations [rate not yet measured].

Not yet built: the splitter, the measured rate, and the time-to-first-audio and gap-free playback receipts on both phones.
