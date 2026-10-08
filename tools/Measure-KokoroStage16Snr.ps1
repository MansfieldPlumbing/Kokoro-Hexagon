#requires -Version 7.4
<# .SYNOPSIS
SNR of a 16-bit stage output captured from the phone against the stock float output.
.DESCRIPTION
The capture holds biased u16 values (x + 32768) in native croutons (tools/New-KokoroGenerator60x16Fixture.ps1);
the stock output is [channel][frame] float32 from the fixture. Value = (u16 - 32768) * OutputScales[channel].
SNR = 10 log10(sum y^2 / sum (y - value)^2) over every channel and valid frame.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $CapturedOutput,
    [Parameter(Mandatory)][string] $FixtureDirectory
)
$ErrorActionPreference = 'Stop'
$fixture = Get-Content -LiteralPath (Join-Path $FixtureDirectory 'fixture.json') -Raw | ConvertFrom-Json
$frames = [int]$fixture.Frames; $tiles = [int]$fixture.Tiles; $scales = [double[]]@($fixture.OutputScales)
if ($scales.Count -ne 128) { throw 'Expected 128 per-channel output scales.' }
$bytes = [IO.File]::ReadAllBytes($CapturedOutput)
# A whole-workspace capture (Generator60x16 harness) holds branch 0, branch 1, then the final tensor.
$tensor = $tiles * 8192; $stride = [int]([math]::Ceiling($tensor / 128) * 128)
if ($bytes.Length -gt $tensor) { $final = [byte[]]::new($tensor); [Buffer]::BlockCopy($bytes, 2 * $stride, $final, 0, $tensor); $bytes = $final }
if ($bytes.Length -ne $tensor) { throw "Captured output is $($bytes.Length) bytes; expected $tensor." }
$raw = [IO.File]::ReadAllBytes((Join-Path $FixtureDirectory 'expected-f32.bin'))
$y = [float[]]::new($raw.Length / 4); [Buffer]::BlockCopy($raw, 0, $y, 0, $raw.Length)
if ($y.Length -ne 128 * $frames) { throw 'Stock output length.' }
$signal = 0.0; $noise = 0.0; $maxErr = 0.0; $channelNoise = [double[]]::new(128); $channelSignal = [double[]]::new(128)
for ($c = 0; $c -lt 128; $c++) {
    for ($t = 0; $t -lt $frames; $t++) {
        $at = 2 * ((([int][math]::Floor($t / 32)) * 4 + ($c -shr 5)) * 1024 + 64 * (($t % 32) -shr 1) + 2 * ($c % 32) + ($t % 2))
        $v = (([int]$bytes[$at] -bor ([int]$bytes[$at + 1] -shl 8)) - 32768) * $scales[$c]
        $r = [double]$y[$c * $frames + $t]; $d = $r - $v
        $signal += $r * $r; $noise += $d * $d; $channelSignal[$c] += $r * $r; $channelNoise[$c] += $d * $d
        $maxErr = [math]::Max($maxErr, [math]::Abs($d))
    }
}
$worst = 1e9; $worstChannel = -1
for ($c = 0; $c -lt 128; $c++) { if ($channelNoise[$c] -gt 0) { $snr = 10 * [math]::Log10($channelSignal[$c] / $channelNoise[$c]); if ($snr -lt $worst) { $worst = $snr; $worstChannel = $c } } }
[pscustomobject]@{
    SnrDb = [math]::Round(10 * [math]::Log10($signal / [math]::Max($noise, 1e-300)), 2)
    WorstChannelSnrDb = [math]::Round($worst, 2); WorstChannel = $worstChannel
    MaxAbsError = $maxErr; Frames = $frames
    CaptureSHA256 = (Get-FileHash -LiteralPath $CapturedOutput).Hash
}
