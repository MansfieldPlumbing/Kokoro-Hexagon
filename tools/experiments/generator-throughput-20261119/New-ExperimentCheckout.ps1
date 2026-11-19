#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Variant,
    [Parameter(Mandatory)][string]$Destination
)
$ErrorActionPreference = 'Stop'
$parents = Get-Content (Join-Path $PSScriptRoot 'parents.json') -Raw | ConvertFrom-Json -AsHashtable
if (!$parents.Contains($Variant)) { throw "Unknown variant. Choose from $($parents.Keys -join ', ')." }
if (Test-Path -LiteralPath $Destination) { throw "Choose a new worktree directory. Path already exists at $Destination" }
$repo = git -C $PSScriptRoot rev-parse --show-toplevel
if ($LASTEXITCODE) { throw 'Cannot locate the repository.' }
$tree = [IO.Path]::GetFullPath($Destination)
$series = [Collections.Generic.Stack[string]]::new()
for ($name = $Variant; $name -ne 'base'; $name = $parents[$name]) { $series.Push($name) }
git -C $repo worktree add --detach $tree 1ebca4f
if ($LASTEXITCODE) { throw 'Could not create experiment worktree.' }
foreach ($name in $series) {
    git -C $tree apply --whitespace=nowarn (Join-Path $PSScriptRoot "$name.patch")
    if ($LASTEXITCODE) { throw "Could not apply $name to $tree." }
}
Write-Output $tree
