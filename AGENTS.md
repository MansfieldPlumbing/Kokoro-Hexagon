# Kokoro-Hexagon

Follow [the shared agent rules](../Pwsh-Development/AGENTS.md).

- PowerShell only. No Python.
- Work iteratively on single tools. Dogfood each tool, and hill-climb it so each spike makes the next one easier.
- Run and measure on the phone through the existing emitted DSP path, and lower hot code. Never substitute interpreted host PowerShell or the offline float tools.
- Entrypoint: `pwsh -NoProfile -File ./Invoke-KokoroDevelopment.ps1`. Run `Verify` before every commit.
- Project notes (the Student contract, designs, handoffs and result records) live outside this repository in [../Pwsh-Development/docs/kokoro-hexagon](../Pwsh-Development/docs/kokoro-hexagon). Read [the Student contract](../Pwsh-Development/docs/kokoro-hexagon/student-generator-contract.md) before Student work. Write new notes there, never under this repository.
- New work extends an owning module under `tools/` or `src/` and is reached through an entrypoint command. No standalone one-off scripts, copies of existing files, or work outside this repository.
- Names state what the thing is or measures. No nicknames, metaphors, version tags or experiment code names in files, identifiers, docs or commits.

## No sprawl

- Each subsystem has one owning file, laid out like Pwsh's `setup.ps1`: declared records (`$script:...` tables), one shared context, and steps that check their own output. New capability is a new record or step in that file.
- Never copy a file to change one branch, put a second definition of the same thing somewhere else, or add a probe or measurement script beside the owner. If the owner can't express something yet, extend the owner.
- Hardware facts (instruction forms, operands, register effects, semantics, manual references) live as records in the owning file, so they're looked up there, not re-derived from the manual.

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
