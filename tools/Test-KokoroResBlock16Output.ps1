#requires -Version 7.4
<# .SYNOPSIS
SNR of a 16-bit resblock job's final tensor against the stock output its fixture expects.
.DESCRIPTION
For output buffers pulled by tools/Invoke-GeneratorTailProbe.ps1 from Kokoro.Generator60x16Run.ps1 jobs: the job
stores at [40] the final tensor's offset from the buffer start (biased u16 croutons, 128 channels). The fixture
holds expected-f32.bin ([channel][frame]) and fixture.json (Frames, Tiles, OutputScales).
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string] $OutputPath, [Parameter(Mandatory)][string] $FixtureDirectory)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Kokoro.CaptureKernels.psm1') -Force
$fx = Get-Content -LiteralPath (Join-Path $FixtureDirectory 'fixture.json') -Raw | ConvertFrom-Json
$frames = [int]$fx.Frames; $tensor = [int]$fx.Tiles * 8192; $scales = [double[]]@($fx.OutputScales)
$buf = [IO.File]::ReadAllBytes($OutputPath)
$at = [BitConverter]::ToInt32($buf, 40)
if ($at -lt 48 -or $at + $tensor -gt $buf.Length) { throw "Final tensor offset $at is outside the buffer." }
$x = [byte[]]::new($tensor); [Array]::Copy($buf, $at, $x, 0, $tensor)
$eb = [IO.File]::ReadAllBytes((Join-Path $FixtureDirectory 'expected-f32.bin')); $ref = [float[]]::new($eb.Length / 4); [Buffer]::BlockCopy($eb, 0, $ref, 0, $eb.Length)
$sig = [double[]]::new(128); $noi = [double[]]::new(128)
$mx = (Get-Croutons16ErrorKernel).Invoke($x, $ref, $frames, $scales, $sig, $noi)
$s = 0.0; $n = 0.0; foreach ($v in $sig) { $s += $v }; foreach ($v in $noi) { $n += $v }
[pscustomobject]@{ SnrDb = [math]::Round(10 * [math]::Log10($s / [math]::Max($n, 1e-300)), 2); MaxAbsError = [math]::Round($mx, 4); FinalSHA256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($x)) }
