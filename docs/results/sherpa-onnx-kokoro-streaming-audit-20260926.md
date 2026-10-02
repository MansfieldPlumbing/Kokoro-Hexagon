# Sherpa-onnx Kokoro streaming-method audit, 2026-09-26

Source was already mirrored in `C:\Dev\.vendor\sherpa-onnx`; no clone or
checkout mutation was needed. This audit reads upstream commit
`040afe360a38e25daaa325ce8889abf93ea02609` by immutable Git object.
It is a scheduling comparison only. No sherpa-onnx code, ONNX model, runtime,
or frontend is a Kokoro-Hexagon product input.

## What the callback actually means

- `sherpa-onnx/csrc/offline-tts-kokoro-impl.h:243-263` converts text to
  token-ID units. `piper-phonemize-lexicon.cc:570-595` iterates the
  phonemizer's sentence groups; `:235-269` adds boundary IDs and further
  splits a long group by the model's maximum token count.
- `offline-tts-kokoro-impl.h:267-286` forces Kokoro batch size one even when
  a larger sentence setting is supplied. At `:308-325`, each unit is passed
  to `Process`, appended to the full answer, and only then handed to the
  callback. At `:420-466`, `Process` makes one complete ONNX Runtime model
  call and copies its full output. Thus the callback is per completed
  sentence/token-limited unit, not frame streaming within one Kokoro run.
- `dotnet-examples/kokoro-tts-play/Program.cs:77-93,163-175` starts an audio
  stream, copies each delivered unit to a playback queue, and plays while
  later units synthesize. Its queue is not capacity-bounded, and its playback
  callback allocates/copies arrays at `:117-159`. These are example choices,
  not a latency or robustness standard for our Android audio path.
- The example starts PortAudio before synthesis at `Program.cs:163-174` and
  writes zero-filled output while no completed chunk is queued at `:153-157`.
  Kokoro-Hexagon's existing `src/runspace/Audio.AAudio.psm1:101-118` instead
  primes available PCM before requesting stream start. Preserve that startup
  ordering; its audible latency still needs a real generated-speech test.

## Kokoro-Hexagon consequence

Use completed legal utterance units as one optional scheduling mode after
the exact full-utterance phoneme-to-PCM path works. Keep the model and AAudio
stream resident; hand PCM to a bounded playback queue with cancellation and
explicit drain. Never call a completed-unit callback intra-model streaming.
Compare short-first-unit and steady larger-unit schedules against exact
one-shot execution on identical admitted text, voice, speed, and weights.
Kokoro's context and full-span AdaIN statistics make a segment cut
potentially audible, so segmentation is not stock-equivalent to the one-shot
utterance. Preserve the one-shot path and gate any segmented mode by measured
first-audio latency, gaps/underruns, memory, and listening results.

This was a source audit, not a benchmark. No sherpa-onnx timing, Kokoro-Hexagon
speech timing, device playback, or quality result is inferred from it.
