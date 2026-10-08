#requires -Version 7.4
<# .SYNOPSIS
Scores the har planes of a Kokoro.HarmonicStft16Run.ps1 device output against stock har and, optionally, against the har
planes the 60x front fixture feeds the generator (tools/New-KokoroGeneratorFront16Fixture.ps1 inputs.bin).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $OutputPath,
    [Parameter(Mandatory)][string] $FixtureDirectory,
    [string] $FrontFixture,
    [ValidateRange(0, 1073741824)][long] $HarOffset = 256,
    # Kokoro.HarmonicSource16Run.ps1 outputs: the signal buffer (sample j at halfword 64 + j, Q15) at this offset, scored
    # against the fixture's expected-merge-f32.bin.
    [long] $SignalOffset = -1
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Kokoro.CaptureKernels.psm1') -Force
$fixture = Get-Content -LiteralPath (Join-Path $FixtureDirectory 'fixture.json') -Raw | ConvertFrom-Json
$frames = [int]$fixture.Frames; $tiles = [int]$fixture.Tiles; $sH = [double[]]@($fixture.HarScales)
$out = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($OutputPath))
$planeBytes = 4096L * $tiles
if ($out.Length -lt $HarOffset + 2 * $planeBytes) { throw 'Output shorter than both har planes.' }
$decode = { param([byte[]]$buf, [long]$hiAt, [long]$loAt)
    $u = [byte[]]::new($planeBytes); (Get-InterleavePlanesKernel).Invoke($buf, [int]$hiAt, $buf, [int]$loAt, [int]($planeBytes / 2), $u)
    $v = [float[]]::new(64 * $frames); (Get-DecodeCroutons16Kernel).Invoke($u, $frames, 64, $v); , $v }
$q = & $decode $out $HarOffset ($HarOffset + $planeBytes)
$hb = [IO.File]::ReadAllBytes((Join-Path $FixtureDirectory 'expected-har-f32.bin')); $har = [float[]]::new($hb.Length / 4); [Buffer]::BlockCopy($hb, 0, $har, 0, $hb.Length)
$ms = 0.0; $me = 0.0; $pe = 0.0; $pw = 0.0; $flips = 0; $nonzeroUnused = 0
for ($k = 0; $k -lt 11; $k++) { for ($t = 0; $t -lt $frames; $t++) {
    $mag = $q[$k * $frames + $t] * $sH[$k]; $ph = $q[(11 + $k) * $frames + $t] * $sH[11 + $k]
    $sm = [double]$har[$k * $frames + $t]; $sp = [double]$har[(11 + $k) * $frames + $t]
    $ms += $sm * $sm; $me += ($mag - $sm) * ($mag - $sm)
    $dp = $ph - $sp; if ([math]::Abs($dp) -gt [math]::PI) { $flips++ }; $dp -= 2 * [math]::PI * [math]::Round($dp / (2 * [math]::PI))
    $pe += $sm * $sm * $dp * $dp; $pw += $sm * $sm
} }
for ($c = 22; $c -lt 64; $c++) { for ($t = 0; $t -lt $frames; $t++) { if ($q[$c * $frames + $t] -ne 0) { $nonzeroUnused++ } } }
$result = [ordered]@{ Frames = $frames; MagnitudeSnrDb = [math]::Round(10 * [math]::Log10($ms / $me), 2); PhaseRmsRad = [math]::Sqrt($pe / $pw); PhaseCutFlips = $flips; NonzeroUnusedChannels = $nonzeroUnused }
if ($SignalOffset -ge 0) {
    $mb = [IO.File]::ReadAllBytes((Join-Path $FixtureDirectory 'expected-merge-f32.bin')); $merge = [float[]]::new($mb.Length / 4); [Buffer]::BlockCopy($mb, 0, $merge, 0, $mb.Length)
    $ss = 0.0; $se = 0.0
    for ($j = 0; $j -lt $merge.Length; $j++) { $v = [BitConverter]::ToInt16($out, [int]($SignalOffset + 128 + 2 * $j)) / 32768.0; $ss += [double]$merge[$j] * $merge[$j]; $se += ($v - $merge[$j]) * ($v - $merge[$j]) }
    $result.MergeSnrDb = [math]::Round(10 * [math]::Log10($ss / $se), 2)
}
if ($FrontFixture) {
    $front = [IO.File]::ReadAllBytes((Join-Path $FrontFixture 'inputs.bin'))
    $f = & $decode $front 0 $planeBytes
    $same = 0; $max = 0; $hist = @{}
    for ($c = 0; $c -lt 22; $c++) { for ($t = 0; $t -lt $frames; $t++) { $d = [math]::Abs($q[$c * $frames + $t] - $f[$c * $frames + $t]); if ($d -eq 0) { $same++ }; if ($d -gt $max) { $max = $d }; $b = if ($d -le 2) { "$d" } elseif ($d -le 16) { '3-16' } else { '>16' }; $hist[$b] = 1 + [int]$hist[$b] } }
    $result.FrontPlanesIdentical = "$same of $(22 * $frames)"; $result.FrontMaxLsb = $max
    $result.FrontLsbHistogram = (($hist.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name):$($_.Value)" }) -join ' ')
}
[pscustomobject]$result
