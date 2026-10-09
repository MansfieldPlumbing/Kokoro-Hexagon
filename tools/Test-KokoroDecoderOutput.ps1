#requires -Version 7.4
<# .SYNOPSIS
Compares a decoder job's output buffer (src/emit/Kokoro.DecoderRun16.ps1, simulator or phone) with the stock capture.
.DESCRIPTION
The decoder output (512-wide croutons at offset 256, 2F frames) is decoded with the generator's DecoderScales; with
-StopAfterBlock n the buffer holds block n's output (1120-wide croutons, F frames; channels 0..1023) in that block's output
scales (tools/New-KokoroDecoderFixture.ps1 fixture.json). Reports SNR against the stock float tensor, the largest absolute
error, and how many values sit at the int16 limits.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $OutputFile,
    [Parameter(Mandatory)][string] $FixtureDirectory,
    [ValidateRange(-1, 4)][int] $StopAfterBlock = -1,
    # With -StopAfterBlock: Shortcut (the block's output region after the shortcut: conv1x1 / sqrt 2 in its output scales)
    # or Conv1 (C, 1024-wide, in the conv1 units).
    [ValidateSet('Block','Shortcut','Conv1')][string] $DumpPoint = 'Block'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Kokoro.CaptureKernels.psm1') -Force
$fixture = [IO.Path]::GetFullPath($FixtureDirectory)
$j = Get-Content -LiteralPath (Join-Path $fixture 'fixture.json') -Raw | ConvertFrom-Json
$frames = [int]$j.Frames; $tiles = [int]$j.Tiles
$buffer = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($OutputFile))
if ($StopAfterBlock -eq 4) {
    # decode.3 inside the job: the shortcut (F frames, conv1x1 / sqrt 2 in its own output scales), conv1 (2F frames, its
    # units) or its output before the conversion into the generator's scales.
    $name = 'decode.3'; $width = 512; $ch = 512; $own = [double[]]@($j.Decode3OutputScales)
    switch ($DumpPoint) {
        'Shortcut' { $fr = $frames; $scales = [double[]]($own | ForEach-Object { $_ * [math]::Sqrt(2) }); $expectedFile = 'expected-decode3-conv1x1-f32.bin'; $name += '.conv1x1' }
        'Conv1' { $fr = 2 * $frames; $scales = [double[]]@($j.Conv1Units.'decode.3'); $expectedFile = 'expected-decode3-conv1-f32.bin'; $name += '.conv1' }
        default { $fr = 2 * $frames; $scales = $own; $expectedFile = 'expected-decoder-f32.bin'; $name += '.own-scales' }
    }
    $tl = [int][math]::Ceiling($fr / 32)
} elseif ($StopAfterBlock -lt 0) {
    $name = 'decoder'; $width = 512; $ch = 512; $fr = 2 * $frames; $tl = [int][math]::Ceiling($fr / 32); $scales = [double[]]@($j.DecoderScales)
    $expectedFile = 'expected-decoder-f32.bin'
} else {
    $name = @('encode', 'decode.0', 'decode.1', 'decode.2')[$StopAfterBlock]; $width = 1120; $ch = 1024; $fr = $frames; $tl = $tiles
    $scales = [double[]]@($j.BlockOutputScales.$name); $expectedFile = "expected-$($name.Replace('.', ''))-f32.bin"
    if ($DumpPoint -eq 'Shortcut') { for ($c = 0; $c -lt 1024; $c++) { $scales[$c] *= [math]::Sqrt(2) }; $expectedFile = "expected-$($name.Replace('.', ''))-conv1x1-f32.bin"; $name += '.conv1x1' }
    if ($DumpPoint -eq 'Conv1') { $width = 1024; $scales = [double[]]@($j.Conv1Units.$name); $expectedFile = "expected-$($name.Replace('.', ''))-conv1-f32.bin"; $name += '.conv1' }
}
$bytes = 64L * $width * $tl
if ($buffer.Length -lt 256 + $bytes) { throw 'Output buffer is shorter than the tensor.' }
$tensor = [byte[]]::new($bytes); [Array]::Copy($buffer, 256, $tensor, 0, $bytes)
$rows = 32 * $tl; $values = [float[]]::new($width * $rows); (Get-DecodeCroutons16Kernel).Invoke($tensor, $rows, $width, $values)
$eb = [IO.File]::ReadAllBytes((Join-Path $fixture $expectedFile)); $expected = [float[]]::new($eb.Length / 4); [Buffer]::BlockCopy($eb, 0, $expected, 0, $eb.Length)
if ($StopAfterBlock -eq 4 -and $DumpPoint -eq 'Shortcut') {
    # Stock applies the 1x1 conv after nearest upsampling (2F frames); the job computes it at F frames: take stock's even frames.
    if ($expected.Length -ne $ch * 2 * $fr) { throw "Expected tensor is not $ch x $(2 * $fr)" }
    $even = [float[]]::new($ch * $fr); for ($c = 0; $c -lt $ch; $c++) { for ($t = 0; $t -lt $fr; $t++) { $even[$c * $fr + $t] = $expected[$c * 2 * $fr + 2 * $t] } }; $expected = $even
}
if ($expected.Length -ne $ch * $fr) { throw "Expected tensor is not $ch x $fr" }
$sig = 0.0; $err = 0.0; $maxErr = 0.0; $at = ''; $limits = 0
for ($c = 0; $c -lt $ch; $c++) { for ($t = 0; $t -lt $fr; $t++) {
    $q = $values[$c * $rows + $t]; if ($q -ge 32767 -or $q -le -32768) { $limits++ }
    $x = $q * $scales[$c]; $e = [double]$expected[$c * $fr + $t]; $d = $x - $e
    $sig += $e * $e; $err += $d * $d; if ([math]::Abs($d) -gt $maxErr) { $maxErr = [math]::Abs($d); $at = "c$c t$t" } } }
# Rows past the frame count must hold zero.
$padNonZero = 0; for ($c = 0; $c -lt $ch; $c++) { for ($t = $fr; $t -lt $rows; $t++) { if ($values[$c * $rows + $t] -ne 0) { $padNonZero++ } } }
[pscustomobject]@{ Tensor = $name; Channels = $ch; Frames = $fr; SnrDb = [math]::Round(10 * [math]::Log10($sig / [math]::Max($err, 1e-300)), 2)
    MaxAbsError = [math]::Round($maxErr, 5); MaxAbsErrorAt = $at; StockPeak = [math]::Round([math]::Sqrt(($expected | Measure-Object -Maximum -Minimum | ForEach-Object { [math]::Max($_.Maximum * $_.Maximum, $_.Minimum * $_.Minimum) })), 4)
    ValuesAtInt16Limits = $limits; PaddedRowsNonZero = $padNonZero }
