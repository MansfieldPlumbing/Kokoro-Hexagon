#requires -Version 7.4
<# .SYNOPSIS
Scores a 16-bit resblock job stopped after stage n (Kokoro.Generator60x16Run.ps1 -StopAfterStage n) against stock.
.DESCRIPTION
The job leaves stage n's output in the final-tensor slot (offset at [40] of the output buffer): C after a first half
(stock stage<s>.conv), R after a second half (stock stage<s+1>.input, or the block output after stage 5). Scales come
from the fixture's stage-output-scales.bin. Capture: the whole-generator capture the fixture was built from.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $OutputPath,
    [Parameter(Mandatory)][string] $FixtureDirectory,
    [Parameter(Mandatory)][string] $CaptureDirectory,
    [Parameter(Mandatory)][ValidateRange(0, 17)][int] $Stage
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Kokoro.CaptureMath.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Kokoro.CaptureKernels.psm1') -Force
$fx = Get-Content -LiteralPath (Join-Path $FixtureDirectory 'fixture.json') -Raw | ConvertFrom-Json
$chans = @($fx.OutputScales).Count; $frames = [int]$fx.Frames; $tensor = [int]$fx.Tiles * 64 * $chans
$b = [math]::Floor($Stage / 6); $s = $Stage % 6
$cap = Read-KokoroResBlockCapture -Directory $CaptureDirectory -Block ([int]@($fx.Blocks)[$b]) -Module $fx.Module
$name = if ($s % 2 -eq 0) { "stage$s.conv" } elseif ($s -lt 5) { "stage$($s + 1).input" } else { 'output' }
$all = [IO.File]::ReadAllBytes((Join-Path $FixtureDirectory 'stage-output-scales.bin')); $scales = [double[]]::new($chans); [Buffer]::BlockCopy($all, 8 * $chans * $Stage, $scales, 0, 8 * $chans)
$buf = [IO.File]::ReadAllBytes($OutputPath); $at = [BitConverter]::ToInt32($buf, 40)
$x = [byte[]]::new($tensor); [Array]::Copy($buf, $at, $x, 0, $tensor)
$sig = [double[]]::new($chans); $noi = [double[]]::new($chans)
$mx = (Get-Croutons16ErrorKernel).Invoke($x, (Read-KokoroCaptureTensor -Capture $cap -Name $name), $frames, $scales, $sig, $noi)
$sn = 0.0; $nn = 0.0; foreach ($v in $sig) { $sn += $v }; foreach ($v in $noi) { $nn += $v }
$per = 0..($chans - 1) | ForEach-Object { [pscustomobject]@{ C = $_; Db = 10 * [math]::Log10($sig[$_] / [math]::Max($noi[$_], 1e-300)) } }
$blocks = 0..($chans / 32 - 1) | ForEach-Object { $k = $_; $a = 0.0; $z = 0.0; for ($c = 32 * $k; $c -lt 32 * $k + 32; $c++) { $a += $sig[$c]; $z += $noi[$c] }; '{0:N1}' -f (10 * [math]::Log10($a / [math]::Max($z, 1e-300))) }
[pscustomobject]@{ Stage = $Stage; Reference = $name; SnrDb = [math]::Round(10 * [math]::Log10($sn / [math]::Max($nn, 1e-300)), 2); MaxAbsError = $mx
    BlockSnrDb = $blocks -join ' '; WorstChannels = (($per | Sort-Object Db | Select-Object -First 4) | ForEach-Object { "c$($_.C)=$([math]::Round($_.Db, 1))" }) -join ' ' }
