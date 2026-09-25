#requires -Version 7.4
[CmdletBinding()]
param(
    [string]$AssemblyPath = [IO.Path]::GetFullPath([IO.Path]::Combine(
        $PSScriptRoot, '..', '..', 'Build', 'Kokoro-Hexagon', 'arm64-v8a',
        'managed', 'by-name', 'Kokoro-Hexagon.dll'))
)
$ErrorActionPreference = 'Stop'
$resolved = (Resolve-Path -LiteralPath $AssemblyPath).Path
$source = & (Join-Path $PSScriptRoot 'Test-ModelContract.ps1')
$assembly = [Reflection.Assembly]::LoadFrom($resolved)
$type = $assembly.GetType('Dev.MansfieldPlumbing.Pwsh.NativeHost', $true)
$graph = [string]$type.GetMethod('ModelGraphSHA256').Invoke($null, @())
$controls = [string]$type.GetMethod('ModelControls').Invoke($null, @())
if ($graph -cne $source.GraphSHA256) { throw 'Assembly graph hash does not match New-KokoroDecoderGraph.ps1' }
$controlNames = $controls.Split(',', [StringSplitOptions]::RemoveEmptyEntries)
if ($controlNames.Count -ne $source.Controls) { throw 'Assembly control schema does not match New-KokoroDecoderGraph.ps1' }
[pscustomobject]@{
    WindowsLoad = $true
    Assembly = $assembly.GetName().Name
    Bytes = (Get-Item -LiteralPath $resolved).Length
    SHA256 = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash
    GraphSHA256 = $graph
    Controls = $controlNames
}
