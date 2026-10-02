#requires -Version 7.4
# Gate the control-plane descriptor independently from model arithmetic.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$factory = Join-Path $repo 'src/models/New-KokoroStyleControlDescriptor.ps1'
$descriptor = & $factory -Schema 1 -Revision 4 -CommitWatermark 37 -Voice af_heart `
    -StyleDimension 128 -Mutations @(
        [pscustomobject]@{ Index = 3; Delta = 0.015 },
        [pscustomobject]@{ Index = 97; Delta = 0.02 },
        [pscustomobject]@{ Index = 3; Delta = -0.005 }
    )
if ($descriptor.Mutations.Count -ne 2 -or $descriptor.Mutations[0].Index -ne 3 -or
    [Math]::Abs($descriptor.Mutations[0].Delta - 0.01) -gt 1e-6 -or
    $descriptor.Mutations[1].Index -ne 97 -or $descriptor.Revision -ne 4 -or
    $descriptor.CommitWatermark -ne 37) {
    throw 'Style-control descriptor canonicalization differs.'
}

$invalid = $false
try {
    & $factory -Schema 1 -Revision 5 -CommitWatermark 37 -Voice af_heart -StyleDimension 128 `
        -Mutations @([pscustomobject]@{ Index = 128; Delta = 0.1 }) | Out-Null
} catch { $invalid = $true }
if (-not $invalid) { throw 'Out-of-range style-control coordinate was admitted.' }

[pscustomobject]@{ Passed = $true; MutationCount = $descriptor.Mutations.Count; Revision = $descriptor.Revision }
