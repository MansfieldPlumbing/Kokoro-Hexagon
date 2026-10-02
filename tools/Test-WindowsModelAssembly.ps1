#requires -Version 7.4
[CmdletBinding()]
param(
    [string]$AssemblyPath = [IO.Path]::GetFullPath([IO.Path]::Combine(
        $PSScriptRoot, '..', 'build', 'downstream',
        'Dev.MansfieldPlumbing.Kokoro.Model.dll'))
)
$ErrorActionPreference = 'Stop'
$resolved = (Resolve-Path -LiteralPath $AssemblyPath).Path
$receipt = & (Join-Path $PSScriptRoot 'Test-KokoroEngineAssembly.ps1') -AssemblyPath $resolved
if (-not $receipt.Passed) { throw 'The downstream Kokoro engine assembly gate failed.' }
[pscustomobject]@{
    WindowsLoad = $true
    Assembly = $receipt.Assembly
    Bytes = $receipt.Bytes
    SHA256 = $receipt.SHA256
    GraphSHA256 = $receipt.GraphSHA256
    SynthesisReady = $receipt.SynthesisReady
    LegacyHostAbsent = $true
    Passed = $true
}
