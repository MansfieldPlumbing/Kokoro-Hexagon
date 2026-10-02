# Independent build-location migration — 2026-09-26

The existing Kokoro-Hexagon build directory was moved from the adjacent
`C:\Dev\Build\Kokoro-Hexagon` location to this repository's ignored `build/`
directory. The source location is absent; the destination has the same 140
files and total byte count, and the existing APK's SHA-256 is unchanged. No
new APK was built or installed for this migration.

`setup-kokoro.ps1` now defaults its APK and optional intermediates to `build/`.
The repository write guard permits only the approved APK and intermediates
there; it still rejects repository-local signing keys and package-cache paths.
The repository-change check excludes only `build/`, and Git ignores it. An
existing package cache moved with the historical build folder; the script's
default package-cache location remains outside the repository.

Checks: PowerShell source parsed; Step 1 `-WhatIf` showed the new default
write plan and reported no source changes; paths outside `build/` were rejected
for the APK and intermediates; repository-local key and cache paths were
rejected; the moved managed assembly passed its Windows load test; and the
production-closure source gate passed. A full build at the new default path
remains unverified.
