#requires -Version 7.4
<# .SYNOPSIS
Joins a 16-bit 60x stage fixture and a 16-bit tail fixture for Kokoro.Generator60x16Run.ps1 -Tail.
.DESCRIPTION
activations.bin is the stage input; weights.bin and tables.bin are the stage's followed by the tail's (the job
reads the tail's at the stage sizes); expected-pcm-f32.bin is the stock PCM. The tail fixture must have been built
from this stage fixture (its fixture.json StageFixture), so its conv_post weights carry the stage's residual scales.
With -NoiseResFixture and -FrontFixture (Kokoro.Generator60x16Run.ps1 -Front -Tail): activations.bin is the front's
inputs, and the noise_res[1] then front weights and records follow the tail's.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $StageFixture,
    # Without -TailFixture: the stage (with -NoiseResFixture and -FrontFixture, its front) alone; expected-f32.bin is the
    # stage's expected final tensor.
    [string] $TailFixture,
    [Parameter(Mandatory)][string] $OutputDirectory,
    [string] $NoiseResFixture,
    [string] $FrontFixture
)
$ErrorActionPreference = 'Stop'
$build = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build')) + [IO.Path]::DirectorySeparatorChar
$out = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $out.StartsWith($build, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)) { throw 'Use a new directory in build/.' }
$stageDir = [IO.Path]::GetFullPath($StageFixture)
$stage = Get-Content -LiteralPath (Join-Path $stageDir 'fixture.json') -Raw | ConvertFrom-Json
$sets = @(, @($stageDir, $stage))
if ($TailFixture) {
    $tailDir = [IO.Path]::GetFullPath($TailFixture)
    $tail = Get-Content -LiteralPath (Join-Path $tailDir 'fixture.json') -Raw | ConvertFrom-Json
    if ([IO.Path]::GetFullPath($tail.StageFixture) -ne $stageDir) { throw 'The tail fixture was built from another stage fixture.' }
    if ($tail.Frames -ne $stage.Frames) { throw 'Frame counts differ.' }
    $sets += , @($tailDir, $tail)
}
if ($FrontFixture) {
    $noiseDir = [IO.Path]::GetFullPath($NoiseResFixture); $frontDir = [IO.Path]::GetFullPath($FrontFixture)
    $noise = Get-Content -LiteralPath (Join-Path $noiseDir 'fixture.json') -Raw | ConvertFrom-Json
    $front = Get-Content -LiteralPath (Join-Path $frontDir 'fixture.json') -Raw | ConvertFrom-Json
    if ([IO.Path]::GetFullPath($front.StageFixture) -ne $stageDir -or [IO.Path]::GetFullPath($front.NoiseResFixture) -ne $noiseDir) { throw 'The front fixture was built from other stage or noise_res fixtures.' }
    $sets += , @($noiseDir, $noise); $sets += , @($frontDir, $front)
}
# Each file must still be the one its fixture.json recorded.
foreach ($pair in $sets) {
    foreach ($f in $pair[1].Files) { if ((Get-FileHash (Join-Path $pair[0] $f.Name)).Hash -ne $f.SHA256) { throw "Fixture file changed: $($f.Name)" } }
}
$read = { param([string]$d, [string]$n) [IO.File]::ReadAllBytes((Join-Path $d $n)) }
$join = { param([string]$n) $parts = @(foreach ($pair in $sets) { , (& $read $pair[0] $n) }); $c = [byte[]]::new(($parts | ForEach-Object Length | Measure-Object -Sum).Sum); $at = 0; foreach ($q in $parts) { [Array]::Copy($q, 0, $c, $at, $q.Length); $at += $q.Length }; , $c }
[void][IO.Directory]::CreateDirectory($out)
[IO.File]::WriteAllBytes((Join-Path $out 'activations.bin'), $(if ($FrontFixture) { & $read $frontDir 'inputs.bin' } else { & $read $stageDir 'activations.bin' }))
[IO.File]::WriteAllBytes((Join-Path $out 'weights.bin'), (& $join 'weights.bin'))
[IO.File]::WriteAllBytes((Join-Path $out 'tables.bin'), (& $join 'tables.bin'))
if ($TailFixture) { [IO.File]::WriteAllBytes((Join-Path $out 'expected-pcm-f32.bin'), (& $read $tailDir 'expected-pcm-f32.bin')) }
else { [IO.File]::WriteAllBytes((Join-Path $out 'expected-f32.bin'), (& $read $stageDir 'expected-f32.bin')) }
$files = @(Get-ChildItem -LiteralPath $out -File | ForEach-Object { [ordered]@{ Name = $_.Name; Bytes = $_.Length; SHA256 = (Get-FileHash $_.FullName).Hash } })
[ordered]@{ Graph = $(if ($TailFixture) { 'Generator60x16Tail' } else { 'Generator60x16' }); Frames = $stage.Frames; Tiles = $stage.Tiles; Samples = $(if ($TailFixture) { $tail.Samples } else { 1 }); OutputScales = $stage.OutputScales; StageFixture = $stageDir; TailFixture = $(if ($TailFixture) { $tailDir } else { $null }); NoiseResFixture = $(if ($FrontFixture) { $noiseDir } else { $null }); FrontFixture = $(if ($FrontFixture) { $frontDir } else { $null }); Files = $files } |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $out 'fixture.json') -Encoding utf8NoBOM
[pscustomobject]@{ Directory = $out; Frames = $stage.Frames }
