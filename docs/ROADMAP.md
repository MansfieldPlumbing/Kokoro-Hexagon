# Roadmap

Follow [the shared rules](../../Pwsh-Development/AGENTS.md) and this repository's
[AGENTS.md](../AGENTS.md). Updated 2026-10-10. The newest
[handoff](handoff-20261010.md) owns the numbered implementation steps and commands;
this file records delivery priorities and open engineering questions. Device
receipts live in `docs/results/`. Published comparisons belong in the
[README comparison chart](../README.md#published-comparisons).

## Active priority: Student-driven phase generator

The [active contract](student-generator-contract.md) supersedes the earlier
bank/decoder integration order below. One 300-sample clock; Student-generated
512-channel features and affine/phase controls; existing hardware Lock/bounce;
frozen generator as the neural runtime. No runtime normalization reductions,
trig Snake or acoustic lookup bank. Stock paths remain offline evidence.

The architecture is flexible: it runs with or without the decoder. The front end
has been replaced by a custom phonemizer that runs on CoreCLR.
The Student is accepted only by held-out dB: 40 dB is the absolute floor and it
must ratchet to at least 70 dB ([contract](student-generator-contract.md)).

## Earlier bank/decoder integration track (reference only)

The accepted network-free system is good enough for integration. Previously
unprepared text entered on SM8550 must produce audible speech through the installed
APK host and local model/bank payload with Windows disconnected. Start with a short
sentence, then bounded long-form speech and SM8635. The host and model payload ship
separately; both must be installed before inference.

The active front end is our compiled phonemizer, unit bank and PowerShell-learned
prosody tables. ALBERT, the text encoder and predictor LSTMs populate reference
captures offline; they are not phone dependencies for this variant. The stock
whole-model DSP track remains a separate numerical and benchmark reference.

Integration needs generator runtime-frame support, a compiled selector and persisted
learned tables, an indexed local bank, deployment calibration checked on holdouts,
and the resident front-end -> DSP -> AAudio chain. Reuse the existing APK host and
PSLowering inputs at their pinned commits. No Windows-prepared per-utterance capture,
scale or input is allowed at playback. Keep typed objects and binary buffers in
process, without JSON serialization between stages. User text is data, never code.

Pronunciation improvements, learned AdaIN controls, 17x speed, instruction packet
scheduling and a general graph tiler do not block the first resident sentence.
Stateful frame chunking and activation binding are the subsequent streaming work;
fix any memory or correctness blocker needed for integration in that path.

## Established baseline and remaining measurements

The [accepted SM8550 sentence](results/bank-front-end-sm8550-20261010.md) contains
85 decoder frames and 51,000 PCM samples (2.125 s). Median DSP execution is
148.495 ms, 14.3x real time, with 31.29 dB PCM SNR and zero clipping. It was heard
through the phone speaker. Windows prepared its inputs; complete fresh-text Android
synthesis is still pending. The 179.790 ms median host invoke is a separate timing,
also excluding the full text-to-audio pipeline.

After integration, measure warm and cold text-to-PCM latency, request-to-first-audio
and end-to-end RTF on the same text, keeping DSP and host timings distinct. Report
SM8550 and SM8635 separately, with artifact hashes, fidelity and listening evidence.
17x is an optimization target, not an established mobile leadership claim.
[The six-passage stock comparison protocol](speed-target.md) remains available;
label network-free results as the variant and refresh competitor data when used.

## Frame chunking as temporal tiling

Investigate arbitrary decoder-frame cut points, including cuts inside phonemes.
Words, word groups and breath groups supply linguistic context and acoustic controls;
they do not set DSP job boundaries. Preserve that context as the execution moves
through fixed-size frame chunks and a final partial chunk.

Start by measuring the largest object passed between stages, its required carried
state, and the other simultaneously live objects at each handoff. Include weights,
scratch, alignment and HMX page constraints in the peak-memory bound. Use those
bounds to test a static frame-chunk size and buffer schedule for each supported VTCM
grant. Arbitrary cut points do not require a dynamic scheduler. Runtime replanning
or additional tiled dimensions are extensions only if the static schedule cannot
meet the measured requirements.

Bind producer outputs directly to consumer inputs in the native activation layout,
retain the live working set in VTCM and reuse storage after its last consumer.
Avoid separate intermediate tensors, host objects or DDR round-trips where direct
binding suffices. Measure the state needed across chunks rather than retaining
whole-utterance activations by default. The front-end conditioning stream supplies
AdaIN coefficients; establish its sufficiency and the remaining edge/source state
against an uninterrupted run. Supplied decoder coefficients are already
[bit-exact with the supplied-moments path](results/decoder-direct-coefficients-sm8550-20261010.md)
and reduced chunk execution from about 13.4 to 2.9 ms. Producing those coefficients
on the phone and extending the modes to the generator remain open.

The generator-template component wrappers, isolated probes and fixed calibration
are temporary integration scaffolding. They do not establish the resident
architecture or a requirement for runtime long-horizon normalization statistics.
The student is intended to supply normalization controls; that producer remains
unverified until measured through the connected generator. First admit the
connected generator's bounded VTCM working set, input/output contract and
whole-sentence PCM, then integrate the dynamic frontend through that boundary.
Replace standalone diagnostic wrappers with the connected fixed loop schedule;
preserve their receipts and reuse only the kernels needed by the connected path.
The connected generator uses the phase lock with reversed increments as its
Snake replacement. Only NaN/Inf automatically stops that run; PCM SNR is
reported without a quality threshold, and listening to the WAV pairs decides
quality. Smoothstep remains an existing parameter value, outside this build's
candidate and gate. Reuse the existing fixed normalization constants unchanged.

Compare progressively smaller and differently placed frame cuts with the same
linguistic controls, style and randomness. Report sample ownership, boundary error,
listening, peak memory and timing. Native STFT/iSTFT overlap-add is retained; no
arbitrary PCM crossfade, duplicated samples or inserted pause is allowed. Exact
tiling error and learned-control approximation error are measured separately.
See the [active frame/control contract](student-generator-contract.md).
The earlier general graph-tiler proposal was deferred and has no current document
or implementation prerequisite.

## VTCM: measured workaround and planning limits

The [capacity probe](results/vtcm-capacity-20261007.md) measured 8 MiB on SM8550 and
4 MiB on SM8635. Admit a schedule only against the actual grant; an 8 MiB result
does not establish fit on SM8635.

The peach sentence initially requested 8,650,752 bytes at 22 convolution batch
tiles and failed resource acquisition (`Stage=2 Done=0`), before execution or
playback. Manually setting `ResidentBatchTiles=14` reduced the request by 524,288
bytes to 8,126,464 bytes, leaving 262,144 bytes below the measured 8 MiB capacity.
The same complete 85-frame utterance then ran and played successfully, with four
HVX workers. Inputs, phrasing and sample count were unchanged.

This reduced internal convolution scratch; it did not split the utterance in time,
bind all intermediate activations, or prove a general memory solution. `Speak`
checks the emitted size against the measured SM8550 capacity. Runtime capacity
query, automatic fallback and arbitrary frame chunking are not implemented.
The older 128-channel u8 generator-stage liveness estimate was for that stage
alone; it is not evidence that the integrated 16-bit job fits 4 MiB.

Any later fallback must reject a failed job before publishing PCM or committing
phase/noise state. A checked static plan that fits is sufficient; do not require
allocation failure and retry as the normal scheduling strategy.

## Earlier research

The October 7 homograph experiments used WikipediaHomographData at
`8f008f021e88f8b71118a27ae655f1f3121162bc`: macro accuracy was 84.1% for most-frequent
choice, 91.5% for neighboring-word decision lists, 91.4% with SMA tree features,
and a provisional 89.2% for misaki with spaCy. These are historical observations,
not the current front-end implementation or a directive to distil misaki.
The [current phonemizer](../phonemizer/README.md) uses Moby and Zira-distilled
choices and has independent phone receipts. The existing prosody/substitution
experiments and their held-out results are indexed in the handoff.

Use admitted teacher evidence for quality improvements; rejected or uncertain
targets cause neither learning updates nor student penalties. Keep training and
untouched holdouts separate. Those improvements follow phone integration.
