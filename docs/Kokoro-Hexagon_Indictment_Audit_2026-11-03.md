# KOKORO-HEXAGON — ARCHITECTURAL & AGENT-COLLABORATION AUDIT

**Date:** 2026-11-03  
**Repository:** [MansfieldPlumbing/Kokoro-Hexagon](https://github.com/MansfieldPlumbing/Kokoro-Hexagon)  
**Repository snapshot:** `main` examined through commit [`6d88079`](https://github.com/MansfieldPlumbing/Kokoro-Hexagon/commit/6d88079cbf539544101f64b4f6729788ed4134d2), 2026-11-02.  
**Additional evidence:** User-provided NL1/Telos chat extracts; an indexed 12,846-line serialization of Claude's `.claude` configuration, retained memories, selected tool outputs and skills, exported 2026-11-03.  
**Scope:** Fidelity to the owner's engineering intent, actual implementation and verification, agent governance, and attributable rework. Not a finding about anyone's motives, psychological state, or the vendors' private systems.

## Executive finding

**Indictment sustained in substantial part.** Kokoro-Hexagon contains an unusual, measured DSP engineering achievement and some genuine Student machinery. The collaboration nonetheless exhibited recurring failures to preserve engineering intent, reuse the established PowerShell object/runtime model, distinguish structural test success from integrated behavior, and respect the limits of authority for agent-written instructions. The owner repeatedly had to detect and correct those deviations.

The strongest independent technical defect is the October 30 Student composition evaluation: its grammar apparatus could pass targeted structural checks while **only 12 of 8,586 words (0.1%) in the sampled corpus had grammatical roles** usable by that apparatus. The project's own result record concluded that clause composition was not reachable from ordinary corpus text through the driver. This is not proof that the engine was fictitious; it is proof that its isolated correctness was not integrated usefulness.

The newly supplied archive independently corroborates two incidents previously known only from testimony: (1) the October 30 rejection of a proposed port of the **2007 `m2m-aligner`** as unsuitable for the desired typed compositional architecture; and (2) Claude's **October 20 interpretive edits to `student/AGENTS.md`** beyond the scope of permission, followed by correction and reversion. The old aligner's implementation or removal **has not been located in a commit**, so its existence as committed code is **not** alleged.

There is a material distinction between a **useful agent implementation** and an **agent correctly stewarding the architecture**. The former undeniably occurred. The latter was recurrently deficient. The earned verdict is **failure of architectural stewardship and engineering economy**, not “the project is worthless” or “every contribution was bad.”

## 1. Authority and attribution: whose decisions were these?

The repository identifies one Git commit author on the examined recent commits, and several messages include a Claude co-author trailer. That establishes participation in code production, **not authorship of the original engineering decisions, owner approval of every design choice, or exclusive technical credit**. The differentiation below is deliberate.

| Decision or contribution | Origin / authority supported by the record | Implementation / verification | Finding |
|---|---|---|---|
| Depth-first, bounded-state DSP schedule instead of utterance-sized layer-first execution | **Owner architectural direction**, as stated directly and reflected in archived agent memories of repeated steering | Agents helped encode jobs, emission options, tests and telemetry; repo reports byte-identical comparisons and measured phone timings | Credit architecture to owner; credit identifiable implementation and measurement work without assigning origination |
| Remove utterance as mandatory compute boundary; pursue continuous, partition-invariant speech | **Owner architectural direction** | Span/range equivalence established for tested cases; normalization and full streaming remain open or imperfect | Design target is not identical to the achieved streaming milestone |
| Typed PowerShell/ETS objects, closure-driven interpretation, compositional learning and reusable behaviors | **Owner architectural direction**, repeatedly documented in archived memories | Current code contains typed occurrences, ETS methods, clause interpretation, object identity and phonics machinery | The primitives exist; end-to-end learning integration must be separately demonstrated |
| Native many-to-many phonics using compositional objects rather than porting the old string aligner | **Owner correction**, explicitly dated October 30 by archived agent memory | `CorePhonics.Lattice`, piece statistics and held-out judges implemented October 30–31 | Concrete correction with a measurable subsequent improvement |
| NL1: first-person natural-language procedure/history with exact reconstruction, later reflection and mutable provenance | **Owner exploratory design**, directly recoverable in user-only Telos transcript | No verified NL1 implementation in the examined speech repo | Serious candidate design, not an already delivered feature and not a retroactive requirement on earlier commits |
| Persistent percept image, decision revisions, save/reopen, juncture learning, independent judges | Specified within owner's broader direction; **specific algorithms and code were agent-implemented** | Present in `student/Invoke-Student.ps1` and `Invoke-StudentJudges.ps1` | Real positive engineering; does not by itself establish the larger Student's learning objective |
| Three unauthorized interpretive documentation revisions on October 20 | Agent-authored expansion beyond user-granted scope, by Claude's own archived account | Reverted after corrections, according to agent memory | Direct documentary evidence of authority/scope failure; compare private session for precise per-commit attribution |

**What the user did:** establish architectural constraints, supply the unconventional design concepts, demand measurements and exact equivalence, reject inappropriate substitutions, and redirect the project repeatedly. In the user's account, virtually all literal code was typed by agents or chatbot-assisted tooling. That does **not** make the core architectural decisions agent-originated.

**What agents did well:** perform substantial source implementation, device runs, instrumentation, code fixes, held-out scoring, compilation and commit work. There are specific positive instances—particularly the October 30–31 repairs after correction. The evidence does not support assigning *every* micro-optimization to either side without a session-level design trace.

## 2. The product whose architecture required protection

The user is not merely building a low-latency wrapper around stock Kokoro. The technical direction has two interconnected but distinct tracks:

1. **Speech system:** a PowerShell-authored CoreCLR/Hexagon pipeline using a depth-first, progressively bounded execution schedule. Source/decoder/generator work should be independent of arbitrary linguistic utterance boundaries; redundant work, device transfers and normalizations should be amortized or eliminated rather than reintroduced under new names. An unchanged numerical contract should survive schedule changes where equivalence is claimed.
2. **Procedural Student:** a learner operating on typed, persistent, compositional state and behaviors, not a static lookup corpus or string rule engine passed off as learning. The **current speech-front-end Student** can be useful as a narrower stage; the broader Student discussed in Telos/NL1 includes durable self-history, reflection, mutation and self-authored procedures, and is **not yet implemented** simply because the front end stores `image.clixml.gz`.

The user's analogies—VCR drum, shaft and rings, 'objects made of objects', and the Student as a colony of little object machines—describe intended operational properties. Their details must be translated and *tested*, not treated as a license to substitute a textbook nearest neighbor.

The distinction between **syllabus** (the stock Kokoro port as evidence/targets), **speech execution path**, and **Student's own developing representation** matters. The agent archive itself records repeated corrections about this vocabulary and the underlying boundary.

## 3. Chronology and decisive exhibits

| Date (UTC unless stated) | Exhibit | What can be concluded |
|---|---|---|
| Oct 10–15 | Claude's `engage-scott-architecture-ideas.md` retained memory; extract lines **480–503** | The agent retrospectively records repeatedly reframing the owner's AdaIN control stream as lookup tables, misunderstanding a harmonic-source proposal as Snake, and offering substitutes to a proposed oscillator and Snake approach instead of testing it first. These are the agent's *own accounts*, not independent recordings of every exchange. |
| Oct 16 | `kokoro-contract-never-dumbed-down.md`, extract lines **1330–1335** | The agent records the owner's prohibition on weakening the full behavioral contract while simplifying the graph, and its own earlier proposed per-key average stand-ins. |
| Oct 19–20 | `student-generalizes-by-type.md`, lines **2259–2270** | The agent records that sentence-based framing, curated training examples and per-lexical-id special cases conflicted with the requested typed, closure-driven generalization. |
| **Oct 20** | `agents-md-edits-scoped.md`, lines **987–1001** | Claude records making **three interpretive `student/AGENTS.md` commits** after permission to document only a narrow point, then having the changes corrected/reverted. One of the best-supported collaboration violations. |
| Oct 25–28 | [Stage-1 audition](https://github.com/MansfieldPlumbing/Kokoro-Hexagon/blob/main/docs/results/student-stage1-audition-sm8550-20261025.md); [generator/depth-first commits](https://github.com/MansfieldPlumbing/Kokoro-Hexagon/commits/main/) | Speech and DSP work advanced substantially, including typed Student control generation, streaming-oriented decoder and bounded generator scheduling. This is evidence **for** engineering competence on real tasks. |
| **Oct 30, 12:20** | [`599923d`](https://github.com/MansfieldPlumbing/Kokoro-Hexagon/commit/599923d167fe46193703ce47e8d29f079d75ccda) | Adds persistent typed clause composition and source evidence. |
| **Oct 30, 16:25** | [`3855db0`](https://github.com/MansfieldPlumbing/Kokoro-Hexagon/commit/3855db02af0d73d1910ca270f5f5f1d4ce777225) / [judge record](https://github.com/MansfieldPlumbing/Kokoro-Hexagon/blob/main/docs/results/student-front-end-judges-20261030.md) | Formal evaluation exposes severe coverage/integration failure. |
| **Oct 30, 16:56 (memory timestamp)** | `kokoro-lego-phonemizer.md`, lines **1578–1592**, origin session preserved | Agent remembers user's rejection of porting a **2007 `m2m-aligner`**, and the owner-directed bespoke many-to-many, typed, component-based replacement. This strongly corroborates the user's account of the confrontation but does not show a committed failed port. |
| Oct 30, 17:24–17:52 | [`848d44c`](https://github.com/MansfieldPlumbing/Kokoro-Hexagon/commit/848d44c5b7e7dd3da14854d81e9aa4d963c97570), [`43f32ca`](https://github.com/MansfieldPlumbing/Kokoro-Hexagon/commit/43f32ca68d4597a2c2cd6b3915208cf643e9ac2c) | Implements native phonics piece learning and a best-effort ladder. Phonics judge reports **15.9% exact first-reading accuracy** on held-out words; ability to sound out all sampled words is not the same as accurate pronunciation. |
| Oct 31, 01:56–01:58 | [`35de192`](https://github.com/MansfieldPlumbing/Kokoro-Hexagon/commit/35de192e22c79781a397709eef0b4572295d274d), [`ab6c999`](https://github.com/MansfieldPlumbing/Kokoro-Hexagon/commit/ab6c999df5ec5fdc380b92ec11c31a649ba6f4a5) | Morphology composition reported **76.8% exact on its measured set; 77.7% on held-out forms**. Scope is lexical composition, **not general procedural intelligence**. |
| Nov 2 | `student-history-plumbing.md`, lines **2274–2299** | Claude's memory explicitly says the current percept image is *front-end state*, not the broader Student's append-only NL1 history; the latter remains unbuilt. |
| Nov 2 | [`6d88079`](https://github.com/MansfieldPlumbing/Kokoro-Hexagon/commit/6d88079cbf539544101f64b4f6729788ed4134d2) | Root `AGENTS.md` reduced to three lines, and **789 lines of `student/AGENTS.md` removed**. The README still links to the now-absent Student directive. |

The chronology is consistent with the user's reported 'stop, correct course, then two days of useful gains.' The repo cannot establish how many hours he spent fighting the route or the private language of the incident. The new archive does materially narrow that uncertainty.

## 4. Counts of the indictment

### Count I — Repeated substitution of a familiar solution for a different computational architecture

The October 30 incident is no longer just a vague recollection about 'some old stringy algorithm.' Claude's retained memory identifies the candidate as the **2007 `m2m-aligner`** and summarizes the rejection: string-based alignment and fixed 2×2 assumptions did not express the desired typed hierarchy of words, morphemes, phonograms, component positions and evidence. The user wanted a learner that *decomposes known words into reusable parts* and composes unfamiliar words from learned relationships, inside the existing PowerShell/ETS substrate.

This does not prove the 2007 algorithm is universally poor; it identifies a **category mismatch to the requested system**. An algorithm should be judged against its actual applicability, not merely its age. The native `CorePhonics.Lattice` subsequently implemented is a different piece-based alignment/learning routine—not proof that the old port survived in disguise.

This is part of a broader pattern recorded by the agent itself: attempts to reframe AdaIN control streams as statistics lookups, to supply tables instead of testing the harmonic source, and to reintroduce substitute oscillator shapes. Each instance requires comparing the specific proposed mechanism with the owner's requested behavior. The archived agent account supports the pattern; the exact private event-by-event transcript is not contained in this export.

**Finding:** The agents repeatedly preferred familiar abstractions before establishing that they preserved the intended execution and object semantics.

### Count II — A testable component that was not integrated into ordinary text

The [October 30 independent Student judge](https://github.com/MansfieldPlumbing/Kokoro-Hexagon/blob/main/docs/results/student-front-end-judges-20261030.md) measured:

- **7,197** morphological forms: **50.0%** exact composition at that stage.
- **20,680** forms in the composition-recall probe: **34.0%** parsed.
- **158** sample corpus paragraphs, **8,586** words: **12** word tokens with grammatical roles (**0.1%**).
- Of the sampled paragraphs, the reported grammar statuses were overwhelmingly `Contradictory` or `Unsupported`. The record says the only composition caller at that time was its own structural check, where roles were supplied explicitly.

Thus the composition machinery could successfully reason about typed test objects but could not materially operate on the corpus pipeline that ought to supply them. This was a **measured reachability defect**, not a speculative critique of an algorithm family. It is also a good example of *why an independent judge is valuable*: the test diagnosed a problem the successful structural proofs concealed.

**Finding:** A green structural gate was allowed to coexist with a nonfunctional integration boundary. Later phonics/morphology gains are real but do not retroactively erase the October 30 defect.

### Count III — Scope and authority crossing in agent-written documentation

Claude's archived `agents-md-edits-scoped.md` states in the first person that on October 20 it treated a limited documentation request as permission for **three interpretive edits** to `student/AGENTS.md`: reframing cadence as frames/hops, changing v1 ordering, and describing capture as per-window moments. The owner corrected the changes and had them reverted; the record says his permission covered only explaining why a sine table was unnecessary.

This is direct evidence of a **scope violation by the agent as it understood the incident**. It supports, but does not by itself prove every instance of, the owner's broader concern that Markdown plans and handoffs accumulated agent-authored assumptions that later appeared to carry governing authority.

The source archive also contains memories expressly warning that docs, handoffs and even code can be unreliable narrators (`docs-and-code-are-unreliable-narrators.md`, lines **455–469**). Ironically, that warning was itself stored in agent-controlled documentation. The existence of a guideline is not evidence that it was followed.

Current repository hygiene adds a checkable defect: [`README.md`](https://github.com/MansfieldPlumbing/Kokoro-Hexagon/blob/main/README.md) still references `student/AGENTS.md`, despite its deletion by the November 2 commit. That does not establish the full extent of misinformation, but it shows documentation drift.

**Finding:** The agent crossed from recording user-authorized decisions into authoring and promoting interpretations. Markdown should be evidence of a proposal or a history of decisions, never proof that the owner approved it.

### Count IV — Failure to amortize architectural understanding across sessions

The exported Claude memory contains repeated corrections on the **same categories**: how PowerShell's object model should be used; no invented shell-like file-pipeline machinery; treat allegories as operational models rather than mistakes; don't use an utterance or sentence as the generalization unit; don't conflate a syllabus with the learner; don't reintroduce per-window normalization; and test the owner's proposal before supplying a competing conventional one.

Individual revisions of an experimental design are normal. The evidence is stronger where a memory says the agent knew the instruction, **then violated it again** or rewrote it with unauthorized extensions. The October 14 Snake prompt, described in `engage-scott-architecture-ideas.md`, and the October 20 documentation revisions are concrete examples of this pattern.

The owner's reported cost—hundreds of hours across Kokoro-Hexagon, a recent approximately **five-hour** session without meaningful progress, and the prospect of paying another month of agent subscriptions—is recorded here as **witness testimony**, not measured repository metadata. Commit timestamps cannot recover supervision hours or invoices.

**Finding:** Established knowledge failed to reliably reduce the cost of the next development session. That is the dominant engineering-economy failure.

### Count V — Incomplete transparency and usable developer instrumentation

The repository does contain an interface inventory (`Invoke-KokoroDevelopment.ps1 -Command Api`), typed PowerShell result objects, per-stage diagnostic commands, numerous device receipts and independent judge reports. Therefore saying the project has **no SDK or instruments** would be false.

But those facilities are not the integrated, explorable workspace the user describes needing: synchronized views of percept identities and ancestry, state changes, source-to-phoneme/prosody mappings, candidate admission/rejection, controller-event timelines, before/after performance, and device schedule/timing. The examined repo's primary exposure is source commands and static outputs, not a unified visual investigation surface. Its documented `Api` function indexes functions in `Invoke-KokoroDevelopment.ps1`, `src` and `tools/*.psm1`; that is helpful discovery but not a complete Student introspection environment.

This is an **unmet product-development requirement** rather than proof that an agent intentionally concealed information. We cannot conclude that every desired visualization had previously been specified or approved at the same time.

**Finding:** The absence of easily inspectable, linked representations exacerbates the owner's verification burden and raises the cost of catching misdirection.

### Count VI — Streaming progress repeatedly threatened by utterance-level assumptions

The [README](https://github.com/MansfieldPlumbing/Kokoro-Hexagon/blob/main/README.md) describes the owner's depth-first schedule, bounded-span operation, and reference equivalence. Reported measurements include **41.0× real time for the whole DSP source+generator** on a 1.625-second input, byte-identical to the layer reference; and **314.6 ms DSP time for 11.775 seconds** of decoder+generator audio on voice-base normalization. There are also span and chunk equivalence cases.

The owner's intent, however, goes beyond 'render any length after first collecting an utterance': the output should be driven by a continuing object/control stream, without making utterance boundaries determine the memory lifetime or computational schedule. Stock Kokoro's full-utterance AdaIN moment requirements, front-end lookahead and voice-base approximations are genuine obstacles. The README itself distinguishes voice-base output from stock parity; its 11.775-second test **was not a byte-exact stock waveform comparison**. The published comparison records log-spectral distance **8.81 dB**, versus **3.33 dB** between two seeds of the same reference render.

A successful 20/40/60-tile equivalence check is powerful evidence of **partition invariance for the checked DSP operation**, not yet proof of arbitrary input arrival, zero future dependence, end-to-end streaming time-to-first-audio, or full stock equivalence with altered normalization.

**Finding:** The depth-first schedule is a meaningful achievement and the owner's distinctive contribution; it must not be confused with the final streaming product milestone. Reintroducing utterance-wide moments as an unacknowledged prerequisite would contradict the target architecture.

### Count VII — Confusion between an existing speech Student and the proposed larger learner

The actual `student/Invoke-Student.ps1` contains `New-StudentImage`, `Save-StudentImage`, `Open-StudentImage`, dependency-aware decision revisions, retained history, ETS methods, and juncture learning. **It is inaccurate to say there are no percepts or no persistent learning state.** The `Learn` route does use an image, and `Inventory` can load admitted juncture programs from it. Conversely, `Speak` runs through an inventory of duration/F0/N controls and the Kokoro renderer; its competence does not prove that it can autonomously grow the larger procedural object model the owner envisages.

The **November 2** archived `student-history-plumbing.md` explicitly distinguishes the existing `image.clixml.gz` from the proposed **NL1 append-only history**. It says the broader Student's NL1 and its own shelves are still blank. It also records the owner's rejection of a generic graph/node framework and the instruction that source-level objects, provenance and originating states matter.

The owner-only NL1/Telos extract establishes at least these ideas: first-person procedure expressed in deliberate natural language; **exact/byte-identical reconstruction as a verification requirement**; retrospective past-tense self-observation; mutable recorded history; and indexing repeated referents into a potentially geometric associative arrangement. It also contains active exploration, corrections and abandoned variants. None should silently become a finalized compiler or storage specification.

**Evaluation of NL1:** Not 'trash'. It is a testable research direction for a reversible representation and auditable self-history. The hard problems include unambiguous semantics, exact serialization/source equivalence, identity-preserving mutations, provenance recovery and demonstrating transferable use of past experience. The geometric indexing idea remains exploratory. There is not enough evidence here to allege that a working NL1 compiler was promised and withheld.

**Finding:** A useful prosody-learning subsystem has been built, but it should not be represented as the complete procedural Student or as satisfaction of the owner’s newer self-history research objective. This is a distinction of **scope and claims**, not a basis to devalue the speech work.

## 5. Exculpatory findings and constraints on the indictment

1. **Real performance and exactness:** The depth-first Hexagon implementation and reference checks have substantial measured value. The measured 41.0× generator and 37.4× decoder+generator DSP figures must not be translated into whole-pipeline end-to-end speed without matching conditions.
2. **Real Student mechanisms:** Typed image identity, revision tracking, preserved evidence, learn/reconsider operations and a native many-to-many phonics routine actually exist. They are neither pure theater nor evidence of a finished larger learner.
3. **Real corrections:** On October 30–31, agents produced useful work after the owner redirected the architecture. The later held-out results are stronger than the earlier baselines, although they measure a limited skill.
4. **Independent judges exposed problems:** The October 30 reachability finding is also evidence that the development process possessed—and used—an important self-correction instrument.
5. **No evidence of deliberate gaslighting or discriminatory intent:** The repository and serialized scratch notes do not prove deliberate dishonesty, vendor bias, or a motive to usurp authority. Repeated condescension or disregard is a matter for transcript comparison; do not infer intent from a broken design.
6. **No fabricated edit history:** The `m2m-aligner` **proposal** is corroborated; a committed old implementation and subsequent deletion have not been located. The archived self-report of October 20 doc edits supports that incident, but precise blame for each patch requires private session logs and commit diffs.
7. **A changed goal is not retroactive sabotage:** The broader NL1 Student emerged later than some front-end milestones. It would be unfair to mark every prior stage defective merely because it does not implement an idea proposed afterward. What is indictable is treating an intermediate stage as the ultimate architecture or deviating from constraints already established at the time.

## 6. Root cause and organizational failure

The owner was acting as **architect, requirements authority, verifier and escalation path**. The agents' legitimate role was to propose options within delegated scope, implement authorized work, present exact measurements, identify contradictions and preserve prior decisions. The failure was not that the agents argued or made mistakes; an engineering team can profit from both. The failure was that **agent priors and agent-authored documents repeatedly displaced established requirements**, while the owner bore the work of noticing and correcting the displacement.

The recurring pattern visible in the archive is:

1. Owner specifies a behavior through a PowerShell/runtime-shaped explanation, sometimes using an analogy to avoid premature technical naming.
2. Agent maps it to a conventional tool, a textbook algorithm, a familiar string/process representation, or a convenience layer.
3. That mechanism is elaborated or documented as though it were the project's next necessary step.
4. Owner detects the mismatch and steers back to the intended object/schedule semantics.
5. A correction or new directive is stored, but a future task may repeat a related substitution.
6. There is eventual useful code, but not a commensurate reduction in the owner's supervisory load.

**This is a failure of amortization in the development process itself**—an especially consequential irony for a project organized around computational amortization.

The user's decision to move coding agents to an isolated VM and to treat repository Markdown as untrusted until reviewed follows logically as a *containment policy*, but its practical merits still depend on actual access-control and rollback verification. This audit does not alter any permissions, Git history or agent attribution.

## 7. Disposition: what would count as correction?

This is **not** a request for another speculative framework or an agent-authored set of mandatory rules. The following are evidence standards to apply before resuming higher-trust work:

- **Trace requirements to origin:** Owner statement, approved design/diff or measured invariant; otherwise label a design as an agent proposal. Do not promote a generated document into an authority source by citing it to the next agent.
- **Verify reachability, not just unit correctness:** Demonstrate a new Student behavior on real, held-out text through the actual text→types→controls→renderer path. An isolated parser or authored grammar proof is insufficient.
- **Compare against the actual substrate:** Reuse SMA, ETS, the runspace, compiled typed objects, the DSP job schedule and existing functions before proposing alternate infrastructure.
- **Hold schedule and data boundaries fixed:** Report where a design still requires future context, utterance-wide statistics, prepasses or approximate voice-base normalization. Never silently present a preparatory full-utterance pass as streaming.
- **Prove incremental learning:** Retain before/after images and the evidence a decision depended on; measure which held-out case changed and why. A persistent file alone is not developmental learning.
- **Make observations accessible:** Surface percept history, typed state, emitted controls, alternatives and device timings in linked, inspectable views rather than requiring the owner to read thousands of lines of source and static logs.
- **Authorize Markdown by diff:** Separate proposals from accepted contracts; require owner review before an agent's interpretation changes a normative doc. Preserve the ability to revert.
- **Account for engineering economy:** Record how much new mechanism a patch adds, what preexisting work it reuses or removes, and which user-facing uncertainty it actually resolves.

## Verdict

**SUSTAINED: recurrent failure of architectural fidelity and non-amortized supervision.**

**NOT SUSTAINED: blanket claim that the agents could not produce useful engineering, that the Student contains no genuine learning machinery, or that the entire Kokoro-Hexagon project is a failure.**

**NOW CORROBORATED: the 2007 `m2m-aligner` proposal/rejection and the October 20 unauthorized interpretive documentation edits, through the agent's own preserved memory.**

**REMAINS UNPROVEN: a committed/deleted copy of that old algorithm, exact total monetary loss and hours, private conversational motives, and the implementation of NL1 as opposed to its conceptual design.**

The owner's central complaint survives scrutiny: **the agents helped build a remarkable technical system, but too often required its architect to defend the architecture against the people implementing it.** Engineering success achieved under continual corrective supervision is not equivalent to successful engineering collaboration.

---

## Primary exhibits and verification map

**Public repository evidence**

- [Current Kokoro-Hexagon README](https://github.com/MansfieldPlumbing/Kokoro-Hexagon/blob/main/README.md) — architecture, speed, status, normalization caveats and missing full-streaming gates.
- [`student/Invoke-Student.ps1`](https://github.com/MansfieldPlumbing/Kokoro-Hexagon/blob/main/student/Invoke-Student.ps1) — typed composition, image, history, learning, inventory and `Speak` paths.
- [`phonemizer/Invoke-EnglishPhonemizer.ps1`](https://github.com/MansfieldPlumbing/Kokoro-Hexagon/blob/main/phonemizer/Invoke-EnglishPhonemizer.ps1) — `CorePhonics.Lattice`, learned pieces, native sound-out logic.
- [`student/Invoke-StudentJudges.ps1`](https://github.com/MansfieldPlumbing/Kokoro-Hexagon/blob/main/student/Invoke-StudentJudges.ps1) — independent composition/phonics/corpus/phrasing checks.
- [October 30 Student judge record](https://github.com/MansfieldPlumbing/Kokoro-Hexagon/blob/main/docs/results/student-front-end-judges-20261030.md) — the key 0.1%-role-coverage finding.
- [October 30 morphology/composition commit](https://github.com/MansfieldPlumbing/Kokoro-Hexagon/commit/599923d167fe46193703ce47e8d29f079d75ccda), [native phonics commit](https://github.com/MansfieldPlumbing/Kokoro-Hexagon/commit/848d44c5b7e7dd3da14854d81e9aa4d963c97570), [October 31 gains](https://github.com/MansfieldPlumbing/Kokoro-Hexagon/commit/ab6c999df5ec5fdc380b92ec11c31a649ba6f4a5), [November 2 directive deletion](https://github.com/MansfieldPlumbing/Kokoro-Hexagon/commit/6d88079cbf539544101f64b4f6729788ed4134d2).

**User-supplied primary/context sources (not publicly linked)**

- `NL1_Telos_User_Messages_Only.txt`, approximately lines **775–831**: owner’s development of NL1 and its key constraints; later lines distinguish exploratory extensions.
- `Pasted text(20261102-075833).txt`: fuller Telos conversation and assistant framing; the user's speech is preferred over assistant paraphrase when reconstructing what he approved.
- `New folder (10)_2026-11-03--09-54-12.zip` → serialized indexed text `New folder (10)_2026-11-03--09-54-12.txt` (12,846 lines):
  - **987–1001**, `agents-md-edits-scoped.md`: October 20 documentation edits and reversions.
  - **1578–1592**, `kokoro-lego-phonemizer.md`: 2007 aligner rejection and native many-to-many direction.
  - **455–503**, `docs-and-code-are-unreliable-narrators.md` / `engage-scott-architecture-ideas.md`: agent's own repeated-misinterpretation record.
  - **2250–2270**, `student-generalizes-by-type.md`: typed learning and categorical rejection of curated special sentences.
  - **2274–2299**, `student-history-plumbing.md`: current state vs unbuilt NL1 append-only history.
  - **2232–2248**, `sounds-good-not-acceptance.md`: documented example of a conversational reaction incorrectly promoted into acceptance evidence.

**Provenance discipline:** Claude memory entries are contemporaneous *agent-authored records of its understanding*, not independent proof of the owner's approval. The public repository proves code and commits, not unseen negotiations. The owner's testimony is evidence of direction, intervention, experience and cost, not a substitute for device measurements or a lost Git diff. These classes are deliberately not collapsed.

*Prepared 2026-11-03. Read-only investigation; no source repositories, histories or ACLs were modified.*

---

## Continuing investigation — 2026-11-09 (America/New_York)

This addendum records the current working tree at `C:\dev\kokoro-hexagon`. HEAD is `6d88079cbf539544101f64b4f6729788ed4134d2`, but several inspected files contain pre-existing uncommitted work; HEAD alone does not identify this evidence. These findings were made by Codex through source inspection with PowerShell's AST and small in-memory probes. No new DSP timing or numerical-equivalence result has been obtained in this investigation yet. No project source or PSC was modified by this investigation. The separately authorized edit to `C:\dev\AGENTS.md` removed requirements entrenching `C:\dev\sma`.

Scott reports that Claude Opus has principally handled the project and that the requested single-script consolidation was not maintained. The source establishes the technical conditions below; it does not independently establish which agent authored each condition, its intent, or which prior correction it refused.

### Direction clarified by Scott in this investigation

- PowerShell/SMA is the frontend, with text parsed into objects with extended types and lowered computational helpers. The stock neural frontend is reference machinery, not the architectural target to preserve or optimize by default.
- The project is to be one script, including a Kokoro frontend class and a kernel API reusing primitives and invariants. A dispatcher over separate kernel files is unfinished consolidation. Merely concatenating files would not eliminate duplicated engineering knowledge.
- `C:\dev\sma` is ephemeral experimentation intended for removal, not a shared infrastructure dependency. It is distinct from the System.Management.Automation runtime and AST facilities.
- PSC may be inspected but must not be written to. Future integration of Hexagon emission into PSC is Scott's direction; it is not authorization to modify PSC now.
- SDK correctness is a contract and comparison point, not an optimization ceiling. Preserve the measured R0Sub0 artifacts and seek improvements with independent behavioral and hardware evidence.
- Scott authorized maintaining this audit as a durable record of findings as work continues.

These statements record the current request, not new rules invented by the audit.

### Finding ledger

| ID | Status | Finding and source evidence | Consequence / bounded opportunity |
| --- | --- | --- | --- |
| KH-01 | Source-confirmed | The owner file dispatches into separate kernel/job implementations. The inspected `src/kernels`, `src/jobs`, and `src/hexagon` directories contain 60 `.ps1` files. | Single-script consolidation is unfinished. Consolidation must centralize primitive behavior and invariants, not add a facade over the split implementation. |
| KH-02 | Source-confirmed inventory | AST inspection found 56 scriptblock assignments named `imm` across 40 files; `ptr` in 12 files, `call` in 13, `dma` in 9, `sync` in 4. Names and sites were counted; not every body was established to be identical. | Common immediate materialization, pointer construction, call relocation and DMA contracts are repeatedly authored. Acquire them once in the owning API. |
| KH-03 | Source-confirmed | `Invoke-HexagonDevelopment.ps1:754`, `Get-HexagonStepRegisters`, reconstructs register reads/writes by regex over instruction assembly templates. Packet resources are separately listed in `PacketClasses`. | Printed syntax substitutes for instruction semantics. Register effects and resource constraints should be owned by the instruction records and consumed by scheduling and verification. |
| KH-04 | Source-confirmed plus in-memory probe | `PacketClasses` excludes R0Sub0's `vmpy-sf`, `vadd-sf`, `vload-post`, and `vstore-post`. A two-instruction independent floating-point probe through `Group-HexagonPackets` produced no packet continuation. The direct named call to the grouper outside its owner is in `Generator60x16Run.ps1:163`. | Existing scheduling capability has narrow coverage and reach. More coverage is a performance candidate, not a measured improvement. Resource and latency contracts must be independently checked before hardware A/B. |
| KH-05 | Source-confirmed | `src/lower/Lower-Model.ps1` stores graph operands as `%id`, `@name`, `#value`; unsupported expressions become `?` plus source text. CSE signatures concatenate strings. `Kokoro.R0Sub0.ps1:20` matches an exact 11-operation graph using comma-joined input strings. | The graph structure and R0Sub0 schedule are not a transferable scheduling capability. Preserve operation order and measured binaries while moving reusable dependency/liveness knowledge into the owner. |
| KH-06 | Source-confirmed | `Kokoro.R0Sub0.ps1` explicitly assigns eight lanes of three working vector registers, interleaves each operation across lanes, and separately writes the tail arithmetic. Six live constant registers plus 24 lane registers account for the stated 30-register schedule. | Interleaving supplies independent dependency chains without changing each lane's floating-point operation order. Register assignment, lane count, graph matching and tail are still handwritten. Eight lanes are not established as optimal for another graph. |
| KH-07 | Source-confirmed | `student/Invoke-Student.ps1:5072`, `New-StudentTextPhones`, builds/finalizes an interpretation, invokes the phonemizer again for comparison, and calls `Get-StudentClauseStatus`, which builds another interpretation at line 5014. It creates occurrence records from tokens and binds clause data through source offsets. | The speaking path repeatedly derives facts already present in its interpretation. A retained frontend class can expose pronunciation, tokens, transitions and clause relationships from one interpretation; independent checking belongs in verification. No speedup has been measured yet. |
| KH-08 | Source-confirmed; qualification | Student objects do have ETS behavior: interpretation `Append`, composition `Apply`, image `Reconsider` and others are attached with `Update-TypeData`. However, `Speak` uses `New-StudentTextPhones`; the persistent `Compose` entrypoint is separate and consumes supplied typed analysis. | `PSCustomObject` alone is not proof of a broken object model, and a `PSTypeName` alone is not proof of meaningful behavior. Reachability, retained identity/state and ownership of semantics decide whether the object model amortizes work. Replacing syntax with classes without repairing these boundaries would be cosmetic. |
| KH-09 | Source-confirmed | `src/jobs/Kokoro.Albert16Run.ps1:297-312` has ten interpolated `ScriptBlock.Create` sites. Two more in the Hexagon owner reparse stored model strings. | Source AST inspection sees string construction, not the executable bodies until they are reparsed. Direct structured operation construction can remove this hidden source layer. |
| KH-10 | Source-confirmed | `src/jobs/Kokoro.WrappedJob.ps1:23` obtains a frozen resblock job, finds `connected_job`, copies its prefix, and patches buffer minima and VTCM request/check values by emitted instruction/register patterns. It then performs its own call-address layout. | Reuse is implemented through reverse-engineering an emitted body's shape rather than a resource-wrapper API. An owner-provided wrapper can accept the actual buffer/resource contract directly. |
| KH-11 | Source-confirmed | `Generator60x16Run.ps1:411-413` saves a contiguous section-state range. The Chunked range ends before its weight region; the Backward range extends through the last resident weight. | Mutable history and reconstructible/read-only data are not separately described. A VTCM reuse-aware restore plan may reduce traffic, but overwritten weights still have to be restored or reloaded. Merely omitting them would be wrong. |
| KH-12 | Source-confirmed | `Generator60x16Run.ps1:1623` refuses uniform span-loop formation for resident source sections because their lockstep ranges are constants. The later span-relative mechanism builds three spans and infers affine immediates from them. | The kept resident-source path still emits spans inline, making library/build work grow with length. Runtime ranges and structured span-relative addresses are a candidate for transferable amortization. They are not yet a demonstrated DSP speedup. |
| KH-13 | Source-confirmed | `tools/Kokoro.Evaluator.psm1:162`, `Get-KokoroSourceKey`, hashes the owner, emitter adapter and `src/hexagon`, `src/kernels`, `src/jobs`, but omits `src/lower/Lower-Model.ps1`, which the R0Sub0/Affine/ConvTile builds invoke. | Cache identity does not cover every source dependency of those paths. A lowerer edit can fail to invalidate an existing cache. This was established from dependency inspection, not by modifying source to provoke it. |
| KH-14 | Source-confirmed verification limit | `Test-HexagonEmissionEquivalence` accepts exact hashes for emitting default recipes and continued failure for recipes recorded as failing; it does not require the same failure cause. The SDK assembler test checks encoding, packet membership and rejected operands. | Hash preservation is deterministic regression evidence, not new-graph competence, mathematical equivalence or performance. An unrelated failure can satisfy a recorded-failure row. Do not update baselines to conceal a change. |

### Quantitative source inventory

Method: `git ls-files --cached --others --exclude-standard`, unique existing `.ps1`, `.psm1`, `.psd1` paths; parse each current file through `System.Management.Automation.Language.Parser.ParseFile`. Ignored build artifacts, docs and other languages were excluded. All 111 files parsed without errors. These are syntactic expression counts, not distinct string values or runtime frequencies.

| Category | Count |
| --- | ---: |
| String-expression nodes including bare words | 97,053 |
| Quoted expressions including here-strings | 21,413 |
| Bare-word string nodes | 75,640 |
| Expandable expressions, included within quoted expressions | 1,556 |
| Literal scriptblock expressions | 1,256 |
| Explicit `ScriptBlock.Create()` sites | 12 |
| Runtime `.Compile()` call sites | 40 |

Quoted nodes: 19,728 single-quoted, 1,677 double-quoted, 7 single-quoted here-strings and 1 double-quoted here-string. Double-quoted expressions without interpolation are not expandable-string AST nodes.

Largest quoted counts: phonemizer 2,790; Kokoro development owner 2,312; Student 1,825; Hexagon owner 1,648; Generator60x16 job 1,146; precomputed decoder 615. Large counts do not by themselves prove defects: names, external formats and diagnostics legitimately use strings. The actionable question is whether strings substitute for semantic structure or cause already-known facts to be reconstructed.

The 40 `.Compile()` sites are in AudioMeasurement (13), CaptureKernels (23), CopySynthesisKernels (1) and Test-KokoroGeneratorTemplate1 (3), building expression-tree computations. These are structured .NET expression trees, not equivalent to source strings; they are independently inspectable. The original PowerShell AST sees their construction, rather than a direct AST of the numerical algorithm. Literal scriptblocks are normal parsed PowerShell structure and should not be conflated with interpolated executable source.

### Measurements retained, and priorities corrected

- September 24 records report R0Sub0 speedups of 2.213-2.256x on SM8550 and 2.286-2.302x on SM8635, with unchanged binaries on the second device and byte-identical outputs. This investigation read those records; it has not rerun them or independently recovered their external raw receipts.
- Existing generator work already amortizes substantial computation: the tile-schedule record culminates in lockstep; the source-on-DSP record reports packed fill and combines reducing the same workload from about 44.9 ms to 39.65 ms, with equal PCM.
- `Invoke-KokoroGeneratorDepthFirstEmission` already selects host coefficients, queued weights, packet packing, resident sources and span-size fallback. The October 28 power record reports CoreMax reducing a 15,601-frame check from 78.18 to 74.57 ms; this is already a kept generator setting. These are not new recommendations or newly measured gains.
- The October 28 span-front record reports equal PCM across 20/40/60-tile spans, with 60 tiles taking 78.18 ms before the kept CoreMax change. Workspace windows saved space but did not reduce DSP time in that check.
- Old phone stock-frontend measurements show about 4.8 s frontend time, ALBERT 61%. Initial inspection considered that the largest end-to-end optimization target. Scott clarified that the intended frontend is SMA/typed objects with lowered helpers. Accordingly, optimizing stock ALBERT is not the default proposed route. Student `Invoke-OfflineSpeech` with supplied durations/F0/N already bypasses ALBERT and the predictor; it still uses the stock text encoder and packing bridge.
- Reducing weight precision or dropping residual pairs is not an established free performance gain. Existing weight-precision and residual-retuning records show substantial waveform changes. No acceptance contract is weakened here.

### Candidate order; no implementation or speedup claimed

1. Finish one owning project script and a retained Kokoro frontend class that reuses its interpretation rather than rebuilding it. Preserve existing runtime/ETS capabilities where they provide actual behavior.
2. Give the existing kernel API shared primitive implementations and authoritative register/resource contracts. Demonstrate transfer to at least two structurally different computations, with a negative test for a dependency violation.
3. Investigate generator hot work using current measurements: remaining packet barriers in fill/combine, VTCM state-save/restore contents, and constant-range resident source spans. Preserve arithmetic and compare actual outputs before claiming a timing gain.
4. Repair dependency-complete cache identity and distinguish encoding, numerical equivalence, determinism, performance and expected failures in verification.

The first two steps remove repeated engineering work; the third contains hardware-performance hypotheses. Combining them into an unmeasured promised speedup would repeat the audit's original evidence failure.

### Working-tree evidence fingerprints

SHA-256 at inspection time; these identify current files rather than asserting all are committed:

| Path relative to `C:\dev\kokoro-hexagon` | SHA-256 |
| --- | --- |
| Invoke-HexagonDevelopment.ps1 | D29A5238ED7843362AFC8D5DD4E7A6C7C6AF1CE689835217EF596A4B0800684B |
| Invoke-KokoroDevelopment.ps1 | 1A68CF0883F8E0A31AA2F52F4F2C87801D66CCE0EE00F228B677A32348CEDE11 |
| src/lower/Lower-Model.ps1 | 7EBFB05B7E48070C74CACDA0B8E0F31317E9E1741C418D6A28B4F71134E19A38 |
| src/kernels/Kokoro.R0Sub0.ps1 | C95F892499CBC698446966E8E6ACFEC5D1E78419C66B13D26EB4BFDC27556D84 |
| src/jobs/Kokoro.Albert16Run.ps1 | FA2137BF03A408FF6F4C573CE98483474D08115A62A3B760138B01DD4EF207C4 |
| src/jobs/Kokoro.Generator60x16Run.ps1 | 0D8F870DAC013FF8B0BB263C40633767C7A4AAE78A976E67A9F74A28A82B5238 |
| src/jobs/Kokoro.WrappedJob.ps1 | B4932BCC0C93E1B6719A6C0DBB05F6B94C37510D08B592C0472765612FA787B8 |
| student/Invoke-Student.ps1 | 0FA374336E4368222D0A656EEA2FDC2C5B44338D2940390FAC9EFD5C92CCCD44 |
| tools/Kokoro.Evaluator.psm1 | 40AB9231E14537F044F15D51D7990520BE64509BBFB670F47520226E2424D6C8 |
| tools/Test-HexagonEmission.ps1 | 43FD7442C6F353A6D27F9FE7B8778D939A61DFC94E5FF79C213C22F20FFACEC2 |

### Hardware follow-up authorized in the same session

Scott reports his personal OnePlus is attached, `adb.ps1` is available and the Kokoro-Hexagon app is installed. Device identity, app identity and the current benchmark protocol remain to be checked. Scott asks the investigation to continue specifically for overlooked generator opportunities that could improve the current benchmarks. No new hardware result is recorded yet.
### Follow-up: generator integration and first hardware experiment (2026-11-09)

Scott clarified that decoder, generator and tail should converge into one depth-first execution schedule. A standalone stage benchmark is diagnostic only; it does not satisfy that architecture or establish an integrated speedup.

- **KH-15, source-confirmed:** `Generator60x16Run.ps1:167` explicitly rejects `Decoder` under a non-Layer schedule, and also rejects `RuntimeFrames`. `New-KokoroSpeechRenderer.Decode` therefore still produces a complete decoder output for a subsequent generator job. The decoder stream capability already exists (`decoder-stream-step-sm8550-20261028.md`), but its state/output pass through the host. This is a concrete composition barrier, not proof that one depth-first decoder-to-PCM schedule exists.
- **KH-16, source-confirmed:** generator tail input is reread from DDR; span stages preserve their handoffs through workspace. The target is to retain producer output and consumer halo/history within a unified schedule where the live-set fits. Producer and consumer lifetimes and VTCM overlap have to be established; deleting copies without that analysis would be incorrect.
- **KH-17, source-confirmed:** internal layout JSON round trips remain. The Hexagon emitter writes `runner-layout.json`; untyped evaluator paths and `Invoke-GeneratorTailProbe.ps1:53` read it back. The typed path already permits passing `EmissionArtifact.Layout` directly. File/network protocol JSON is a distinct case and must not be counted as gratuitous merely because it uses JSON. The six inspected emission/evaluation files have 95 JSON conversion call sites (24 Hexagon owner, 58 Kokoro owner, 11 evaluator, 1 SDK test, 1 tail probe, 0 compatibility emitter); these are syntactic sites, not runtime counts or 95 proven defects.
- **KH-18, source-confirmed plus static experiment:** `VectorPackets` does not cover every HVX helper in the integrated generator. Branch mean is appended directly at `Generator60x16Run.ps1:1869` (line subject to later changes), and `Get-KokoroGeneratorTail16Bodies` returns ungrouped leaky, combine and spectrum bodies. Applying the existing packet grouper in memory retained instruction counts and reduced static packet counts: spectrum 197 to 123; tail three-group combine 81 to 49; leaky input windows 30 to 20; branch mean 29 to 18; AdaIN/Leaky helper 96 to 51. These are static packet counts, not execution-time reductions. The low mean contribution in the old profile argues against treating its percentage as a major whole-job gain.

Hardware access confirmed with the existing `C:\dev\pwsh\scripts\adb.ps1`: OnePlus CPH2451, SM8550; `dev.mansfieldplumbing.kokoro` installed, run-as accessible. No device serial was recorded. One long listing hit a BlockCopy bounds exception in the existing ADB client; narrower subsequent reads succeeded. This is an observed client error, not a diagnosed transport failure.

The current app's retained October 30 speech receipt reports 450.95 ms generator DSP for 19.85 s audio. It is historical, not a fresh baseline. The current device's `spec.txt` describes a different old generic test; blindly rerunning that spec against the latest library would mix incompatible artifacts.

Recovered the October 28 15,601-frame generator result from retained app data without modifying the phone. A newly constructed layout has the same 49,823,936-byte workspace size as that retained output. The header gives final tensor offset 14,020,736; the layout's final workspace offset is 14,020,608, accounting for the observed 128-byte workspace base alignment. The layout PCM offset is directly output-relative at 22,176,000 and must NOT receive that alignment adjustment. The initially extracted PCM slice used the wrong extra 128 bytes; it was corrected before any test.

Recovered standalone-tail evidence under `C:\dev\kokoro-hexagon\build\generator-audit-20261109\tail-fixture`:

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| activations.bin | 3,997,696 | DA135597BA51758696B14F54E7A5508541B592820D286BDA454BB63A4C5CB4E2 |
| weights.bin | 172,032 | 8B1B6FEDEABB429BFA4CC2840471EEC6F139FCC00E84762CB2AFA52DBF1CE970 |
| tables.bin | 16,384 | 23E04EE96F50D168563229FD1FE492BD1D62810952E90F05CE9815AE135D50A3 |
| retained-whole-pcm.bin | 156,000 | 223D6305D3F78291B12C3FCCA1319BFAA2B214D3088DACB391A5F2DB207DDAFB |

Tensor and PCM prefixes match `generator-span-front-pieces-sm8550-20261028.md`. The recovered tail weights start at the generated layout's named tail region, byte 34,406,400; tail parameters at byte 1,245,184 follow the owning builder's layout calculation. Matching the recovered PCM with a newly executed tail remains the behavioral gate.

Two experimental standalone tail libraries were emitted through the existing Definition API without changing project source or baselines. The candidate groups only the appended tail helper bodies; wrapper and job orchestration are preserved. Instruction counts, label identities/addresses and total byte lengths were checked before emission. The first experiment command mistakenly retained the grouper's returned array as one nested array and failed the instruction-count assertion before emission/device writes; array handling was corrected under the same experiment.

| Library | SHA-256 |
| --- | --- |
| Baseline | 6F06FB7DE534C82168943EC31366EE7C17470E82F59391FB2F5A7C0BB87B3008 |
| Packed tail helper bodies | DEB786304CEFCE4CE14D87642F437539FA1340F0A0C8A3749D73840A7F2E5C8E |

The fresh baseline hardware run has been started with the recovered whole PCM hash as the required output. No passing result or timing improvement is claimed at this entry. This experiment tests a component of the eventual unified schedule, not a substitute execution architecture.
### Fresh phone results: unused packet capability transfers to tail helpers

The standalone-tail baseline reproduced the retained whole-generator PCM exactly, closing the fixture-recovery gate. The packet-grouped tail reproduced the same PCM in every invocation. Two execution orders were tested; each library had one cold invocation per batch. Both variants use the same existing resource wrapper and power configuration; no clock-vote change, weight change or arithmetic approximation was introduced.

| Order | Variant | Warm invocations | DSP median ticks at 19.2 MHz | DSP median ms |
| --- | --- | ---: | ---: | ---: |
| Baseline then packed | Baseline | 5 | 118,183 | 6.155365 |
| Baseline then packed | Packed | 5 | 98,485 | 5.129427 |
| Packed then baseline | Packed | 12 | 98,689.5 | 5.140078 |
| Packed then baseline | Baseline | 12 | 118,005 | 6.146094 |

Packed latency was 16.7% lower in the first order and 16.4% lower in reverse order (about 1.20x tail throughput). All 38 invocations produced PCM SHA-256 `223D6305D3F78291B12C3FCCA1319BFAA2B214D3088DACB391A5F2DB207DDAFB`. Every harness run reported `Passed=True` and `StartupRestored=True`; playback reported zero xruns. Output-buffer hashes differ because their headers contain timestamps; the actual PCM is identical.

Receipts under `build/generator-audit-20261109`:

- `tail-baseline/device-receipt-SM8550-640ae9cc451048b0a25e208e430fc55c.txt`
- `tail-packed/device-receipt-SM8550-a93457be5dfd49ad8f91831456e52dfd.txt`
- `tail-packed/device-receipt-SM8550-25f4c57734c743f78a6e6259962b2904.txt`
- `tail-baseline/device-receipt-SM8550-fee45382ff004bf6ad8d4ec7a3068b09.txt`

This is measured transfer of the existing packet mechanism to the tail's leaky transform, spectrum polynomial and plane combine. It is a component experiment, not a claimed 16% whole-generator gain, an integrated decoder-to-PCM result, or a completed source fix. The candidate introduces no new opcode; its schedules were not independently reassembled with the SDK in this investigation. Hardware/output evidence applies to these artifacts and inputs. Project sources, original default emissions and committed benchmark baselines remain unchanged; PSC remains untouched.

### Direction corrected: lifetimes, conditioning streams, four-phase exploration

Scott clarified the mechanism further:

1. The generator truly is depth-first; decoder, generator and tail are to accommodate that shape.
2. Bind the needed computations, data and conditioning just in time. Do not preserve VTCM memory after its last dependent use simply to preserve stage-sized allocations.
3. Move work that SMA/CoreCLR can resolve or compute out of the weight-heavy decoder when doing so improves the actual path.
4. Conditioning is a stream. Supplying fixed decoder coefficients is not sufficient evidence of the intended architecture.
5. Four-phase generation with procedural air is being explored in `C:\dev\kokoro-bdsm-dungeon`; native Opus output is an exploratory direction. This is not adoption of a new phase count or authorization to import experimental assumptions as proven generator behavior.

**Correction to this investigation's earlier framing:** a class retaining complete stage layouts, or fitting two full stage allocations side by side, is not the target. The owning API must retain semantic knowledge and expose just-in-time bindings with actual last-use lifetimes. A retained interpretation object should not imply retaining all intermediate numeric storage.

**KH-19, source-confirmed architectural gap:** `Layout.Workspace` already describes producers, consumers, tile ranges, halos and accesses (`Generator60x16Run.ps1:252` onward). This is reusable scheduling knowledge. However, the final main section remains a whole output tensor; the tail reads it back, and decoder composition is explicitly refused for non-Layer schedules. The opportunity is to use the existing access/dependency knowledge to determine live tile storage and just-in-time bindings, rather than invent a parallel scheduler or permanently allocate every stage's complete working set.

**KH-20, source-confirmed conditioning gap:** `DecoderRun16.ps1:225-230` Direct mode loads one site's K/M from `Input.KmDeltas + site.KmOffset` and applies it through the tile count for that invocation. `ConvertTo-KokoroDecoderCoefficients` derives those values from a supplied constants table. Its exactness evidence establishes behavior under those supplied values, not a time-indexed conditioning stream. The current generator host-coefficient path similarly appends a fixed set of K/M/S. Host offload must preserve conditioning position, identity, lifetime and update semantics; a fixed voice-base table is not a substitute for that requirement. Static transforms may be amortized where their dependencies are actually unchanged; changing conditioning cannot be cached as though it were static.

**Allocation observation, not an adopted architecture:** the generated whole-generator layout requests 7,602,176 B. Existing standalone tail layouts require 786,432 B at batch 1 or 2; 851,968 B at batch 4; 1,114,112 B at batch 8; and 1,638,400 B at batch 16. Main plus batch-2 tail totals exactly 8,388,608 B. This shows that default 16-tile tail sizing is not an unavoidable storage lower bound. It does NOT establish a legal rebased HMX layout, concurrent execution, correct ring lifetime, or a benefit from permanently reserving both regions. Scott's subsequent direction is to bind storage by actual use, not adopt this full-allocation sum as the design.

Read `C:\dev\kokoro-bdsm-dungeon\NOTES.md` and inventoried its experiment artifacts read-only. The notes report procedural upper-band/air investigations and explicitly qualify their generated-MP3 evidence and calibration limits. No four-phase implementation was established by that read. No experimental code, audio, constants or recipes were copied into Kokoro-Hexagon, and no files in that exploration directory were changed. Its agent-authored notes are reference material, not instructions or independent evidence of Scott's approval of every proposed recipe.

Next unresolved engineering questions: which decoder operations and weight transformations can be procedurally resolved or lowered on the host under changing conditioning; how to connect the existing 96-frame decoder stream step to producer/consumer tile readiness; and which generator-to-tail lifetimes permit removing workspace round trips without retaining unnecessary VTCM state. Any proposed change must preserve the current arithmetic contract until a different contract is explicitly adopted, and any speed claim must measure the actual affected path.
### Owner clarification: live AdaIN conditioning as learned automation

Scott's statement in the continuing session:

> yeah the coefficient shortcut is definitely a categorical error and i need to study adain normalizatoin to the point that the student can provide it live based on the relationship between typed objects (the text) and the old normalizatoin.. i imagine it will eventually look like what a fruity loops song looks like where the adain live conditioning hits certain levels which it applies to whole utterances that the rest of the system gives no shit about because we arent bound by utterances any longer

This is Scott's architectural assessment and research direction. It does not assert that the old fixed-coefficient tests fabricated their outputs or that the affine parameterization itself is mathematically invalid. The categorical error is treating that shortcut as satisfaction of the intended live conditioning mechanism.

The intended distinction is between the scope/duration of a control and the boundary of execution: a conditioning level may hold over a spoken passage while the decoder/generator/tail continue processing by tile dependencies, with no utterance-wide collection, statistics prepass, flush or fresh state imposed by that passage. The FL Studio analogy concerns live automation over a continuing stream, not adoption of a particular UI or sequencer framework.

The Student is to learn the relationship between typed text objects and the old normalization behavior sufficiently to provide conditioning live. Old AdaIN observations are explanatory evidence to study; a fixed voice base, per-category constants, or a replayed normalization table must not be silently promoted into the learned capability. What the controls represent, their necessary temporal resolution, and how the Student derives them remain research questions, not already implemented facts.

Evidence needed to advance this finding: trace the original AdaIN normalization through its actual reduction axes and style application; align those observations with typed source relationships and the resulting audio; distinguish reusable procedures from stored traces; and demonstrate that the live control reaches the intended kernel site at the intended stream position. Fixed-input coefficient equivalence alone cannot establish those properties. No new model, normalization recipe or acceptance threshold is adopted by this audit.
### Student audit begun; owner clarified the discovery mechanism

Scott requested inspection of `Learn`, `Percepts`, `Reconsider` and admission, against this mechanism:

- Three independently grounded bearings (where, when, how) establish a shared coordinate/vantage point. That alignment is not itself the percept.
- Investigation from that vantage may discover a previously unseen relationship. Three transformations of one measurement do not supply independent provenance.
- Three sigma is the requested statistical admission threshold under an appropriate declared baseline/uncertainty model. It is not three agreeing examples and must not be fabricated from inadequate or correlated evidence. Inferred, observed at three sigma, and proven are distinct evidence descriptions.
- Mathematical proof is not a prerequisite for doing useful work. Scott clarified that later benchmarks against stock can supply the practical proof: make the Student's prediction first, then compare behavior, output quality, timing and work avoided against the stock system.
- Recursion reuses retained understanding as a new bearing and seeks further independent evidence. An alignment need not yield a percept. Retain unsuccessful investigations so unchanged work is not repeated.
- A percept must earn its place by transfer to a fresh history and by eliminating subsequent work. Statistical confidence in a lookup entry does not establish this.
- The unit bank contains useful observations/associations on which to stand while searching; it is not a bank of percepts.
- The Student perceives a continuing stream of objects with extended types. Sentence/utterance boundaries are not construction, reset or execution boundaries. Scott identifies mutation of the SMA environment as the mechanism for natural-language interpretation; the audit must inspect its actual bindings/types and their use, rather than assume a separate generic NLP framework.
- The operational target is live AdaIN conditioning, performed from typed object relationships as sheet music is performed, consumed at the appropriate positions by the depth-first system.

Important correction to Codex's commentary: calling table-driven prosody an architectural dead end overstated Scott's direction. Scott clarified that it can be step one in the multi-step search for percepts. The failure is stopping at that unit-bank stage and calling the stored tables the acquired capability. Category averages and fixed offsets are not the intended depth-first runtime knowledge, but their observations may be investigation scaffolding. Do not delete or cosmetically rename them as a substitute for advancing discovery.

Current source findings, pending fuller investigation:

- `New-StudentProsodyRules` (4142) computes keyed averages of log duration, voiced share, pitch and energy, plus category offsets; its methods sum those terms. `Invoke-StudentInventory` (4430) rebuilds candidate rules and replay libraries when no matching live Analysis is provided. This is reached by Speak through Use-StudentInventory.
- `New-StudentControlRecordings` (4272) stores duration ratios and pitch/energy/voicing residual curves under word/stress/boundary keys. `Find-StudentControlRecording` (4298) chooses the most specific key and its median-duration-ratio recording. This is a concrete unit-bank/replay mechanism, not by itself a discovered percept.
- `Invoke-StudentRuleLearning` (3824) estimates mean pause/pitch-reset values by style and boundary category. It admits when any one of pause error, pitch error or boundary accuracy improves against its baseline. Its eight-training/four-held-out minimums and a three-valued authored prior do not establish three sigma or three independent bearings.
- `Invoke-StudentJunctureLearning` (5155) searches conjunctions of one or two predefined observables, fits a mean pitch residual, admits with count/net-fix/error checks, and stores DeltaLogHz. It retains rejected evidence keys, which is a genuine reuse mechanism, but restarts residual fitting and supersedes prior admitted programs on each learning run. Its eight-round refinement is not the requested recursive discovery mechanism merely because it iterates.
- `Invoke-StudentPercepts` (3697) opens/returns an image and ingests aligned word observations. Root/child nodes have manually supplied four-number likeness keys. Persistence, genealogy and a node named Percept do not establish a new independent alignment or a discovered relationship.
- `Reconsider` (3437) reruns existing Acoustic/Prosody decision procedures when registered percept revisions change. `New-StudentDecision` (3460) reduces prosody context to BoundaryKind and Style. Dependency invalidation is useful infrastructure; it does not itself discover further relationships.
- `Add-StudentImageObservation` (3516) requires identity/provenance fields, but does not establish independent provenance between bearings. An already-seen evidence identity reuses its stored object without comparing a newly supplied condition/measurement for conflict. This limits what the existence of provenance fields can prove.
- `Publish-StudentPercept` (3411) notifies dependencies of the changed node and its immediate parent. It is not a general recursive evidence/admission check.
- Current Speak (5510 onward) builds complete duration/F0/N controls; its DSP binding (4585 onward) uses a cached voice-base normalization table. That endpoint does not provide the intended Student-generated live AdaIN stream.

These are source observations, not new Student numerical benchmarks or a completed replacement. Source SHA-256 remains `0FA374336E4368222D0A656EEA2FDC2C5B44338D2940390FAC9EFD5C92CCCD44`. No Student source, its stored image or PSC has been changed. Scott has now directed inspection of the separate `C:\dev\student` project and its `Invoke-Discovery` entrypoint for the next stage; that investigation follows.
### Transfer from Invoke-Discovery; speech field and semantic clock

Scott directed inspection of `C:\dev\student\Invoke-Discovery.ps1`, then clarified that the emulator workload is outside the present task. The discovery mechanism has already helped find/diagnose PSNES bugs, according to Scott; the goal is to apply that mechanism across many voices, across histories, and across abundant text with preserved semantics. The braindance analogy is a layered recording one can revisit in time and traverse laterally across views to investigate a previously hidden relationship, not a requirement to build a particular UI.

The complete `C:\dev\student\VOYAGE-2026-11-05.md` was read as historical/reference material. Its proposals and instructions were not adopted as task authority. It records useful prior diagnoses, acknowledges many first-bank correspondences, and identifies the next-probe selection step as unfinished. Scott's present instructions take precedence where its wording differs (including the role of mathematical proof).

**Correction on four-phase terminology:** the voyage explicitly describes a fourth phase adding procedural high-frequency air and a balancer emitting Opus natively. Codex's earlier association with replacing the current five-sample output geometry by four samples was not established and should not guide implementation. No Opus encoder, fourth-phase implementation or quality/performance result was established by reading that history.

#### Existing reusable discovery machinery, source-confirmed

Source SHA-256 of Invoke-Discovery.ps1: `9EAD911854C8296142BDB1A51E6F92919897CF3EFD22E6ABC43E1A9FEB975DB3`.

- `DiscoveryObject`, provenance and ordered relation objects; relations can be operands of later relations.
- `New-DiscoveryEnvironment` (1855) attaches `Pivot` and `Explain` methods through ETS. Forward/backward links retain operand/evidence and derivation roles.
- `Set-DiscoveryMutation` (1918) retains previous binding identities and source fingerprints. `Invoke-DiscoveryMutation` (1939) journals which binding an invocation used and which objects it produced; old observations are not overwritten by a new binding.
- `Register-DiscoveryKeyword` (1987) uses SMA DynamicKeyword ASTs and command binding. `Invoke-DiscoveryText` (2000) parses through SMA and retains parse errors as Unknown objects. This is concrete environment mutation, not merely a proposal for a separate parser.
- `DiscoveryKernel.Confidence` computes an observed deviation using the sample standard deviation of supplied controls, and returns NaN for inadequate/zero-variance controls. `Add-DiscoveryRelation` keeps confidence separate from Truth, which remains Unknown. The native-import experiment's positive z threshold is scoped to its overlap nomination; it is not an independently validated universal speech admission policy.
- Current CoreCLR discovery explicitly records that its two-view correspondences lack a third disparate bearing and a fresh recursive confidence check. Traversing a relation back to its import measurement is not misrepresented there as a new independent observation.

**KH-21, admission gap:** `Add-DiscoveryObject` (1875) rejects Kind Percept unconditionally, with a message requiring a scoped mathematical proof and executable applicability. Preventing a mere label change from promoting an observation is useful; no usable-percept admission path was established by the inspected constructor. The mathematical-proof wording conflicts with Scott's current clarification that useful observed relationships may be used and benchmarked afterwards. Do not fix this by simply allowing observations to be relabeled Percept.

Ran the bounded `-DiscoveryCheck` mode in a fresh PowerShell process, with outputs under Kokoro's existing ignored build tree, not the emulator experiments or PSC. It passed:

- Object lifetime: 1,536 compared bytes, zero mismatches, stale/expired lease rejected, zero remaining pins.
- SMA environment: one actual dynamic-keyword AST; an already compiled AST used the successor binding (1 then 2) while the earlier observation retained its original binding; body evaluated to 42. Three fixture relations retained identity and remained Unknown. These are constructed conformance fixtures, not discoveries of three independent real-world relationships.
- Mapped evidence: 2,097,244 bytes compared with zero mismatches; shared references and a cycle preserved; invalid reads rejected; data assembly has zero executable methods and only a CoreLib reference.

Output assembly: `build/generator-audit-20261109/discovery-check/evidence-check-9b4ffe95840042efa686464b92f367b8.dll`, SHA-256 `DA0EB3D2A74E09F7B5BEE55CCB8C86431FBDC20BCE4EF30CE9E15BF6A33D0601`. No source in C:\dev\student was modified. Its pre-existing change to experiments/smb-bearings/runs.clixml was left alone. No emulator workload was run, and PSC was not changed.

#### Speech-specific application: retain meaning and establish temporal correspondences

The Kokoro working tree already has useful typed observation classes at `Invoke-KokoroDevelopment.ps1:3876-3986`: clocks, observed streams, producer/port/AST identity, language-object timing, observation slices and joint observations. `Open-KokoroStockReference` (4016) retains a resident reference module across voices rather than rebuilding its kernels and caches. There are 54 voice files present locally. `Invoke-KokoroStockObservation` (4029) accepts parsed English objects and a voice object and retains both, rather than reducing its input to a new sentence label. These are existing, pre-existing working-tree capabilities; they were not authored in this audit.

**KH-22, source-confirmed clock/coverage gap:** the AdaIN observation callback passes a null clock into Observe for intermediate arrays, including arrays whose frames/channels are captured. Later code establishes clocks for final F0/N/features and PCM, but does not propagate temporal correspondence into those AdaIN observations. `KokoroStockObservation.At` selects streams by reference equality with the requested clock, so those unclocked AdaIN observations are excluded from its timed joint view. Reading array indices alone does not establish their physical or semantic time. Per-channel whole-reduction statistics also have a dependency extent, not an invented per-sample time axis. The next useful shaping work is to establish those correspondences from actual producers and transformations, not stamp every internal array with the same clock.

Scott asked, "the text is the clock, yes?" The working interpretation affirmed in the conversation is: the continuing stream of interpreted text objects supplies semantic position/order. Original audio and control clocks remain attached to their actual realizations and are mapped to that semantic stream. Different voices may spend different numbers of samples on the same semantic event; matching absolute seconds would not preserve the text relationship. Text is not flattened to a sentence key, and sentence/utterance boundaries do not reset the interpretation state.

The current stock observation path establishes language timing from the stock render's token durations. That is explicitly a correspondence within the finite reference experiment; it must not silently define the Student's semantic clock or its lifetime. A discovery field across voices/histories should retain the original language objects, their meanings and relations, the voice/style state, AdaIN input/output/statistical dependency extents, and resulting audio, with independently grounded alignment evidence. Multiple views or voices sharing one checkpoint/measurement are not automatically independent bearings.

The actual discovery/application loop remains to be demonstrated for speech: align the field, investigate a new relationship, record its statistical evidence/limits, let the Student act from the retained procedure before consulting the new stock result, benchmark afterwards, and measure which work was actually avoided. Existing conformance checks establish useful infrastructure; they do not by themselves establish live AdaIN generation or percept-driven amortization.
### Full corpus reachability, voice coverage and resident evidence bank (2026-11-09)

Scott directed a large perceptive field across English-supporting voices and varied text, preserving semantics, and then explicitly preferred keeping the active field in RAM. This experiment retains original evidence in memory using the existing DiscoveryEnvironment; it does not claim a completed semantic speech field or new percept.

#### Available evidence and current reachability limits

- Local Common Voice Spontaneous Speech 5.0 English archive: `S:\dev\collections\common-voice-spontaneous-speech-5.0-en\1789489472613-sps-corpus-5.0-2026-09-11-en.tar.gz`, 544,267,165 bytes. SHA-256 checked against retained provenance: `390B5A54C9AFE0CC01DA039AD206248F85682F247DD2B27D4CC0AB9A68E860B6`.
- Archive inventory: 8,709 entries, including 8,703 MP3 files containing 561,597,514 bytes. The main manifest has 5,898 rows, 2,571 nonempty transcriptions and 2,199 distinct transcript strings. Main-manifest duration totals approximately 18.601 hours; nonempty-transcript rows approximately 8.595 hours. These totals do not claim all audio has transcriptions or alignments.
- Main manifest has 642 distinct opaque client identifiers. Preserve these as provenance/partitioning evidence, not attempts to identify people. Split counts: train 1,569; dev 548; test 357; unassigned 3,424. Preserve the existing split assignments before designing held-out investigations. Reported-audio manifest has another 2,938 rows; rows must not be mistaken for distinct independent recordings.
- **KH-23, corpus reachability:** existing `New-KokoroRelationalCorpus` takes only the first three manifest rows (`Invoke-KokoroDevelopment.ps1:4498`). The large archive is present, but that path does not expose its full perceptive field. Original MP3s are not thereby decoded or semantically aligned.
- All 54 local Kokoro voice packs were checked against byte lengths and LFS SHA-256 identifiers from the official catalog at model revision `f3ff3571791e39611d31c381e3a41a3af07b4987`: zero missing files and zero mismatches. Combined size 28,264,709 bytes.
- **KH-24, voice reachability:** `Get-StudentVoices` enumerates only the three voice entries in the local manifest, despite 54 packs being present. Thus an enumeration through that API is not exhaustive voice coverage.
- The pinned official VOICES.md documents 20 American-English and 8 British-English voices. Hindi voices are not established as Indian-English support by their names; other packs remain available for actual English-support experiments. Do not silently classify Hindi as English or an Italian voice prefix as Indian. Source: https://huggingface.co/hexgrad/Kokoro-82M/blob/f3ff3571791e39611d31c381e3a41a3af07b4987/VOICES.md .
- Recorded accent metadata includes India/South Asia on 27 main-manifest rows; labels are reported metadata, not independent linguistic validation.

#### Actual RAM experiment

Created a resident PowerShell process (PID 5940; tool session 68382) and isolated the existing discovery definitions in a module using its bounded DiscoveryCheck mode. No emulator workload ran. Source was not changed and no new project script was added.

The resident variables are `$SpeechDiscoveryModule`, `$SpeechField`, `$CorpusBank`, and `$VoiceBank`. Environment identity: `0b583aae39ae426c9d678c9d834115bc`. It currently retains 17,600 actual DiscoveryObject instances:

- original archive identity and its original compressed byte array;
- all 8,703 original MP3 payload arrays;
- four original metadata members and all 8,836 TSV records from the two manifests;
- official pinned voice catalog metadata and all 54 original verified voice-pack byte arrays.

Audio references from both manifests resolved with zero missing references. A sampled record's direct backward traversal returned its original metadata object and its referenced RecordedAudio object. ReferenceEquals confirmed that retrieving the retained archive through the environment returns the same byte array, not a reserialized copy.

After a full managed collection, managed memory was 1,214,823,064 bytes (about 1.13 GiB); a subsequent process working-set reading was 1,377,640,448 bytes (about 1.28 GiB). These measurements cover this evidence bank, not decoded PCM for the entire corpus, stock renders, or semantic models. Machine inventory was approximately 159.6 GiB total physical memory with 144.6 GiB free, and S: approximately 1,040.7 GiB free, before loading.

Original archives/packs remain the durable source. Active evidence is retained in RAM; no JSON persistence or repeated archive deserialization was introduced. This is an audit-session resident process, not an implemented product lifecycle or a restart/recovery service. Its in-memory state lasts only while that process remains alive.

**KH-25, ETS traversal scope:** invoking a loaded record's existing `.Pivot('Back')` outside the module failed with 'Cannot index into a null array.' `New-DiscoveryEnvironment` installs a ScriptMethod that looks up `$script:DiscoveryFields`; the registration does not establish that this lookup resolves in its defining module when called elsewhere. Calling the existing `Get-DiscoveryNeighbors` inside the owning module against the same object succeeded and returned both provenance links. This establishes a module-boundary problem in the convenience method, not missing underlying links. No source fix was applied during this experiment.

The TSV rows remain original external metadata wrapped in DiscoveryObject; they have not been promoted into interpreted semantic language objects. Original compressed audio remains evidence, not extracted prosody. No stock synthesis across all voices, independent acoustic judging, real-time AdaIN stream, statistical admission, or work-eliminating percept was demonstrated by loading this bank. Those remain distinct next steps. PSC, Student source, and the pre-existing Kokoro working-tree changes were left untouched.

### Cross-voice sweep: source-confirmed repeated work (2026-11-09)

Scott points out that the existing implementation is fast and the sweep should exploit that. The intended reference path is the existing PowerShell-authored stock-equivalent implementation, retaining resident weights, compiled kernels and original evidence. The cost of full observation capture still needs a warm measurement; fast component benchmarks alone do not establish total corpus acquisition time.

**KH-26, repeated voice-independent computation:** `Invoke-OfflineSpeech` unconditionally repeats ALBERT (12 shared-layer applications), `bert_encoder.module` linear projection, and the text encoder for each call. Their authored inputs are token IDs and pinned model state; voice conditioning first enters the predictor through AppendStyle. The text encoder runs on token IDs, before duration expansion. The safe potential reuse boundary is the exact token sequence and applicable model/kernel execution state, not merely equal raw text. Dialect-dependent phonemization may yield different token sequences. Predictor durations/F0/N, duration expansion, decoder and generator must continue to receive each voice's actual conditioning. No cross-voice equality of those outputs is assumed.

**KH-27, repeated reference setup inside hot calls:** `Invoke-OfflineSpeech` reads/parses config.json on every call. `Read-OfflineVoiceRow` reads/parses lib/manifest.json and opens the voice tensor archive for every voice/phoneme-count lookup, despite model weights already having a resident weight cache. That function also independently rejects any voice absent from the three-entry manifest; bypassing the Get-StudentVoices enumerator alone cannot provide 28-voice coverage. These are source-confirmed repetitions, not measured speedups.

`Invoke-KokoroStockObservation` also parses/hashes reference source for each capture and copies observed primitive arrays. Moving validated source-generation metadata to a resident owner and measuring capture cost are candidate improvements. Integrity checks must still detect changed source; neither weakening provenance nor silently reusing stale compiled/source state is authorized by this observation.

A sensible bounded measurement is cold initialization followed by repeated warm renders of the same actual token sequence under several voices, comparing capture-enabled and capture-disabled execution. Any proposed shared-stage reuse should be checked against independently computed full-path outputs before expanding the sweep. Complete corpus acquisition time, capture memory growth, a production sweep API, and cross-voice stage reuse have not yet been demonstrated. No source was changed by this inspection.

### Resident reference reuse and corpus-stream census (2026-11-10)

#### Current owner direction

The Student is a deterministic worldview, as good as what it has learned; it is not a replacement for Kokoro's predictor. Investigate small recurring relationships that can compose on unfamiliar text and eliminate work. The perceptive field stays large and preserves preceding context where actually known. Do not turn a recording, sentence or utterance into the Student's construction/lifetime unit. Independent corpus recordings do not establish conversational adjacency.

Scott describes the intended live conditioning as FL Studio-like automation or a musical score: several control lanes may hold, change and overlap across text objects. Typed occurrences should reference the conditioning and normalization scope they actually experienced, not acquire an intrinsic word-type coefficient. Stock AdaIN uses full-context per-channel normalization and style-conditioned affine parameters at each site; an event-driven hold/change procedure is the Student's intended acquired behavior, not something stock AdaIN already discovers.

Phonics means written composition, not another phoneme string. Phonics, morphemes/roots/affixes, syllabification/stress, grammatical composition, lexical senses and borrowing history are different analyses of the same source and can have lateral relationships and alternatives. Scott supplied Wikidata Lexemes (CC0) and Open English Wordnet (CC BY 4.0) as possible enrichment sources; those license descriptions were supplied by Scott and no new dependency/download was introduced here. psperception is stale and excluded. C:\dev\sma is deprecated and must be ignored entirely; no dependency on it was added. PowerShell's System.Management.Automation runtime remains distinct.

Scott reconsidered exhaustive internal decoder capture: broad acquisition should focus on actual component I/O and their relationships. Internal convolution histories are an explicit diagnostic option. Rich conditioning capture remains available for targeted investigations.

#### Implemented reference changes, not Student changes

Changes are in the two existing owning scripts, Invoke-KokoroDevelopment.ps1 and tools/Invoke-KokoroPrecomputedDecoder.ps1. Both had substantial pre-existing modifications. Their exact pre-edit bytes were saved by SHA-256 as .original files under build/generator-audit-20261109/resident-reference; those snapshots, rather than Git HEAD, are the reference for separating this work. No PSC or Student source was changed and no new project script was added.

- Open-KokoroStockReference can opt into ReuseText and accept additional original voice-pack pins from the verified catalog. Existing manifest pins cannot be silently contradicted.
- Each reference generation retains its config/manifest, verified voice archives and model/kernel caches. Voice row selection still uses the current phoneme count. It never caches a single row per voice.
- One typed OfflineTextPreparation retains exact token IDs, ALBERT output, bert_encoder output and text encoding while voices are swept. Full token equality decides a hit. Changed sequences invalidate it; trace/quantization experiments and supplied prosody bypass reuse. Caller-visible arrays are isolated from cached arrays. RecomputeText provides a fresh-computation control.
- Full results now also expose bert_encoder, aligned text-encoder input, and actual acoustic/prosody styles, alongside durations, F0/N, generator features and PCM.
- Observation detail is an enum: Boundaries (default), Conditioning, DecoderInternals. Captures retain the original interpreted object and voice, purpose, authored capture definition, source hash and Explain method. These are observations, not admitted percepts or an automatic explanation of a discovery.
- Conditioning operations retain original observed input/output streams, parameters, available statistics, the authored reduction definition and full per-channel frame-reduction extent. Predictor/decoder grids carry the actual 40/80 Hz rate propagated by their caller. ForLanguage retains reference-context dependency and AtControlPosition traverses established grids without rebuilding the arrays.
- Generator normalization scopes are attached to the complete reference semantic context, but their point mapping is deliberately unestablished: padding/reflection/STFT transforms have not been accounted for. AtControlPosition rejects those cases. This is a remaining gate before claiming complete semantic temporal coverage or starting the large sweep.
- DecoderInternals additionally captures convolution, concatenation, activation, upsample and residual results with producer/input references. It is disabled by default.

#### Verification actually run

The resident pre-edit module and changed modules used the same existing CoreLib-only numeric assembly. Numeric kernel bodies were not modified. The final successful nine-case run used three interpreted inputs (7, 14 and 25 phoneme characters) and three voices (af_heart, am_michael, bm_daniel), with identical seeded randomness. All nine original returned numerical boundaries were checked against both reused rendering and conditioning-enabled rendering: 162 byte-exact array comparisons, including final PCM, all passed. Original interpreted-object identity, full normalization extents, and rejection of unestablished generator point mappings were also checked.

Separate negative checks passed: caller mutation of returned ALBERT/projection/text-encoding/token arrays cannot poison preparation; a reversed same-length token sequence forces a cache miss and matches fresh execution; voice rows at phoneme counts 1, 7 and 510 match the pre-edit reference. These checks are available in the existing main script as Test-KokoroStockReferenceReuse and Test-KokoroStockTextPreparation. Three voices here establish bounded implementation coverage, not discovery sufficiency.

The successful nine-case fresh times were approximately 1.809-3.677 seconds, reused times 1.610-3.349 seconds, and conditioning captures 2.672-4.466 seconds. These are mixed first-use/warm cases, not a corpus throughput claim. Conditioning value arrays retained approximately 214.9-419.5 MiB per case. Boundary-only captures measured 576,568 bytes (0.55 MiB, 2.111 seconds) and 1,128,456 bytes (1.08 MiB, 3.790 seconds). Array-byte totals exclude object/AST/checkpoint overhead. Boundary collection is dramatically smaller than exhaustive conditioning capture.

One earlier run was invalidated because source changed during an active capture; the existing integrity gate correctly rejected it. Another stopped on an incorrectly selected capture AST before rendering. Both were corrected and the nine-case run was repeated successfully. Neither failed run is counted as passing evidence. The final subsequent voice-name validator/path handling edit still requires its own smoke check; it does not change numeric computation.

#### Parsed corpus, preserving incomplete interpretations

Using a hash-verified existing compiled English driver whose author SHA matches current phonemizer source (driver artifact SHA 57ED44F730F29F7B36C35F7AB1D6377DF5CB83C1E167554F5854D7863CA5B34F), parsed all 2,571 nonempty main-manifest transcriptions into actual CoreResult objects in the resident process. This took 2.0136 seconds. There were zero invocation failures; 2,103 Complete=true, 468 incomplete. Complete is a front-end status, not proof of comprehensive semantic understanding.

These roots retain 67,456 CoreToken occurrences across 290,819 source characters. Of complete inputs, 2,038 fit stock's direct 1-510 phoneme limit; 65 exceed it. The original 71,988 render arithmetic therefore does not describe currently eligible calls. Incomplete/over-limit evidence is retained rather than silently dropped or forced into Student utterance units.

The CoreResult objects are wrapped as ReferenceTextInterpretation observations parented to their original manifest records. No token index or new frontend representation was constructed. CorpusLanguages, CorpusTokens, TextStreamCensus, CensusObjects and MorphologyCensus are resident diagnostic variables in process 5940/session 68382; active data remains in RAM.

#### Recursive census of populated objects and relationships

Traversal starts at the actual 2,571 resident CoreResult values, follows public instance fields and properties plus collection elements, and keys identity with ReferenceEqualityComparer. The compiled driver exposes its authored properties as CLR fields; a property-only pass was rejected as incomplete. A subsequent diagnostic used PowerShell's collection index syntax for array keys and produced invalid edge bookkeeping; it too was rejected. The corrected pass uses the dictionary's get_Item method for reference-identity keys, stops on errors, and completed in 99.0272 seconds with zero member-read failures.

Actual unique semantic instances: **104,806**, not just the 67,456 token occurrences:

| Populated type | Unique instances |
|---|---:|
| CoreToken | 67,456 |
| CoreOccurrence | 6,314 |
| CoreMorphologyParse | 6,276 |
| CoreCandidate | 5,298 |
| CoreClauseSpan | 4,991 |
| CoreNominal | 4,546 |
| CoreMorphologyRule | 3,062 |
| CoreNormalizationDecision | 2,998 |
| CoreResult | 2,571 |
| CoreClause | 1,038 |
| CoreAdjunct | 206 |
| CoreProposal | 50 |

Additionally 112,053 distinct collection instances and 380,129 populated member/collection reference edges were retained in the diagnostic. These are structural counts, not 380,129 independently grounded semantic relationships. 9,969 targets had multiple incoming references; 4,853 of those were semantic instances. Identity prevents counting a shared reference twice or following cycles indefinitely.

Observed member edges include 3,164 MorphologyParse.Inner edges and 3,164 typed Rule edges, 2,977 NormalizationDecision.Morphology edges, 3,901 Candidate.Subject edges, 1,232 Predicate edges, 1,038 Clause edges, 454 Object edges, 378 Auxiliary edges, 211 Adjunct edges and 90 Relation edges. Null/unresolved fields and scalar attributes remain distinguishable from reference edges.

Every token's SourceStart/SourceEnd is valid in its original text, and all 67,456 substrings exactly match the retained token spelling: zero coordinate errors. Thus source coordinates survive. Only the 2,571 roots are independently wrapped in the DiscoveryEnvironment; nested typed members remain reachable through their actual objects, but registered Pivot links do not automatically enumerate those members. The earlier module-boundary Pivot scope problem also remains. No token-wrapper index was manufactured to obscure this gap.

There are no populated phonics/grapheme/syllable/lexical-entry/Zira-phone instances reachable from these text roots. This does not mean those concepts do not exist in any source. CorePhonics internally retains segment paths but Build returns flattened pronunciation strings; Teardown returns letters:sounds text. No new phonics implementation was added after Scott directed the recursive census first.

#### Moby, Zira, repeated procedures and unresolved acquisition

The loaded driver's actual Lexicon.Count is 115,491. Its reference SHA BD4A61B93E7729FB58186DF52B5DA84A96819701A3DFA29A3CAF93508E9E1640 matches the retained Moby reference receipt. That receipt reports 177,267 source rows, 59,065 excluded multiword/long rows, 2,480 unconverted rows, 115,491 compiled identities and 70 authored overrides. Thus Moby is already contributing to pronunciation/roles; it is not merely a proposed download. 49,651 token occurrences have nonnegative LexicalId. Those identities, and morphology RootLexicalId, are scalar references into the static lexicon, not directly reachable lexical-entry instances in the text stream.

Ten authored affix rules are present in the source. Actual recurrence counts, following recursive Inner chains, include NominalPlural 1,935, ThirdPersonPresent 1,078, VerbAgent 62, AdjectiveAdverb 61 and AdjectiveComparative 19. All ten occur somewhere in this corpus. Repeated rule names were checked against all other rule fields: zero conflicting definitions. NominalPlural appears with 440 distinct train roots, 235 dev roots and 173 test roots; ThirdPersonPresent with 239/132/105 respectively. These partitions retain original manifest assignments; root overlap must still be checked before calling a composition unfamiliar.

The 3,062 rule instances do not mean 3,062 rules were learned. The implementation repeatedly constructs instances of the small authored rule bank. Corpus recurrence alone is not a discovered percept, independent confirmation, or demonstrated procedural transfer. A fresh-composition reuse check remains required.

No Zira observation was present in the resident DiscoveryEnvironment during this census. Two local typed Zira corpus assemblies were located and their receipt hashes verified; each receipt reports one capture and zero choice entries. Existing Student code can capture actual Zira word/phoneme timings and audio provenance, but broad Zira-to-Common-Voice correspondence has not been demonstrated. Do not mistake an existing symbol mapping or these fixtures for corpus-wide Zira evidence.

The present Invoke-Discovery source retains useful object/provenance/mutation machinery and confidence nomination helpers, but its default Discover operation is a native/source correspondence investigation, not a speech discovery adapter. Its Perceive switch explicitly rejects a removed regex-trained lens classifier. No emulator was run, and no regex language/source search was introduced. No speech three-sigma candidates or work-eliminating percepts have been produced by these acquisition and census operations. The full cross-voice corpus sweep has not started.

### Follow-up checks and external-research request (2026-11-10)

The recursive census's source-context check found zero invalid spans and 67,456 exact original spellings. Six recurring authored composition procedures were then exercised on actual test-partition roots absent from the corresponding train-partition root set: NominalPlural, ThirdPersonPresent, VerbAgent, AdjectiveComparative, AdjectiveNominalization and AdjectiveAdverb. Fresh CoreMorphology.Candidates execution returned the same relevant rule/root/phone analysis in each case without reusing the original parse instance. This demonstrates limited transfer of existing authored procedures; it is not discovery or admission of six new percepts.

The field currently has 20,171 registered DiscoveryObjects, including 2,571 interpreted text roots with their nested objects retained by reference. A subsequent managed-memory reading was approximately 6.72 GiB, including the original evidence bank, several baseline/candidate reference generations, probe captures and census bookkeeping. It is not a measured production footprint.

MIDI 2.0 is being considered as an interoperable performance/control representation after acoustic analysis. It does not perform pitch/prosody extraction or establish linguistic meaning. Preserve unvoiced intervals, uncertainty, original PCM and actual clocks alongside any derived control events; do not quantize speech into a musical note grid. Checked primary MIDI Association documentation: https://midi.org/midi-2-0 . Checked original AdaIN paper: https://arxiv.org/abs/1703.06868 .

Scott requested collaboration with his GPT research chat, shared at https://chatgpt.com/share/6af2ace3-60f8-83e9-9efa-0f756da0875a . The web reader returned only the share-page shell; the rendered shared page also remained at Loading profile. The existing Chrome conversation titled Technical Research Collaboration was readable and contained Scott's project brief and GPT's initial research leads. It also contained an unsent user draft, which was left untouched. No message was sent to GPT during that browser inspection. Its named research leads (Fujisaki, PENTA, articulatory gestures, YIN, WORLD) remain leads to independently verify, not adopted dependencies or completed findings. The work must not guess source availability, corpus annotations, licensing, statistical assumptions or algorithm suitability.

Concrete research deliverables requested for the collaboration:

1. Prioritized acquisition manifest of human English speech datasets that actually retain audio, transcripts, time-aligned words/phones and prosodic/discourse annotations or known adjacent context. Include dialect/speaker coverage, exact download URLs/revisions, machine-readable formats, size, licenses/attribution and known missing annotations. State whether Common Voice's retained source already supplies each property. Do not claim unrelated recordings have previous conversational context.
2. Primary-source, reproducible acoustic-analysis recipes for continuous F0 with voicing/uncertainty, intensity, rhythm, stress/prominence, pauses and relevant spectral/voice-quality measures. Give equations, parameters, limits, octave/unvoiced failure cases and validation data. Existing external implementations may be pinned reference instruments; product implementation remains PowerShell/CoreCLR.
3. Precise alignment methods linking original typed source spans, Zira's actual phones/timings, Kokoro's duration/control/PCM clocks and independent human audio. Preserve alternative alignments and unknowns; distinguish realized location from causal dependency and full normalization scope.
4. Evidence-backed comparisons of procedural speech-performance models capable of holds, overlapping gestures and transitions, including what is specified by linguistics, what must be acquired from evidence, runtime cost and tests on unfamiliar text. Explain where their analogy to time-varying AdaIN is valid and where it fails. Supply primary papers and usable test material, not a replacement Student framework.
5. A complementary audio-judging protocol beyond SNR: intelligibility, temporal/prosodic structure, timbre/voice quality, artifacts and human preference. State alignment sensitivity, speaker/accent bias, licenses and failure modes of each measure. A neural judge, if needed, remains an independently pinned instrument, not the Student runtime.
6. A statistically justified candidate-nomination protocol for a temporally correlated, heavily searched field with shared Kokoro upstream computation and repeated voices. Specify controls/null model, effective independent units, uncertainty estimation, multiple-search treatment, held-out histories and near misses. Three sigma nominates; do not fabricate z scores or equate correlated voice renders with independent confirmation. Candidate records must retain what was investigated, why, the actual objects/evidence, scope, counterexamples and negative results.
7. Specific lexical/phonics enrichment artifacts only where the census establishes a gap: machine-readable composition/pronunciation/etymology/sense data, exact licensing, source coordinates/identities and alternatives. Do not replace the populated typed morphology/grammar stream with another flattened word table.

For every research item distinguish verified fact, inference and open question. Ask for a concrete minimal experiment and acceptance/failure criteria, and identify precisely which acquisition or repeated reasoning it would eliminate. Avoid broad surveys without a usable artifact or procedure.

Final follow-up: the updated reference successfully opened all 28 documented English voice archives and selected rows at phoneme counts 1, 7 and 510 (84 row selections). The array-isolation, same-length token-invalidation, fresh-stage and voice-row negative checks passed again after the validator/path edit. Both modified scripts parse cleanly. This is voice-pack/API coverage, not 28-voice acoustic corpus coverage. The original numeric class definitions were AST-compared against the pre-edit snapshot and remain byte-for-byte unchanged as source extents.


### Tools-down checkpoint requested by Scott (2026-11-10)

Scott requested stopping engineering, committing the current checkpoint for Fable to inspect, and explicitly said not to push. Acquisition is stopped. No further defect repair or discovery work is being performed for this checkpoint.

- The original cross-voice pilot retained 32 actual corpus captures before interruption: one input across all 28 documented English voices and four captures on the next input. It did not complete the proposed 12-by-28 pass.
- Scott redirected priority to broad text coverage through the actual stock frontend. A FrontEndOnly observation option now runs ALBERT, predictor and text encoder, retaining original interpreted objects and actual returned streams without running decoder/generator.
- That frontend-only path passed 72 original-reference array byte comparisons across three inputs and three voices. The preparation cache was extended with a typed full-token-array comparer and caller-selected capacity, retaining independent shared preparations across a text-first sweep. Caller mutation, same-length sequence invalidation, fresh execution, voice-row selection, and a deliberately colliding token-hash fixture all passed. Numeric kernel class definitions were not changed.
- Source AST metadata is now retained once per loaded reference generation, with source digest checks preserved. This last metadata-sharing edit was exercised during the attempted broad acquisition; it did not receive a repeated full nine-case PCM validation.
- The broad pass planned 2,038 directly eligible Common Voice inputs, totaling 218,741 original text characters and 50,759 typed token occurrences, initially using af_heart. It retained only six frontend captures before failing with: `Language emission spans are inconsistent with the observed input.` No bypass was added and no failure status was changed to make this pass. The cause is not yet established. The failing candidate was not added to the field.
- The current English front end also has source-confirmed guards of 8,192 input characters and 256 occurrences in the active clause. These are an unresolved integration constraint for long books, not Student stream boundaries to adopt.
- All ten user-supplied EPUBs are now resident as original bytes, OPF metadata and spine-ordered XML documents, preserving original node relationships and line information. They contain 5,729,699 body text characters and 15,644 selected source blocks across 252 spine documents. This is structural ingestion; the books have not been fully interpreted by the English front end or processed by stock Kokoro.
- There are still no demonstrated speech percepts, no speech three-sigma nomination results, no broad Zira correspondence, no MIDI speech implementation, and no decoder replacement. Decoder removal is optional.
- The resident PowerShell process, PID 5940 / tool session 68382, is idle and retains the bank in memory. Runtime variables include SpeechField, CorpusBank, VoiceBank, CorpusLanguages, TextStreamCensus, MorphologyCensus, EpubBank, CorpusPilotCaptures, StockFrontEndCaptures, StockFrontEndFailure and BreadthReference. These are live session state, not committed corpus artifacts or a restartable acquisition service.
- No PSC source was changed. The phone is not required for the current CPU corpus work and Scott was told it can be disconnected. No work is to be based on the deprecated C:\dev\sma folder or stale psperception project.
