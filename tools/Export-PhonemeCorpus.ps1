#requires -Version 7.4
# Export exact decoder-input fixtures from a pinned phoneme corpus.
# This is one-time host tooling. It deliberately runs entries sequentially so
# only one PyTorch/Kokoro model process is resident at a time.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Corpus,
    [Parameter(Mandatory)][string] $OutRoot,
    [Parameter(Mandatory)][string] $KokoroSource,
    [string] $ModelDir = 'C:\models\Kokoro-82M',
    [string] $Python = 'C:\bin\micromamba\envs\mono\python.exe',
    [string[]] $Id
)
$ErrorActionPreference = 'Stop'
$expectedCommit = 'dfb907a02bba8152ca444717ca5d78747ccb4bec'
$requiredFiles = @(
    $Corpus,
    $Python,
    (Join-Path $ModelDir 'config.json'),
    (Join-Path $ModelDir 'kokoro-v1_0.pth'),
    (Join-Path $KokoroSource 'kokoro\model.py'),
    (Join-Path $PSScriptRoot '..\src\export\export_decoder.py'),
    (Join-Path $PSScriptRoot '..\src\export\masked.py'),
    (Join-Path $PSScriptRoot '..\src\export\export_phrase.py')
)
foreach ($path in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required file is missing: $path" }
}
$actualCommit = (& git -C $KokoroSource rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $expectedCommit) {
    throw "Kokoro source must be pinned to $expectedCommit; found $actualCommit"
}

$entries = @(Get-Content -Raw -LiteralPath $Corpus | ConvertFrom-Json)
if ($Id) { $entries = @($entries | Where-Object id -In $Id) }
if ($entries.Count -eq 0) { throw 'Corpus has no entries.' }
[void](New-Item -ItemType Directory -Force -Path $OutRoot)
$specRoot = Join-Path $OutRoot 'specs'
[void](New-Item -ItemType Directory -Force -Path $specRoot)

$oldPythonPath = $env:PYTHONPATH
$oldModelDir = $env:KOKORO_MODEL_DIR
try {
    $env:PYTHONPATH = if ($oldPythonPath) { "$KokoroSource$([IO.Path]::PathSeparator)$oldPythonPath" } else { $KokoroSource }
    $env:KOKORO_MODEL_DIR = $ModelDir
    foreach ($entry in $entries) {
        foreach ($name in 'id', 'phonemes', 'voice', 'capacity') {
            if ($null -eq $entry.$name -or [string]::IsNullOrWhiteSpace([string]$entry.$name)) {
                throw "Corpus entry is missing $name."
            }
        }
        if ([int]$entry.capacity -notin 64, 96, 128, 160) {
            throw "Unsupported capacity $($entry.capacity) for $($entry.id)."
        }
        $spec = [ordered]@{
            id = [string]$entry.id
            phonemes = [string]$entry.phonemes
            voice = [string]$entry.voice
            capacity = [int]$entry.capacity
            speaker = 'paralinguistic-probe'
        }
        if ($null -ne $entry.acoustics) { $spec.acoustics = $entry.acoustics }
        $specPath = Join-Path $specRoot "$($entry.id).json"
        $spec | ConvertTo-Json | Set-Content -LiteralPath $specPath -Encoding utf8NoBOM
        $out = Join-Path $OutRoot ([string]$entry.id)
        Write-Host "EXPORT $($entry.id): $($entry.hypothesis)"
        & $Python (Join-Path $PSScriptRoot '..\src\export\export_phrase.py') `
            (Join-Path $PSScriptRoot '..\src\export\export_decoder.py') `
            (Join-Path $PSScriptRoot '..\src\export\masked.py') $specPath $out
        if ($LASTEXITCODE -ne 0) { throw "Export failed for $($entry.id)." }
    }
}
finally {
    $env:PYTHONPATH = $oldPythonPath
    $env:KOKORO_MODEL_DIR = $oldModelDir
}
