#requires -Version 7.4
# Builds a bounded, revisioned style-control descriptor. The descriptor carries
# semantic control deltas only; it never carries activations, PCM, or operators.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateRange(1, 65535)][int] $Schema,
    [Parameter(Mandatory)][ValidateRange(0, [long]::MaxValue)][long] $Revision,
    [Parameter(Mandatory)][ValidateRange(0, [long]::MaxValue)][long] $CommitWatermark,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_]{0,63}$')][string] $Voice,
    [Parameter(Mandatory)][ValidateRange(1, 1024)][int] $StyleDimension,
    [Parameter(Mandatory)][object[]] $Mutations
)

$ErrorActionPreference = 'Stop'
if ($Mutations.Count -gt 32) { throw 'Style-control mutation count exceeds the admitted bound.' }

$deltas = [Collections.Generic.Dictionary[int,double]]::new()
foreach ($mutation in $Mutations) {
    if ($null -eq $mutation) { throw 'Style-control mutation is null.' }
    $names = @($mutation.PSObject.Properties.Name)
    if ($names.Count -ne 2 -or -not $names.Contains('Index') -or -not $names.Contains('Delta')) {
        throw 'Style-control mutation must contain exactly Index and Delta.'
    }
    [int]$index = $mutation.Index
    [double]$delta = $mutation.Delta
    if ($index -lt 0 -or $index -ge $StyleDimension -or -not [double]::IsFinite($delta) -or
        [Math]::Abs($delta) -gt 1.0) {
        throw 'Style-control mutation is outside the admitted coordinate domain.'
    }
    if ($deltas.ContainsKey($index)) { $deltas[$index] += $delta } else { $deltas.Add($index, $delta) }
}

$entries = [Collections.Generic.List[object]]::new()
foreach ($index in @($deltas.Keys | Sort-Object)) {
    [double]$delta = $deltas[$index]
    if (-not [double]::IsFinite($delta) -or [Math]::Abs($delta) -gt 1.0) {
        throw 'Accumulated style-control delta is outside the admitted coordinate domain.'
    }
    if ($delta -ne 0.0) { $entries.Add([pscustomobject]@{ Index = $index; Delta = [single]$delta }) }
}

[pscustomobject]@{
    Schema = $Schema
    Revision = $Revision
    CommitWatermark = $CommitWatermark
    Voice = $Voice
    StyleDimension = $StyleDimension
    Mutations = $entries.ToArray()
}
