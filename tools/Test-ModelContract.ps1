#requires -Version 7.4
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$path = Join-Path $root 'New-KokoroDecoderGraph.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'New-KokoroDecoderGraph.ps1 does not parse' }
$nodes = @(& (Join-Path $root 'src\lower\Lower-Model.ps1') -Model $ast.GetScriptBlock())
$expected = @(
    'KokoroFront|@asr,@F0_curve,@N,@style,@mask,@capacity',
    'KokoroGenerator|%0,@gb,@har8,@mask,@mask8,@capacity'
)
$actual = @($nodes | ForEach-Object { $_.Op + '|' + ($_.Inputs -join ',') })
if (($actual -join "`n") -cne ($expected -join "`n")) { throw 'New-KokoroDecoderGraph.ps1 graph contract changed unexpectedly' }
$json = $nodes | ConvertTo-Json -Depth 6 -Compress
$hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json)))
[pscustomobject]@{ Nodes = $nodes.Count; Controls = 9; GraphSHA256 = $hash }
