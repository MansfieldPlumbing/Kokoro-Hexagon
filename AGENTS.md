# Kokoro-Hexagon

Follow [the shared agent rules](../Pwsh-Development/AGENTS.md).

- PowerShell only. No Python.
- Work iteratively on single tools. Dogfood each tool, and hill-climb it so each spike makes the next one easier.
- Run and measure on the phone through the existing emitted DSP path, and lower hot code. Never substitute interpreted host PowerShell or the offline float tools.
- Entrypoint: `pwsh -NoProfile -File ./Invoke-KokoroDevelopment.ps1`. Run `Verify` before every commit.
- Directives live in this file and in [student/AGENTS.md](student/AGENTS.md), which governs Student and generator work. Read it before that work.
- Handoffs and result records live outside this repository in [../Pwsh-Development/docs/kokoro-hexagon](../Pwsh-Development/docs/kokoro-hexagon). They are historical evidence, not directives; earlier design documents there, including the Student contract, are superseded where they differ from these two files. Write new result records there, never under this repository.
- New work extends an owning module under `tools/` or `src/` and is reached through an entrypoint command. No standalone one-off scripts, copies of existing files, or work outside this repository.
- No hard-coded machine paths (drive letters, user profiles, home directories, other checkouts or worktrees) in code, data or docs. Resolve from `$PSScriptRoot`, a parameter, or an environment variable, and fail with a message naming what's missing.
- Names state what the thing is or measures. No nicknames, metaphors, version tags or experiment code names in files, identifiers, docs or commits.

## No sprawl

We improve a few single-file tools iteratively. Each subsystem has one owning file, laid out like Pwsh's `setup.ps1`: declared records (`$script:...` tables), one shared context, and steps that check their own output. The Hexagon builder is one file: instruction records, reusable fragments, kernel records, encoder, emitter, simulator and phone run. A new capability is a new record, fragment or step in the owner.

Target layout: a few single-file appliances reached through `Invoke-KokoroDevelopment.ps1`.

- `Invoke-HexagonDevelopment.ps1` is the Hexagon appliance: every instruction, fragment, kernel, job, emitter, simulator and phone-run record lives in it. The kernels and jobs under `src/` fold into it one at a time as records and fragments, each fold checked byte-identical with `VerifyEmission`, and the folded file is removed in the same commit.
- `student/Invoke-Student.ps1` is the Student appliance and the pattern for the others: declared records, one shared context, lowered kernels in one class, typed objects with ETS members, and steps reached by name.
- `phonemizer/Invoke-EnglishPhonemizer.ps1` is the phonemizer appliance.

Tools are composable: functions over typed objects in one process, reused by every step that needs them, extended with a parameter or record rather than copied. Each change makes the owner more capable and leaves fewer lines than writing the capability separately would.

Commit continually. Every step that passes `Verify` is committed and pushed before the next begins, so work is never stranded in a working tree.

This repository grew to 131 files across 14 folders because agents did the following. Each is now prohibited:

- **A new file per task.** Every kernel, job, fixture builder, probe and test became its own file. Do not create a tracked file or folder without the team lead's approval in chat. The default answer is to extend the owner.
- **Generations side by side.** 16-bit kernels were added next to 8-bit ones, and `...Run16` next to `...Run`, with both kept alive. A new variant is a parameter or record of the existing definition, never a sibling file. What an old version does that the new one doesn't is decomposed into fragments, not discarded and not duplicated.
- **Whole-kernel copies.** Kernels were written from scratch, or by copying another kernel and editing it, so nothing was shared and every build started over. Compose kernels from fragments. When the same instruction sequence appears in two places, it becomes one fragment.
- **A switchboard instead of records.** The emitter grew one `if` branch per kernel. Add records, not branches.
- **One-off probes and measurement scripts.** A question about hardware or numerics gets an option on an existing command, and its answer becomes a record or a note.
- **Re-deriving hardware facts.** Agents re-read the V73 manual for every task. Instruction forms, operands, register effects, semantics and manual references live as records in the builder; look them up there, and add a missing one there.
- **Forks and parallel copies.** Separate repositories, worktrees and copied files for one experiment (Kodeko, the drum worktree, a forked emitter) left work stranded. Work happens in this checkout, in the owners.
- **Results, receipts and handoffs in the repository.** They go to the project notes.
- **Finishing a task without consolidating.** Every change leaves the repository with no more files than before, unless the team lead approved a new one, and leaves behavior byte-identical where it claims to (see `Verify` and the recipe gate).

## PowerShell is not bash

PowerShell is an SDK and a runtime: one long-lived .NET process with typed objects, modules and in-memory state. Bash habits waste that and cause the sprawl above:

- **Small scripts glued by files and text.** Bash composes processes, so every task becomes another script. In PowerShell, compose functions in one module and pass typed objects between them.
- **Text as the interface.** Don't print `Key=Value` lines and parse them back with regex, or report results through exit codes and stderr. Return objects and throw exceptions.
- **A new process per step.** `pwsh -File` per step pays startup, reloads modules, loses state and hides types. Call functions in process. Spawn a process only for real isolation, such as `Verify`.
- **Dot-sourcing scripts as libraries.** Use modules with exported functions, and declare data once as records.
- **Copying a script to change one line.** That forks behavior. Add a parameter or record to the owner.
- **Hard-coded absolute paths and the working directory.** Resolve paths from `$PSScriptRoot` or the shared context.
- **Strings and commas for data.** Arguments are typed, a comma builds an array, and numbers stay numbers. See [PowerShell arithmetic](#powershell-arithmetic).
- **Shell or Python side scripts.** Everything here is PowerShell or emitted by PowerShell.

## Documentation

- Docs record measurements, methods and decisions in professional technical prose.
- Never quote, paraphrase or cite chat remarks, listening reactions or verdicts. Never present one as evidence, acceptance or authorization, or as overriding a measured requirement.
- Every number in a doc comes from a committed result doc or receipt, and the doc links it. Leave out any figure you can't trace.
- No doc, plan or target is framed against another product or project. Comparisons with other systems appear only in one standard benchmark table in the README, about two-thirds of the way down, with sources.

## PowerShell arithmetic

- A comma builds an array. `F $a, $b` passes one array, and `$x = 1, 2` is an array. Call commands with spaces (`F $a $b`). Use commas only inside .NET method calls (`[Math]::Max($a, $b)`).
- Variable names are case-insensitive, so `$N` and `$n` are the same variable. Never use names that differ only in case.
- Never assign automatic variables (`$input`, `$matches`, `$args`, `$_`, `$this`, `$error`, `$host`, `$home`, `$pid`).
- `/` always returns a floating-point result. `[int]` and `[long]` casts round half to even (`[int]2.5` is 2). Use `[Math]::Floor`, `[Math]::Truncate` or `-shr` when you mean integer division.
