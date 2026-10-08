#requires -Version 7.4
<# .SYNOPSIS
Joins a 16-bit 60x stage fixture and a 16-bit tail fixture for Kokoro.Generator60x16Run.ps1 -Tail.
.DESCRIPTION
activations.bin is the stage input; weights.bin and tables.bin are the stage's followed by the tail's (the job
reads the tail's at the stage sizes); expected-pcm-f32.bin is the stock PCM. The tail fixture must have been built
from this stage fixture (its fixture.json StageFixture), so its conv_post weights carry the stage's residual scales.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $StageFixture,
    [Parameter(Mandatory)][string] $TailFixture,
    [Parameter(Mandatory)][string] $OutputDirectory
)
$ErrorActionPreference = 'Stop'
$build = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build')) + [IO.Path]::DirectorySeparatorChar
$out = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $out.StartsWith($build, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)) { throw 'Use a new directory in build/.' }
$stageDir = [IO.Path]::GetFullPath($StageFixture); $tailDir = [IO.Path]::GetFullPath($TailFixture)
$stage = Get-Content -LiteralPath (Join-Path $stageDir 'fixture.json') -Raw | ConvertFrom-Json
$tail = Get-Content -LiteralPath (Join-Path $tailDir 'fixture.json') -Raw | ConvertFrom-Json
if ([IO.Path]::GetFullPath($tail.StageFixture) -ne $stageDir) { throw 'The tail fixture was built from another stage fixture.' }
if ($tail.Frames -ne $stage.Frames) { throw 'Frame counts differ.' }
# Each file must still be the one its fixture.json recorded.
foreach ($pair in @(@($stageDir, $stage), @($tailDir, $tail))) {
    foreach ($f in $pair[1].Files) { if ((Get-FileHash (Join-Path $pair[0] $f.Name)).Hash -ne $f.SHA256) { throw "Fixture file changed: $($f.Name)" } }
}
$read = { param([string]$d, [string]$n) [IO.File]::ReadAllBytes((Join-Path $d $n)) }
$join = { param([string]$n) $a = & $read $stageDir $n; $b = & $read $tailDir $n; $c = [byte[]]::new($a.Length + $b.Length); [Array]::Copy($a, $c, $a.Length); [Array]::Copy($b, 0, $c, $a.Length, $b.Length); , $c }
[void][IO.Directory]::CreateDirectory($out)
[IO.File]::WriteAllBytes((Join-Path $out 'activations.bin'), (& $read $stageDir 'activations.bin'))
[IO.File]::WriteAllBytes((Join-Path $out 'weights.bin'), (& $join 'weights.bin'))
[IO.File]::WriteAllBytes((Join-Path $out 'tables.bin'), (& $join 'tables.bin'))
[IO.File]::WriteAllBytes((Join-Path $out 'expected-pcm-f32.bin'), (& $read $tailDir 'expected-pcm-f32.bin'))
$files = @(Get-ChildItem -LiteralPath $out -File | ForEach-Object { [ordered]@{ Name = $_.Name; Bytes = $_.Length; SHA256 = (Get-FileHash $_.FullName).Hash } })
[ordered]@{ Graph = 'Generator60x16Tail'; Frames = $stage.Frames; Tiles = $stage.Tiles; Samples = $tail.Samples; StageFixture = $stageDir; TailFixture = $tailDir; Files = $files } |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $out 'fixture.json') -Encoding utf8NoBOM
[pscustomobject]@{ Directory = $out; Frames = $stage.Frames; Samples = $tail.Samples }
