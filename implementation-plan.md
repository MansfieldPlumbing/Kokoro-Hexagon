Yes. Sol needs a sequence of evidence gates, a clear critical path, and explicit limits on infrastructure work.

One correction to my earlier advice: I overstated what had been recovered from your prior work. The old receipts identify useful boundaries; they do **not** yet establish that those components can be dropped into today’s decoder. Likewise, the new pipeline only passed parsing. Its sleep-based playback scheduling is provisional and needs replacement before it can support credible gap or first-PCM claims.

Here is the implementation brief for Sol.

# Kokoro-QNN implementation plan

## Objective

Develop the existing working Kokoro decoder into a reproducible, low-latency Hexagon implementation, with a PowerShell Android demonstration APK and Hugging Face artifacts.

Preserve the current successful decoder. Recover prior work selectively through executable gates. Optimize for time to the next verified improvement.

## Established baseline

- Repository: `C:\Dev\Kokoro-QNN`.
- Frozen contexts: `C:\Dev\Build\Kokoro-QNN\known-good`.
- Canonical recorded result: generator 1.3729 seconds warm mean over 20 runs; RTF 0.419; front approximately 14.9 ms; audio SNR 24.06 dB.
- Baseline receipt: `docs/receipts/baseline-fp16-20260922.md`.
- The phone was subsequently left with the slower plain generator. Its latest replay reported 1.5638 seconds warm mean and successful playback.
- SDK, Hexagon compiler 19.0.02, and HexKL have been extracted in WSL. Compiler version was queried successfully; a project kernel has not yet been proven on the phone.
- Local changes include Claude’s baseline documentation and uncommitted prototype phrase/pipeline code. Inspect and preserve them.
- Do not describe proposed capacity buckets, pipeline timing, dynamic narration, or fused kernels as device-proven.

## Operating rules

1. PowerShell owns orchestration, candidate selection, lifetimes, scheduling, measurements, and promotion.
2. Remove Python from repeated inference and benchmark operation as soon as the necessary front-end boundaries are proven. Existing Python export/reference tools may temporarily manufacture artifacts and provide an independent numerical oracle.
3. Every promoted speech path must produce valid PCM and play through the phone speaker. Record playback completion separately from merely calling `Play()`.
4. Benchmark narration must use actual recorded results and run outside timed measurement intervals.
5. Keep generated artifacts outside the repository. Preserve known-good artifacts; compile into unique candidate locations.
6. Follow repository instructions and read the required local skills.
7. No push, publication, irreversible overwrite, or history rewrite without the required confirmation.
8. Each experiment answers one stated question, has a measurable acceptance gate, and ends with a receipt or a precise failure.
9. No framework expansion unless an immediate experiment needs it.

## Prior art: what to use and what must be proved

| Source | Reuse | Admission gate |
|---|---|---|
| Old Kokoro-QNN | Predictor/BiLSTM, duration/cardinality, F0/N probes, graph bindings, solver/replay and phrase geometry | Locate implementation and original inputs; reproduce the receipt on the current runtime; verify compatibility with the current graph |
| ChangeModel | Experience records, representation refinement, constrained proposals, replay and acceptance | Adapt to real Kokoro receipts; verify predictions on held-out cases |
| JS2PS | Explicit, reversible candidate changes; bounded greedy search checked against exhaustive search | Demonstrate on a small real optimization space |
| QuickPS | Native binding and deterministic resource ownership patterns | Verify exact Android ABI, cleanup and execution on device |
| Pwsh | Pinned build inputs, write plan, APK production and persistent runspace host | Prove the Android facilities Kokoro actually requires |
| PSPersistence | Potential persisted control methods | Show an actual startup/control bottleneck and pass the exact Android runtime gate first |

ChangeModel currently contains bounded research proofs, not a ready numerical optimizer. JS2PS is not a general translator. PSPersistence is not yet an Android execution solution. Pwsh’s owned-host UI/audio migration must not block decoder progress.

## Phase 0 — Recover the exact reproducible starting point

Do this before further feature work.

- Read current instructions and inspect the working diff.
- Compute and compare the known-good context hashes against `known-good.json`.
- Locate the baseline phrase inputs, oracle, context metadata, and benchmark-enabled runner. The manifest inspected previously listed only three context binaries; input preservation has not been verified.
- Recover the original export environment and exact commands from the supplied scratchpad location. Use targeted searches.
- Compare the phone’s benchmark runner with the repository copy; preserve the benchmark capability that exists only on the phone or scratchpad.
- Restore the canonical native-norm candidate using its actual tensor metadata.
- Replay correctness, repeated timing, and speaker playback.
- Record the complete reproduction command and artifact identities.

Exit: another session can reproduce the canonical baseline without reconstructing missing commands or guessing paths.

## Phase 1 — Make the current runner reusable and measurements honest

Implement a small reusable PowerShell session around existing QNN modules:

- Load a context and bind reusable buffers.
- Validate tensor names, shapes, types and byte lengths.
- Execute repeatedly without reopening the app or reloading contexts.
- Release buffers, contexts, performance resources and audio resources deterministically.
- Reject failed native calls.
- Save a structured receipt with hashes and measurement scope.

Timing fields must distinguish:

- App/context initialization.
- Prepared-input-to-PCM latency.
- Text-to-PCM latency, once a live front end exists.
- PCM submission.
- Playback timestamp/completion.
- Timed graph execution.
- Validation and narration overhead.

Review the prototype `Pipeline.ps1` and `Invoke-Pipeline.ps1` before using them. Replace wall-clock sleeps as the authority for playback completion. Validate audio-write results, quality before playback, cleanup, staging failures, and context compatibility. Predicted headroom is not a measured underrun or audible gap.

Exit: the existing 160-frame candidate runs repeatedly through this session and matches its baseline within declared measurement variation.

## Phase 2 — Prove capacity buckets and phrase overlap

First experiment: does a smaller capacity improve prepared-input-to-first-audio latency without unacceptable quality loss?

- Start with one short phrase and one longer phrase.
- Measure their true predicted frame counts before choosing capacities.
- Export/compile 64 and 96 only when the phrase fits; do not truncate or invent logical lengths.
- Preserve sentinel slots and distinguish token count, physical capacity, valid frames and valid samples.
- Verify every transformation against its predecessor.
- Compare each bucket with the full-length reference and the established masked design.
- Check native InstanceNorm behavior for low occupancy; do not assume the baseline quality holds for much shorter phrases.
- Measure load time and memory before deciding which contexts stay resident.

Then implement synthesis/playback overlap:

1. Synthesize and validate the first phrase.
2. Submit its PCM.
3. Synthesize the next phrase while Android plays the first.
4. Queue audio using an observed playback state or supported completion mechanism.
5. Measure completion, underruns and boundary quality.

A continuous audio queue is preferable if supported by the existing host. Avoid replacing one playing static track based on estimated duration.

Exit: two different phrases play in order, with a receipt that proves overlap and correctly labels timing boundaries.

## Phase 3 — Remove Python from repeated speech generation

The decoder alone cannot synthesize arbitrary benchmark narration. Recover the missing front end in dependency order.

- Inventory the old graph boundaries and their actual inputs/outputs.
- Determine which upstream stages are still missing; a proven BiLSTM does not establish a complete text encoder or prosody pipeline.
- Replay the most useful proven boundary on the current runtime.
- Connect it to the present decoder only after tensor layout and semantic-length parity pass.
- Advance through text encoding, duration/alignment, F0/N and harmonic source/STFT.
- Use PowerShell to own planning and native/HTP kernels for bulk arithmetic.
- Preserve an independent reference while replacing each stage.

For G2P, the old Misaki corpus demonstrates lexical coverage, not a finished PowerShell implementation. First implement the bounded vocabulary needed for truthful benchmark narration, with verified number expansion and pronunciation. Expand to general text separately.

Exit: a fresh benchmark result becomes text, then Kokoro PCM, and is spoken on the S23 without Python participating in that repeated workflow.

## Phase 4 — Prove one useful fused kernel

Run this once the baseline harness can reliably compare candidates.

- Pin SDK/compiler/HexKL identities.
- Use a minimal compiler smoke test only if needed.
- Extract representative input/output fixtures from an expensive real decoder block.
- First kernel: the required reduction and activation/table operation on real tensor geometry.
- Compare against the reference on the S23.
- Establish whether it can integrate through a QNN custom op or FastRPC.
- Compare integration routes where feasible, including copies, synchronization, context transitions, memory and VTCM contention.
- Begin with the least numerically disruptive implementation that tests the bottleneck.
- Add table interpolation and integer representations incrementally.
- Fuse one block before expanding across the generator.

The stats, lookup, convolution and quantization design remains a hypothesis until its individual numerical and performance gates pass.

Exit: one block gives a repeatable inclusive speedup while meeting quality constraints on held-out inputs. If it does not, keep the QNN implementation and record why.

## Phase 5 — Automate the hill climb using prior art

Start with a small PowerShell candidate record and receipt cache. Do not build a general optimizer first.

Candidate identity includes:

- Parent graph and source hashes.
- Transformation sequence and parameters.
- Compiler/runtime identities.
- Target hardware.
- Calibration and evaluation corpus versions.
- Relevant execution settings.

Use the old solver/replay implementation where it actually reduces work.

Evaluation order:

1. Static admission.
2. Reference equivalence or declared approximation test.
3. Quality screening.
4. Compilation.
5. Device block measurement.
6. Whole-phrase validation.
7. Promotion suite and speaker playback.

Reuse artifacts for identical candidates. Reuse historical timing only with its measurement conditions; hardware timing requires fresh confirmation before promotion.

Adapt ChangeModel to identify missing explanatory features when outcomes conflict. Keep compile failures, quality failures and timing noise distinct. Use bounded JS2PS-style search for the first handful of knobs, then test limited joint moves if one-at-a-time search stalls.

Correctness and quality are hard constraints. Keep latency, memory and energy as explicit tradeoffs rather than hiding them in an arbitrary weighted score.

Exit: one automated search produces a reproducible winner using fewer expensive evaluations than its bounded exhaustive comparison.

## Phase 6 — Demonstration APK and model zoo

Use the proven Android host for the first demonstration. Migrate to the owned Pwsh host when the exact required Android APIs pass their gates.

APK:

- Text entry and voice selection.
- Speak, cancel and replay.
- Hardware and artifact identification.
- Clear stage placement.
- Correctly scoped latency/RTF display.
- Benchmark execution and spoken result.
- Receipt export.

Release artifacts:

- Reproduction instructions and pinned source.
- Supported-device/runtime matrix.
- Model/context manifests and hashes.
- Representative audio comparisons.
- Benchmark corpus and raw receipts.
- Dependency and licensing records.
- Hugging Face artifact layout aligned with actual tested configurations.

Resolve redistribution rights for each artifact, including compiled contexts and runtime dependencies, before publication. Publish only measured compatibility.

## How to prevent drift

At the start of each work session, state:

- Current gate.
- One question being answered.
- Existing evidence being reused.
- Expected artifact or receipt.

At the end, record:

- What changed.
- What ran and what passed.
- What remains unproven.
- The exact next command or blocking dependency.

Keep one canonical status document. Do not substitute strategy prose for implementation or call parser success a device result.

The immediate assignment is Phase 0 followed by Phase 1. Complete those before expanding the prototype pipeline or creating another subsystem.