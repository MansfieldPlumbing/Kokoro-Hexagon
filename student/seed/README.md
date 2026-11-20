# Managed Student percept seed

This assembly contains a typed graph of seven Student percepts and 46 observations. PSC compiles the PowerShell class definitions and emits the IL that builds the graph. The assembly has no embedded resources and loads without PSC.

From the repository root, verify the checked-in snapshot with PowerShell 7.

```powershell
pwsh -NoProfile -File student/Test-PerceptSeed.ps1 -AssemblyPath student/seed/Kokoro.Student.PerceptSeed.dll
```

To inspect the live CLR graph in a PowerShell session, use the assembly's public entry point.

```powershell
$path = (Resolve-Path student/seed/Kokoro.Student.PerceptSeed.dll).Path
$assembly = [Reflection.Assembly]::LoadFrom($path)
$seed = $assembly.GetType('StudentPerceptSeed').GetMethod('Read').Invoke($null, $null)
$seed.Percepts | Select-Object Identity, Kind, @{Name='Examples';Expression={$_.Examples.Count}}
```

The seed retains numeric measurements and relationships between percepts, observations, prompt variants, transfer rows, word spans, and repeated tag occurrences. Prompt and tag IDs are scoped to this snapshot. The source audio, transcript words, tag names, filenames, paths, and source fingerprints are excluded. The retained numbers derive from the original experiments. The paragraph alignments are hypotheses awaiting independent review.

Rebuilding uses [the PowerShell build script](../Build-PerceptSeed.ps1), PowerShell 7.7, a local PSC checkout and the original Student image. Reading and verifying the checked-in DLL requires only the assembly and PowerShell.
