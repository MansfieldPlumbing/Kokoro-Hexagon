#requires -Version 7.4
# Byte-level reference gate for every stock ALBERT linear geometry. The DSP
# numerical/device differential remains a separate gate.
[CmdletBinding()]
param([string] $OutputDirectory = (Join-Path $PSScriptRoot '../build/hexagon-emission/albert-linear'))

$ErrorActionPreference = 'Stop'
$base = [IO.Path]::GetFullPath($OutputDirectory)
$buildRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build'))
if (-not $base.StartsWith($buildRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Linear emission gate writes only under ignored build.'
}
$shapes = @(
    @(128, 768),  # ALBERT embedding projection
    @(768, 768),  # Q/K/V and attention output
    @(768, 2048), # feed-forward expansion
    @(2048, 768), # feed-forward contraction
    @(768, 512)   # BERT projection
)
foreach ($shape in $shapes) {
    $from = [int]$shape[0]; $to = [int]$shape[1]
    $directory = Join-Path $base "$from-$to"
    $result = & (Join-Path $PSScriptRoot 'Test-HexagonEmission.ps1') `
        -Kernel KokoroLinearTile -OutputDirectory $directory `
        -LinearRows 3 -LinearInputChannels $from -LinearOutputChannels $to
    if (-not $result.InstructionBytesMatch -or $result.Imports -ne 0 -or
        $result.Relocations -ne 0) {
        throw "ALBERT linear emission failed: $from->$to"
    }
    Write-Output "PASS: emitted ALBERT linear 3x$from->$to, $($result.CodeBytes) instruction bytes"
    $vectorDirectory = Join-Path $base "$from-$to-vector"
    $vector = & (Join-Path $PSScriptRoot 'Test-HexagonEmission.ps1') `
        -Kernel KokoroLinearTile -OutputDirectory $vectorDirectory `
        -LinearRows 3 -LinearInputChannels $from -LinearOutputChannels $to `
        -LinearVectorOutputTiles
    if (-not $vector.InstructionBytesMatch -or $vector.Imports -ne 0 -or
        $vector.Relocations -ne 0) {
        throw "ALBERT vector linear emission failed: $from->$to"
    }
    Write-Output "PASS: emitted vector ALBERT linear 3x$from->$to, $($vector.CodeBytes) instruction bytes"
}
