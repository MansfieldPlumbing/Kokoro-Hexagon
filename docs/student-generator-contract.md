# Student-driven phase generator contract

Settled architecture, reaffirmed 2026-10-15. This document owns the active
runtime contract. Project instructions, handoffs, prompts and skills route here.
Stock Kokoro is the frozen offline teacher and numerical comparison; its name,
equations and historical porting milestones do not prescribe this runtime.

## Eliminate work on one clock

The Student and generator share one 300-sample tick: 80 frames per second at
24 kHz. Internal 10x and 60x cycle positions give the phase operations stable
positions on that timeline. Transport batching does not change this clock.
Carry state across arbitrary block boundaries; program order is the schedule.

Snake is a hardware phase primitive in this execution model. Reuse the existing
Lock/bounce path: phase displacement relative to an operating point, reflection
at the turning points, clamp, and a bounded height/slope multiply-add correction.
The Student conducts the phase drive on the frame clock. Do not reintroduce
per-activation sine, a trig lookup, smoothstep, or a second Snake implementation.
This is an architectural elimination of repeated nonlinear work, not a request
to optimize a conventional Snake operator.

AdaIN scale/bias arrive from the front end on the same timeline. The generator
applies the supplied affine through the existing hardware path. Do not add
runtime instance-statistic reductions, style-projection networks or normalization
refinement to recover stock behavior. Existing fixed corpus constants are
unchanged CONST scaffolding; input-dependent controls are not resident tables.

Each typed frame binds the complete 512-channel generator input, F0/voicing,
duration/alignment, voice identity, AdaIN controls and phase/control state.
The Student produces their numbers together through reusable deterministic
programs. Store how to produce the values, not recordings of feature frames,
per-utterance lock tables or separate raw control tracks. Global strokes may
transform all 512 channels at once. No runtime text encoder, predictor network
or per-unit acoustic-vector lookup bank. The decoder is optional: the
architecture runs with or without it, ahead of the frozen generator. The front
end is a custom phonemizer that runs on CoreCLR. Compute the source branch; do not store
or stream its pre-rendered tiles as the product.

Use Invoke-KokoroDevelopment.ps1 Student and the owning Student modules.
StudentV2 is deprecated. Differing StudentV3 cadence and file-layout plans are
superseded; reader, ETS percept and closure ideas remain future reference.

Only weights and demonstrated genuinely per-voice constants are eligible for
instantiation-time residency. Permanent VTCM residency is the goal, not a result
established by this document. Precision variants require their own evidence;
old integer-only porting rules cannot prohibit the agreed FP16 reference path.

## Phase state and evidence boundaries

The earlier fixed-seat-bias plus channel/frame-lock decomposition did not preserve
the matched per-seat PCM. Its receipt directs work to the Student driving phased
signals. Do not turn that descriptive fit into a production preload or repeat
the failed split as an integration prerequisite. Rebinding from frame sums and
advancing the tangent by rotation are recorded implementation directions, not
proof of table-free execution or exact arbitrary-text joins. The full state
transition and boundary behavior still require implementation and measurement.

The existing Lock reference/epilogue is reusable evidence. Historical trig/table
producers and stock AdaIN are offline comparison machinery only; their existence
does not authorize new runtime implementations or make them prerequisites for
the Student path. Preserve captures, manifests, frozen weights and receipts.

The shared-stroke experiment's coefficients selected with access to true held-out
vectors establish representation evidence only. They do not prove a Student
policy, generalization or storage economics. Report representation,
reference-free generation and economics separately, and preserve failed
numerical results.

## Held-out dB ratchet

The Student is measured by what it emits, not by the IDs it reads. From typed
context alone, never from the target, it emits the continuous per-frame values
listed above. The instrument executes them and the output is compared with the
teacher in dB at the point where the values are consumed. A change is kept only
if held-out dB does not drop. A separate untouched test split gives the final
score. 40 dB on held-out text is the absolute floor; below it a result is a
failure. The Student must ratchet to at least 70 dB held-out; the target range
is 70–90 dB.

Current bracket on nine held-out selections
([replay](results/student-replay-nine-offline-20261015.md)): 10.7–16.6 dB PCM16
from copied units alone, 54.4–63.5 dB when programs are climbed against each
known target. The work is the mapping from typed context to emitted values that
closes that gap without the target.

## Agent routing and defaults

Before proposing work, identify the actual frame consumer, supplied controls,
state and current task. Model-family familiarity is not a requirement. Do not
infer runtime architecture from the repository name, stock papers, a general
audio skill, an old handoff or a reference API that still computes AdaIN/Snake.
Do not ask which architecture to use when this contract already answers it.
An incomplete input bridge calls for connecting the agreed controls, not
reintroducing the operations being eliminated. Do not rename the repository or
alter the frozen weights to solve an instruction-routing problem.

Compare reference and candidate with matching F0, voice, source draws and other
controls; label differences explicitly. Failed hypotheses remain results. Use the owning entrypoint, PowerShell and admitted compiled
kernels; no Python or new JSON. Respect current worktree, publication and scope
authorization; the architecture does not authorize unrelated residency work.
Respect the current task's stop conditions and Verify before commits.

Sources: [Lock/bounce implementation](../tools/Kokoro.GeneratorLock.psm1),
[emitted epilogue](../src/kernels/Kokoro.GeneratorEpilogue.ps1),
[phase-split measurement](results/generator-phase-split-offline-20261015.md),
[shared-stroke measurements](results/student-shared-strokes-20261015.md).