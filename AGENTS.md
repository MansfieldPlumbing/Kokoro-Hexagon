# Kokoro-Hexagon

Follow [the shared agent rules](../Pwsh-Development/AGENTS.md).

- PowerShell only. No Python.
- Work iteratively on single tools. Dogfood each tool, and hill-climb it so each spike makes the next one easier.
- Run and measure on the phone through the existing emitted DSP path, and lower hot code. Never substitute interpreted host PowerShell or the offline float tools.
- Entrypoint: `pwsh -NoProfile -File ./Invoke-KokoroDevelopment.ps1`. Run `Verify` before every commit.
- New work extends an owning module under `tools/` or `src/` and is reached through an entrypoint command. No standalone one-off scripts, copies of existing files, or work outside this repository.
- Names state what the thing is or measures. No nicknames, metaphors, version tags or experiment code names in files, identifiers, docs or commits.

## Documentation

- Docs record measurements, methods and decisions in professional technical prose.
- Never quote, paraphrase or cite chat remarks, listening reactions or verdicts. Never present one as evidence, acceptance or authorization, or as overriding a measured requirement.
- Every number in a doc comes from a committed result doc or receipt, and the doc links it. Leave out any figure you can't trace.

## PowerShell arithmetic

- A comma builds an array. `F $a, $b` passes one array, and `$x = 1, 2` is an array. Call commands with spaces (`F $a $b`). Use commas only inside .NET method calls (`[Math]::Max($a, $b)`).
- Variable names are case-insensitive, so `$N` and `$n` are the same variable. Never use names that differ only in case.
- Never assign automatic variables (`$input`, `$matches`, `$args`, `$_`, `$this`, `$error`, `$host`, `$home`, `$pid`).
- `/` always returns a floating-point result. `[int]` and `[long]` casts round half to even (`[int]2.5` is 2). Use `[Math]::Floor`, `[Math]::Truncate` or `-shr` when you mean integer division.
